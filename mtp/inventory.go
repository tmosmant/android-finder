package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"path"
	"slices"
	"strings"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

func inventory(ctx context.Context, device *mtp.Device, storage uint32, root androidObject, output io.Writer) error {
	var info mtp.DeviceInfo
	infoErr := device.GetDeviceInfo(&info)
	var response mtp.RCError
	if infoErr != nil && !errors.As(infoErr, &response) {
		return infoErr
	}
	bulk := infoErr == nil && slices.Contains(info.OperationsSupported, mtp.OC_MTP_GetObjPropList)
	writer := bufio.NewWriter(output)
	var walk func(androidObject) error
	walk = func(folder androidObject) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		handles, err := objectHandles(device, storage, folder.handle)
		if err != nil {
			return err
		}
		var children []androidObject
		// Three property lists are cheaper than one request per object in wide folders.
		if bulk && len(handles) >= 8 {
			children, err = bulkInventoryChildren(ctx, device, folder, handles)
			if err != nil {
				// A transport failure closes the device. Only unsupported or
				// malformed property lists can fall back in the same session.
				if !errors.Is(err, errInvalidPropertyList) && !errors.As(err, &response) {
					return err
				}
				bulk = false
			}
		}
		for index, handle := range handles {
			if err := ctx.Err(); err != nil {
				return err
			}
			var child androidObject
			if children != nil {
				child = children[index]
			} else {
				child, err = readObject(device, handle, folder.FullPath)
				if err != nil {
					return err
				}
			}
			relative := strings.TrimPrefix(child.FullPath, strings.TrimSuffix(root.FullPath, "/")+"/")
			if child.IsDir {
				if _, err := fmt.Fprintf(writer, "./%s\x00d\x00", relative); err != nil {
					return err
				}
				if err := walk(child); err != nil {
					return err
				}
			} else if _, err := fmt.Fprintf(writer, "./%s\x00f %d\x00", relative, child.Size); err != nil {
				return err
			}
			if folder.handle == root.handle && child.IsDir {
				if _, err := writer.WriteString("!\x00child\x00"); err != nil {
					return err
				}
				if err := writer.Flush(); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := walk(root); err != nil {
		return err
	}
	if _, err := writer.WriteString("!\x000\x00"); err != nil {
		return err
	}
	return writer.Flush()
}

var errInvalidPropertyList = errors.New("invalid MTP object property list")

func bulkInventoryChildren(ctx context.Context, device *mtp.Device, folder androidObject, handles []uint32) ([]androidObject, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	parent, depth := folder.handle, uint32(1)
	if parent == mtp.GOH_ROOT_PARENT {
		// In GetObjectPropList, zero selects root children. All-ones selects all objects.
		parent, depth = 0, 0
	}
	names := inventoryProperties[mtp.StringValue]{code: mtp.OPC_ObjectFileName, kind: mtp.DTC_STR}
	formats := inventoryProperties[struct{ Value uint16 }]{code: mtp.OPC_ObjectFormat, kind: mtp.DTC_UINT16}
	sizes := inventoryProperties[mtp.Uint64Value]{code: mtp.OPC_ObjectSize, kind: mtp.DTC_UINT64}

	for _, property := range []struct {
		code uint16
		list mtp.Decoder
	}{
		{mtp.OPC_ObjectFileName, &names},
		{mtp.OPC_ObjectFormat, &formats},
		{mtp.OPC_ObjectSize, &sizes},
	} {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		request := mtp.Container{Code: mtp.OC_MTP_GetObjPropList, Param: []uint32{parent, 0, uint32(property.code), 0, depth}}
		if err := device.GetData(&request, property.list); err != nil {
			return nil, err
		}
	}
	children := make([]androidObject, 0, len(handles))
	for _, handle := range handles {
		name := names.values[handle].Value
		format, hasFormat := formats.values[handle]
		length, hasSize := sizes.values[handle]
		isDir := format.Value == mtp.OFC_Association
		if name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\x00") ||
			!hasFormat || (!isDir && (!hasSize || length.Value > math.MaxInt64)) {
			return nil, errInvalidPropertyList
		}
		var size int64
		if !isDir {
			size = int64(length.Value)
		}
		children = append(children, androidObject{
			entry:  entry{Name: name, FullPath: path.Join(folder.FullPath, name), IsDir: isDir, Size: size, Handle: handle},
			handle: handle,
		})
	}
	return children, nil
}

type inventoryProperties[T any] struct {
	code   uint16
	kind   uint16
	values map[uint32]T
}

func (list *inventoryProperties[T]) Decode(reader io.Reader) (err error) {
	defer func() {
		if err != nil && !errors.Is(err, errInvalidPropertyList) {
			err = errors.Join(errInvalidPropertyList, err)
		}
	}()
	var count uint32
	if err := binary.Read(reader, binary.LittleEndian, &count); err != nil {
		return err
	}
	list.values = make(map[uint32]T)
	for range count {
		var header struct {
			Handle uint32
			Code   uint16
			Kind   uint16
		}
		if err := binary.Read(reader, binary.LittleEndian, &header); err != nil {
			return err
		}
		if header.Code != list.code || header.Kind != list.kind {
			return errInvalidPropertyList
		}
		if _, exists := list.values[header.Handle]; exists {
			return errInvalidPropertyList
		}
		var value T
		if err := mtp.Decode(reader, &value); err != nil {
			return err
		}
		list.values[header.Handle] = value
	}
	// GetData supplies the complete property-list packet.
	var trailing [1]byte
	if n, err := reader.Read(trailing[:]); n != 0 || err != io.EOF {
		return errInvalidPropertyList
	}
	return nil
}
