//go:build unix

package edgeonboarding

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

var errHostTrustNotRootControlled = errors.New("host trust directory is not root-controlled")

// establishPrivilegedHostTrust makes the trust directory root-owned and not
// writable by any other user before enrollment publishes identity or CA bytes.
// The canonical parent is corrected first. Any other parent that is still
// caller-writable is refused, because a later chown cannot tell our files
// from a replacement.
func establishPrivilegedHostTrust(configDir string) error {
	parentFD, err := openDirNoFollow(configDir)
	if err != nil {
		return fmt.Errorf("open host trust parent: %w", err)
	}
	defer func() { _ = syscall.Close(parentFD) }()

	canonical := filepath.Clean(configDir) == canonicalAgentConfig
	if err := makeRootControlled(parentFD, canonical); err != nil {
		return err
	}
	// The parent inode is root-controlled before this path is used, so another
	// user cannot retarget it between the check and the create.
	dir := filepath.Join(configDir, hostTrustDirName)
	if err := os.Mkdir(dir, 0o755); err != nil && !os.IsExist(err) {
		return fmt.Errorf("create host trust: %w", err)
	}
	trustFD, err := openDirNoFollow(dir)
	if err != nil {
		return fmt.Errorf("open host trust: %w", err)
	}
	defer func() { _ = syscall.Close(trustFD) }()
	return makeRootControlled(trustFD, true)
}

func makeRootControlled(fd int, establish bool) error {
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return fmt.Errorf("stat host trust: %w", err)
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		return errHostTrustPathNotDirectory
	}
	if rootControlled(st) {
		return nil
	}
	if !establish {
		return errHostTrustNotRootControlled
	}
	if err := syscall.Fchown(fd, 0, 0); err != nil {
		return fmt.Errorf("chown host trust: %w", err)
	}
	if err := syscall.Fchmod(fd, exclusiveDirMode(statMode(st))); err != nil {
		return fmt.Errorf("chmod host trust: %w", err)
	}
	if err := syscall.Fstat(fd, &st); err != nil {
		return fmt.Errorf("stat host trust: %w", err)
	}
	if !rootControlled(st) {
		return errHostTrustNotRootControlled
	}
	return nil
}

// statMode widens Stat_t.Mode. Darwin, Dragonfly, and FreeBSD store it as
// uint16; Linux and the other unix targets store it as uint32. Widening
// through uint64 keeps one conversion that compiles on both widths.
func statMode(st syscall.Stat_t) uint32 {
	return uint32(uint64(st.Mode))
}

func rootControlled(st syscall.Stat_t) bool {
	return st.Uid == 0 && st.Mode&0o022 == 0 && st.Mode&syscall.S_IFMT == syscall.S_IFDIR
}

func exclusiveDirMode(mode uint32) uint32 {
	perm := mode & 0o777
	perm &^= 0o022
	if perm&0o400 == 0 {
		return 0o755
	}
	return perm
}

func openDirNoFollow(path string) (int, error) {
	return syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
}
