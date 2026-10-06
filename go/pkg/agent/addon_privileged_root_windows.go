//go:build windows

package agent

func PrivilegedRootForSetuidInstall(_, _ string) (string, error) {
	return "", ErrAddonPrivilegedRootUnsafe
}

func effectivePrivilegedAddonRoot(privilegedRoot, runtimeRoot string) (string, error) {
	return resolvePrivilegedAddonRoot(privilegedRoot, runtimeRoot), nil
}
