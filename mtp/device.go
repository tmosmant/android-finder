package main

import (
	"errors"
	"fmt"
	"math"
	"path"
	"strings"
	"time"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

var errObjectMissing = errors.New(localized("Android item not found", "élément Android introuvable", "no se encontró el elemento en Android"))

type androidObject struct {
	entry
	handle   uint32
	modified time.Time
}

func readObject(device *mtp.Device, handle uint32, parentPath string) (androidObject, error) {
	var info mtp.ObjectInfo
	if err := device.GetObjectInfo(handle, &info); err != nil {
		return androidObject{}, err
	}

	name := info.Filename
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\x00") {
		return androidObject{}, fmt.Errorf(localized("invalid Android file name: %q", "nom de fichier Android invalide : %q", "nombre de archivo de Android no válido: %q"), name)
	}

	isDir := info.ObjectFormat == mtp.OFC_Association
	size := int64(info.CompressedSize)
	if isDir {
		size = 0
	} else if info.CompressedSize == math.MaxUint32 {
		var length mtp.Uint64Value
		if err := device.GetObjectPropValue(handle, mtp.OPC_ObjectSize, &length); err != nil {
			return androidObject{}, err
		}
		if length.Value > math.MaxInt64 {
			return androidObject{}, fmt.Errorf(localized("file too large: %q", "fichier trop volumineux : %q", "archivo demasiado grande: %q"), name)
		}
		size = int64(length.Value)
	}
	return androidObject{
		entry:  entry{Name: name, FullPath: path.Join(parentPath, name), IsDir: isDir, Size: size, Handle: handle},
		handle: handle, modified: info.ModificationDate,
	}, nil
}

func objectHandles(device *mtp.Device, storage, parent uint32) ([]uint32, error) {
	var handles mtp.Uint32Array
	err := device.GetObjectHandles(storage, mtp.GOH_ALL_ASSOCS, parent, &handles)
	return handles.Values, err
}

func findChild(device *mtp.Device, storage, parent uint32, parentPath, name string) (androidObject, error) {
	handles, err := objectHandles(device, storage, parent)
	if err != nil {
		return androidObject{}, err
	}
	for _, handle := range handles {
		var filename mtp.StringValue
		if err := device.GetObjectPropValue(handle, mtp.OPC_ObjectFileName, &filename); err != nil {
			return androidObject{}, err
		}
		if filename.Value == name {
			return readObject(device, handle, parentPath)
		}
	}
	return androidObject{}, fmt.Errorf(localized("%w: %s", "%w : %s", "%w: %s"), errObjectMissing, path.Join(parentPath, name))
}

func findObject(device *mtp.Device, storage uint32, remote string) (androidObject, error) {
	current := androidObject{entry: entry{FullPath: "/", IsDir: true}, handle: mtp.GOH_ROOT_PARENT}
	for _, name := range strings.Split(strings.TrimPrefix(remote, "/"), "/") {
		if name == "" {
			continue
		}
		if !current.IsDir {
			return androidObject{}, fmt.Errorf(localized("this path is not a folder: %s", "ce chemin ne désigne pas un dossier : %s", "esta ruta no corresponde a una carpeta: %s"), current.FullPath)
		}
		child, err := findChild(device, storage, current.handle, current.FullPath, name)
		if err != nil {
			return androidObject{}, err
		}
		current = child
	}
	return current, nil
}
