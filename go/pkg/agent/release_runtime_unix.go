//go:build !windows

package agent

import (
	"os"
	"syscall"
)

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
