//go:build windows

package agent

import "os"

func validateRootOwnedFile(info os.FileInfo) error {
	return errReleaseUpdaterOwnershipUnknown
}
