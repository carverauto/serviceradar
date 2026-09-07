//go:build !tinygo

package sdk

// Alloc reserves a buffer and returns a non-zero placeholder pointer.
func Alloc(size uint32) uint32 {
	if size == 0 {
		return 0
	}
	return 1
}

// Dealloc is a no-op in the stub build.
func Dealloc(_ uint32, _ uint32) {}
