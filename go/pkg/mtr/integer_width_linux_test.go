package mtr

import (
	"errors"
	"math"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// A classic BPF program's length is a uint16. A longer program must be refused
// before SO_ATTACH_FILTER, which would otherwise install the truncated length.
func TestAttachFilterRejectsAProgramLongerThanTheBPFLengthField(t *testing.T) {
	t.Parallel()

	tooLong := make([]unix.SockFilter, math.MaxUint16+1)
	if err := attachFilter(-1, tooLong); !errors.Is(err, errIntegerWidth) {
		t.Fatalf("program of %d instructions returned %v", len(tooLong), err)
	}

	short := []unix.SockFilter{{Code: unix.BPF_RET | unix.BPF_K}}
	err := attachFilter(-1, short)
	if err == nil || errors.Is(err, errIntegerWidth) {
		t.Fatalf("one-instruction program should reach the socket, got %v", err)
	}

	var errno syscall.Errno
	if !errors.As(err, &errno) {
		t.Fatalf("one-instruction program should fail at the socket, got %v", err)
	}
}
