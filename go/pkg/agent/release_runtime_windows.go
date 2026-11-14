//go:build windows

package agent

import "os"

func validateRootOwnedFile(info os.FileInfo) error {
	return errReleaseUpdaterOwnershipUnknown
}

func fileDeviceInode(os.FileInfo) string {
	return "dev=?:ino=?"
}
