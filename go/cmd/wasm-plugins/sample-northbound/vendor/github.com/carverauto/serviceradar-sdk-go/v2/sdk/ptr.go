package sdk

import "unsafe"

func ptrFromBytes(data []byte) uint32 {
	if len(data) == 0 {
		return 0
	}

	return uint32(uintptr(unsafe.Pointer(&data[0])))
}
