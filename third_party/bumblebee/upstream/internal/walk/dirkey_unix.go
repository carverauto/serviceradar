//go:build unix

package walk

import (
	"fmt"
	"os"
	"syscall"
)

func dirKey(path string) (string, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return "", false
	}
	sys, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", false
	}
	return fmt.Sprintf("%d:%d", sys.Dev, sys.Ino), true
}
