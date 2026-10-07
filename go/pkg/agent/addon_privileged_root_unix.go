//go:build !windows

package agent

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// PrivilegedRootForSetuidInstall is the only privileged add-on root the setuid
// updater may materialize. Caller-supplied roots are ignored: a serviceradar
// caller must not choose where file capabilities are applied.
func PrivilegedRootForSetuidInstall(_, _ string) (string, error) {
	if err := validatePrivilegedAddonRootOwnership(defaultPrivilegedAddonRoot); err != nil {
		return "", err
	}
	return defaultPrivilegedAddonRoot, nil
}

func effectivePrivilegedAddonRoot(privilegedRoot, runtimeRoot string) (string, error) {
	if os.Geteuid() == 0 && os.Getuid() != 0 {
		return PrivilegedRootForSetuidInstall(privilegedRoot, runtimeRoot)
	}
	return resolvePrivilegedAddonRoot(privilegedRoot, runtimeRoot), nil
}

func validatePrivilegedAddonRootOwnership(root string) error {
	root = filepath.Clean(root)
	var chain []string
	for current := root; ; current = filepath.Dir(current) {
		chain = append(chain, current)
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
	}

	sawDir := false
	for i := len(chain) - 1; i >= 0; i-- {
		info, err := os.Stat(chain[i])
		if errors.Is(err, os.ErrNotExist) {
			if !sawDir {
				return fmt.Errorf("%w: %s", ErrAddonPrivilegedRootUnsafe, chain[i])
			}
			return nil
		}
		if err != nil {
			return fmt.Errorf("%w: %s: %v", ErrAddonPrivilegedRootUnsafe, chain[i], err)
		}
		sawDir = true
		if !info.IsDir() || !rootOwnedNotWritableByCaller(info) {
			return fmt.Errorf("%w: %s", ErrAddonPrivilegedRootUnsafe, chain[i])
		}
	}
	if !sawDir {
		return fmt.Errorf("%w: %s", ErrAddonPrivilegedRootUnsafe, root)
	}
	return nil
}

func rootOwnedNotWritableByCaller(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 {
		return false
	}
	return !writableByUID(info, os.Getuid())
}

func writeAddonStateFileNoFollow(dir, name string, data []byte) error {
	if !safeAddonSegment(name) {
		return fmt.Errorf("%w: %q", ErrAddonUnsafePath, name)
	}
	f, err := os.OpenFile(filepath.Join(dir, name), os.O_WRONLY|os.O_CREATE|os.O_TRUNC|syscall.O_NOFOLLOW, addonManifestMode)
	if err != nil {
		return fmt.Errorf("open addon state file: %w", err)
	}
	defer func() { _ = f.Close() }()
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("write addon state file: %w", err)
	}
	return nil
}

func writableByUID(info os.FileInfo, uid int) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return true
	}
	mode := info.Mode().Perm()
	if int(stat.Uid) == uid && mode&0o200 != 0 {
		return true
	}
	if mode&0o002 != 0 {
		return true
	}
	if mode&0o020 == 0 {
		return false
	}
	if int(stat.Gid) == os.Getgid() {
		return true
	}
	groups, err := os.Getgroups()
	if err != nil {
		return true
	}
	for _, group := range groups {
		if int(stat.Gid) == group {
			return true
		}
	}
	return false
}
