package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

type entry struct {
	Name     string
	FullPath string
	IsDir    bool
	Size     int64
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 2 {
		return errors.New("expected an operation and an Android path")
	}

	device, err := mtp.SelectDevice("")
	if err != nil {
		return err
	}
	defer device.Close()
	device.Timeout = 15000
	if err := device.Configure(); err != nil {
		return err
	}

	var storages mtp.Uint32Array
	if err := device.GetStorageIDs(&storages); err != nil {
		return err
	}
	if len(storages.Values) == 0 {
		return errors.New("aucun stockage Android accessible")
	}
	storage := storages.Values[0]
	operation, remote := args[0], args[1]

	switch operation {
	case "list":
		folder, err := findObject(device, storage, remote)
		if err != nil {
			return err
		}
		if !folder.IsDir {
			return fmt.Errorf("ce chemin ne désigne pas un dossier : %s", remote)
		}
		handles, err := objectHandles(device, storage, folder.handle)
		if err != nil {
			return err
		}
		entries := make([]entry, 0, len(handles))
		for _, handle := range handles {
			info, err := readObject(device, handle, folder.FullPath)
			if err != nil {
				return err
			}
			entries = append(entries, info.entry)
		}
		return json.NewEncoder(os.Stdout).Encode(entries)
	case "download":
		if len(args) != 3 || remote == "/" {
			return errors.New("expected a file or folder and a destination directory")
		}
		info, err := findObject(device, storage, remote)
		if err != nil {
			return err
		}
		return download(device, storage, info, args[2])
	case "upload":
		if len(args) < 3 {
			return errors.New("expected at least one local path")
		}
		folder, err := findObject(device, storage, remote)
		if err != nil {
			return err
		}
		if !folder.IsDir {
			return errors.New("la destination Android n’est pas un dossier")
		}
		return uploadSelection(device, storage, folder.handle, args[2:])
	case "delete":
		for _, target := range args[1:] {
			if target == "/" {
				return errors.New("impossible de supprimer la racine du stockage")
			}
			info, err := findObject(device, storage, target)
			if err != nil {
				return err
			}
			if err := device.DeleteObject(info.handle); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unknown operation %q", operation)
	}
}

// Copy into a staging directory. Any unreadable object fails the entire copy.
func download(device *mtp.Device, storage uint32, info androidObject, parent string) error {
	if info.Name == "" || info.Name == "." || info.Name == ".." || filepath.Base(info.Name) != info.Name {
		return fmt.Errorf("nom de fichier Android invalide : %q", info.Name)
	}
	destination := filepath.Join(parent, info.Name)
	if info.IsDir {
		if err := os.Mkdir(destination, 0755); err != nil {
			return err
		}
		children, err := objectHandles(device, storage, info.handle)
		if err != nil {
			return err
		}
		for _, id := range children {
			child, err := readObject(device, id, info.FullPath)
			if err != nil {
				return err
			}
			if err := download(device, storage, child, destination); err != nil {
				return err
			}
		}
	} else {
		file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
		if err != nil {
			return err
		}
		transferErr := device.GetObject(info.handle, file, func(_ int64) error { return nil })
		closeErr := file.Close()
		if err := errors.Join(transferErr, closeErr); err != nil {
			return err
		}
		local, err := os.Stat(destination)
		if err != nil {
			return err
		}
		if local.Size() != info.Size {
			return fmt.Errorf("copie incomplète : %s (%d / %d octets)", info.Name, local.Size(), info.Size)
		}
	}
	if !info.modified.IsZero() {
		return os.Chtimes(destination, info.modified, info.modified)
	}
	return nil
}
