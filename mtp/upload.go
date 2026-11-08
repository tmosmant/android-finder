package main

import (
	"crypto/rand"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	mtpx "github.com/ganeshrvel/go-mtpx"
)

func uploadSelection(device *mtp.Device, storage, parent uint32, sources []string) error {
	for completed, source := range sources {
		if err := uploadItem(device, storage, parent, source); err != nil {
			return fmt.Errorf("%d élément(s) sur %d copiés. %w", completed, len(sources), err)
		}
	}
	return nil
}

func uploadItem(device *mtp.Device, storage, parent uint32, source string) error {
	name := filepath.Base(source)
	if _, err := mtpx.GetObjectFromParentIdAndFilename(device, storage, parent, name); err == nil {
		return fmt.Errorf("cet élément existe déjà : %s", name)
	} else {
		var missing mtpx.FileNotFoundError
		if !errors.As(err, &missing) {
			return err
		}
	}

	var idBytes [16]byte
	if _, err := rand.Read(idBytes[:]); err != nil {
		return err
	}
	tempName := fmt.Sprintf("AndroidFinder-incomplet-%x", idBytes)
	handle, err := send(device, storage, parent, source, tempName)
	if err == nil {
		err = device.SetObjectPropValue(handle, mtp.OPC_ObjectFileName, &mtp.StringValue{Value: name})
		if err == nil {
			return nil
		}
		// A lost reply could mean the rename succeeded. Leave the complete object alone.
		return fmt.Errorf("finalisation de %q non confirmée. Après reconnexion, vérifie %q et supprime %q s’il reste présent : %w", name, name, tempName, err)
	}
	if handle != 0 && device.DeleteObject(handle) == nil {
		return fmt.Errorf("copie de %q interrompue, élément temporaire supprimé : %w", name, err)
	}
	return fmt.Errorf("copie de %q interrompue. Après reconnexion, supprime %q s’il est présent : %w", name, tempName, err)
}

func send(device *mtp.Device, storage, parent uint32, source, name string) (uint32, error) {
	info, err := os.Lstat(source)
	if err != nil {
		return 0, err
	}
	object := mtp.ObjectInfo{
		StorageID: storage, ParentObject: parent, Filename: name,
		ObjectFormat: mtp.OFC_Undefined, ModificationDate: info.ModTime(),
	}
	var file *os.File
	if info.IsDir() {
		object.ObjectFormat = mtp.OFC_Association
	} else {
		if !info.Mode().IsRegular() || info.Size() >= math.MaxUint32 {
			return 0, fmt.Errorf("type ou taille non pris en charge : %s", source)
		}
		file, err = os.Open(source)
		if err != nil {
			return 0, err
		}
		defer file.Close()
		object.CompressedSize = uint32(info.Size())
	}
	_, _, handle, err := device.SendObjectInfo(storage, parent, &object)
	if err != nil {
		return handle, err
	}
	if !info.IsDir() {
		return handle, device.SendObject(file, info.Size(), func(_ int64) error { return nil })
	}
	children, err := os.ReadDir(source)
	if err != nil {
		return handle, err
	}
	for _, child := range children {
		if _, err := send(device, storage, handle, filepath.Join(source, child.Name()), child.Name()); err != nil {
			return handle, err
		}
	}
	return handle, nil
}
