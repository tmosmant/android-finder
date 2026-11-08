package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	mtpx "github.com/ganeshrvel/go-mtpx"
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

	device, err := mtpx.Initialize(mtpx.Init{})
	if err != nil {
		return err
	}
	defer mtpx.Dispose(device)

	storages, err := mtpx.FetchStorages(device)
	if err != nil {
		return err
	}
	if len(storages) == 0 {
		return errors.New("aucun stockage Android accessible")
	}
	storage := storages[0].Sid
	operation, remote := args[0], args[1]

	switch operation {
	case "list":
		entries := []entry{}
		_, _, _, err := mtpx.Walk(device, storage, remote, false, false, false,
			func(_ uint32, info *mtpx.FileInfo, err error) error {
				if err != nil {
					return err
				}
				entries = append(entries, entry{info.Name, info.FullPath, info.IsDir, info.Size})
				return nil
			})
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(entries)
	case "download":
		if len(args) != 3 || remote == "/" {
			return errors.New("expected a file or folder and a destination directory")
		}
		info, err := mtpx.GetObjectFromPath(device, storage, remote)
		if err != nil {
			return err
		}
		return download(device, storage, info, args[2])
	case "upload":
		if len(args) < 3 {
			return errors.New("expected at least one local path")
		}
		folder, err := mtpx.GetObjectFromPath(device, storage, remote)
		if err != nil {
			return err
		}
		if !folder.IsDir {
			return errors.New("la destination Android n’est pas un dossier")
		}
		return uploadSelection(device, storage, folder.ObjectId, args[2:])
	case "delete":
		for _, target := range args[1:] {
			if target == "/" {
				return errors.New("impossible de supprimer la racine du stockage")
			}
			info, err := mtpx.GetObjectFromPath(device, storage, target)
			if err != nil {
				return err
			}
			if err := device.DeleteObject(info.ObjectId); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unknown operation %q", operation)
	}
}

// Copy into a staging directory. Any unreadable object fails the entire copy.
func download(device *mtp.Device, storage uint32, info *mtpx.FileInfo, parent string) error {
	if info.Name == "" || info.Name == "." || info.Name == ".." || filepath.Base(info.Name) != info.Name {
		return fmt.Errorf("nom de fichier Android invalide : %q", info.Name)
	}
	destination := filepath.Join(parent, info.Name)
	if info.IsDir {
		if err := os.Mkdir(destination, 0755); err != nil {
			return err
		}
		var children mtp.Uint32Array
		if err := device.GetObjectHandles(storage, mtp.GOH_ALL_ASSOCS, info.ObjectId, &children); err != nil {
			return err
		}
		for _, id := range children.Values {
			child, err := mtpx.GetObjectFromObjectId(device, id, info.FullPath)
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
		transferErr := device.GetObject(info.ObjectId, file, func(_ int64) error { return nil })
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
	if !info.ModTime.IsZero() {
		return os.Chtimes(destination, info.ModTime, info.ModTime)
	}
	return nil
}
