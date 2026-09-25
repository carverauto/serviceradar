//go:build linux || darwin

package mtr

import (
	"syscall"
	"testing"
)

// Closing a probe socket twice must not close a descriptor that reused the
// send descriptor's number after the first close.
//
// Not parallel: it depends on the kernel handing the next socket the lowest
// free descriptor number, which a concurrently running test could take.
func TestRawSocketCloseDoesNotCloseReusedDescriptor(t *testing.T) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("open socket: %v", err)
	}

	sock := newTestRawSocket(fd)
	if err := sock.Close(); err != nil {
		t.Fatalf("first close: %v", err)
	}

	reused, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("open second socket: %v", err)
	}
	defer func() { _ = syscall.Close(reused) }()

	if reused != fd {
		t.Skipf("descriptor %d was not reused (next socket got %d); cannot observe a stray close", fd, reused)
	}

	_ = sock.Close()

	if _, err := syscall.Getsockname(reused); err != nil {
		t.Fatalf("second Close closed descriptor %d, which now belongs to another socket: %v", reused, err)
	}
}
