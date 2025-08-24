// pkg/scan/mmsghdr_linux_arm64.go
//go:build linux && arm64

package scan

import (
	"unsafe"

	"golang.org/x/sys/unix"
)

type Mmsghdr struct {
	Hdr    unix.Msghdr
	MsgLen uint32
	_      uint32 // padding to match C struct alignment on arm64
}

func sendmmsg(fd int, msgvec []Mmsghdr, flags int) (int, error) {
	var p unsafe.Pointer

	if len(msgvec) > 0 {
		p = unsafe.Pointer(&msgvec[0])
	}

	r1, _, errno := unix.Syscall6(unix.SYS_SENDMMSG, uintptr(fd), uintptr(p),
		uintptr(len(msgvec)), uintptr(flags), 0, 0)

	if errno != 0 {
		return int(r1), errno
	}

	return int(r1), nil
}
