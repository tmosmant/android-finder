package main

import (
	"errors"
	"os"
	"strconv"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

type thumbnailOutput struct {
	remaining int64
}

func (output *thumbnailOutput) Write(data []byte) (int, error) {
	if int64(len(data)) > output.remaining {
		return 0, errors.New("thumbnail transfer exceeded its size limit")
	}
	n, err := os.Stdout.Write(data)
	output.remaining -= int64(n)
	return n, err
}

func thumbnail(device *mtp.Device, args []string) error {
	if len(args) != 4 {
		return errors.New("expected an object handle, name, and size limit")
	}
	handle, err := strconv.ParseUint(args[1], 10, 32)
	if err != nil {
		return err
	}
	limit, err := strconv.ParseUint(args[3], 10, 32)
	if err != nil {
		return err
	}
	var info mtp.ObjectInfo
	if err := device.GetObjectInfo(uint32(handle), &info); err != nil {
		return err
	}
	if info.Filename != args[2] || info.ObjectFormat == mtp.OFC_Association {
		return nil
	}

	const embeddedLimit = 512 * 1024
	if info.ThumbCompressedSize > 0 && info.ThumbCompressedSize <= embeddedLimit {
		req := mtp.Container{Code: mtp.OC_GetThumb, Param: []uint32{uint32(handle)}}
		var response mtp.Container
		return device.RunTransaction(&req, &response, &thumbnailOutput{embeddedLimit}, nil, 0, mtp.EmptyProgressFunc)
	}
	if limit > 0 && uint64(info.CompressedSize) <= limit {
		return device.GetObject(uint32(handle), &thumbnailOutput{int64(limit)}, mtp.EmptyProgressFunc)
	}
	return nil
}
