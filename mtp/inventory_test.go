package main

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

func TestInventoryProperties(t *testing.T) {
	const size = uint64(5_000_000_000)
	var packet bytes.Buffer
	write := func(value any) {
		t.Helper()
		if err := binary.Write(&packet, binary.LittleEndian, value); err != nil {
			t.Fatal(err)
		}
	}
	write(uint32(1))
	write(uint32(42))
	write(uint16(mtp.OPC_ObjectSize))
	write(uint16(mtp.DTC_UINT64))
	write(size)

	list := inventoryProperties[mtp.Uint64Value]{code: mtp.OPC_ObjectSize, kind: mtp.DTC_UINT64}
	valid := packet.Bytes()
	if err := list.Decode(bytes.NewReader(valid)); err != nil || list.values[42].Value != size {
		t.Fatalf("64-bit file size did not decode: %v, %v", list.values, err)
	}

	wrongProperty := append([]byte(nil), valid...)
	binary.LittleEndian.PutUint16(wrongProperty[8:10], mtp.OPC_ObjectFormat)
	for name, malformed := range map[string][]byte{
		"truncated":      valid[:len(valid)-1],
		"extra":          append(append([]byte(nil), valid...), 1),
		"wrong property": wrongProperty,
	} {
		t.Run(name, func(t *testing.T) {
			if err := list.Decode(bytes.NewReader(malformed)); err == nil {
				t.Fatal("accepted an invalid property list")
			}
		})
	}
}
