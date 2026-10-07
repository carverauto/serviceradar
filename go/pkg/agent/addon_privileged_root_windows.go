//go:build windows

package agent

import "fmt"

func writeAddonStateFileNoFollow(dir, name string, data []byte) error {
	return fmt.Errorf("%w: %s/%s (%d bytes)", ErrAddonPrivilegedRootUnsafe, dir, name, len(data))
}

func PrivilegedRootForSetuidInstall(_, _ string) (string, error) {
	return "", ErrAddonPrivilegedRootUnsafe
}

func effectivePrivilegedAddonRoot(privilegedRoot, runtimeRoot string) (string, error) {
	return resolvePrivilegedAddonRoot(privilegedRoot, runtimeRoot), nil
}
