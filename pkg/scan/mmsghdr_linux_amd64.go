//go:build linux && amd64

package scan

import (
	"golang.org/x/sys/unix"
	"unsafe"
)

// Mmsghdr represents the mmsghdr struct for amd64 architecture
// This matches the C struct mmsghdr layout on 64-bit systems
type Mmsghdr struct {
	Hdr    unix.Msghdr
	MsgLen uint32
	_      uint32 // required padding on amd64 so sizeof matches C's struct mmsghdr
}

// sendmmsg wraps the sendmmsg system call for amd64
func sendmmsg(fd int, msgvec []Mmsghdr, flags int) (int, error) {
	var p unsafe.Pointer
	if len(msgvec) > 0 {
		p = unsafe.Pointer(&msgvec[0])
	}
	r1, _, errno := unix.Syscall6(unix.SYS_SENDMMSG, uintptr(fd), uintptr(p), uintptr(len(msgvec)), uintptr(flags), 0, 0)
	if errno != 0 {
		return int(r1), errno
	}
	return int(r1), nil
}
