//go:build !windows

package agent

import (
	"os"
	"syscall"
)

// requestSelfTermination asks this process to shut down through the same
// SIGTERM path the service manager uses, so shutdown hooks still run.
func requestSelfTermination() {
	_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
}
