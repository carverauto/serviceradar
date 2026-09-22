//go:build windows

package agent

import "os"

// requestSelfTermination ends the process so the Windows service manager's
// recovery action restarts it. Windows cannot deliver SIGTERM to itself, so
// this exits without running the signal-driven shutdown path.
func requestSelfTermination() {
	os.Exit(0)
}
