//go:build windows

package edgeonboarding

import "fmt"

func establishPrivilegedHostTrust(string) error {
	return fmt.Errorf("privileged host trust requires a unix host")
}
