//go:build !windows

package agent

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

var errReleaseUpdaterOwnershipInvalid = errors.New("release updater must be owned by root")

func validateRootOwnedFile(info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errReleaseUpdaterOwnershipUnknown
	}
	if stat.Uid != 0 {
		return errReleaseUpdaterOwnershipInvalid
	}
	return nil
}

func fileDeviceInode(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "dev=?:ino=?"
	}

	return fmt.Sprintf("dev=%d:ino=%d", stat.Dev, stat.Ino)
}
