//go:build tinygo

package sdk

import "unsafe"

var allocations = map[uint32][]byte{}

//export alloc
func alloc(size uint32) uint32 {
	if size == 0 {
		return 0
	}

	buf := make([]byte, size)
	ptr := uint32(uintptr(unsafe.Pointer(&buf[0])))
	allocations[ptr] = buf

	return ptr
}

//export dealloc
func dealloc(ptr uint32, _ uint32) {
	delete(allocations, ptr)
}

// Alloc reserves a buffer and returns its pointer.
func Alloc(size uint32) uint32 {
	return alloc(size)
}

// Dealloc releases a previously allocated buffer.
func Dealloc(ptr uint32, size uint32) {
	dealloc(ptr, size)
}
