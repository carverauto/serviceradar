//go:build !windows

package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
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
			return fmt.Errorf("%w: %s: %w", ErrAddonPrivilegedRootUnsafe, chain[i], err)
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
	// A real uid of 0 is already root. The setuid threat is a non-root caller
	// (Getuid != 0, Geteuid == 0) who can write a parent and redirect the tree.
	uid := os.Getuid()
	if uid == 0 {
		return true
	}
	return !writableByUID(info, uid)
}

func restoreAddonStateForCaller(runtimeRoot, addonID, snapshotPath string) error {
	if os.Geteuid() == 0 && os.Getuid() != 0 {
		if strings.TrimSpace(snapshotPath) == "" {
			return nil
		}
		if err := checkAddonStateRollbackPath("", addonID, snapshotPath); err != nil {
			return err
		}
		return restoreStateThroughAnchor("/var/lib", addonStateDir("", addonID))
	}
	return restoreAddonStateFromRollback(runtimeRoot, addonID, snapshotPath)
}

func restoreStateThroughAnchor(anchor, stateDir string) error {
	rel, err := filepath.Rel(anchor, stateDir)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return fmt.Errorf("%w: state dir %s", ErrAddonUnsafePath, stateDir)
	}
	dirfd, err := openDirNoFollow(anchor, rel)
	if err != nil {
		return err
	}
	defer func() { _ = unix.Close(dirfd) }()

	data, err := readFileNoFollow(dirfd, ".serviceradar-state-rollback")
	if err != nil {
		return err
	}
	var persisted persistedAddonStateRollback
	if err := json.Unmarshal(data, &persisted); err != nil {
		return fmt.Errorf("decode addon state rollback: %w", err)
	}
	for name, content := range persisted.Files {
		if !safeAddonSegment(name) {
			continue
		}
		if err := writeFileNoFollow(dirfd, name, content); err != nil {
			return err
		}
	}
	return nil
}

func openDirNoFollow(anchor, rel string) (int, error) {
	fd, err := unix.Open(anchor, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return -1, fmt.Errorf("open state anchor: %w", err)
	}
	for _, part := range strings.Split(rel, string(os.PathSeparator)) {
		if !safeAddonSegment(part) {
			_ = unix.Close(fd)
			return -1, fmt.Errorf("%w: %q", ErrAddonUnsafePath, part)
		}
		next, err := unix.Openat(fd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		_ = unix.Close(fd)
		if err != nil {
			return -1, fmt.Errorf("open state dir %s: %w", part, err)
		}
		fd = next
	}
	return fd, nil
}

func readFileNoFollow(dirfd int, name string) ([]byte, error) {
	fd, err := unix.Openat(dirfd, name, unix.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open addon state rollback: %w", err)
	}
	f := os.NewFile(uintptr(fd), name)
	defer func() { _ = f.Close() }()
	return io.ReadAll(f)
}

func writeFileNoFollow(dirfd int, name string, data []byte) error {
	fd, err := unix.Openat(dirfd, name, unix.O_WRONLY|unix.O_CREAT|unix.O_TRUNC|unix.O_NOFOLLOW, addonManifestMode)
	if err != nil {
		return fmt.Errorf("open addon state file: %w", err)
	}
	f := os.NewFile(uintptr(fd), name)
	defer func() { _ = f.Close() }()
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("write addon state file: %w", err)
	}
	return nil
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
