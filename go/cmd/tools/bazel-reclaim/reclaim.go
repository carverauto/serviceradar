// Stale Bazel output-base discovery and classification.
//
// Bazel keys each output base on the workspace path, so every git worktree
// gets its own multi-gigabyte base under the output user root. Removing the
// worktree does not remove the base. A base is stale only when its workspace
// is gone: the path does not exist, the linked worktree's gitdir does not
// exist, git reports that path is not a repository, or a successful
// `git worktree list --porcelain` omits it. A stat or git failure that does
// not prove the workspace is gone keeps the base. A live checkout is never
// stale, because other sessions on the same workstation share these roots.
package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// Base is one Bazel output base and the workspace it serves.
type Base struct {
	Path      string
	Workspace string
}

// Verdict is the reclaim decision for one output base.
type Verdict int

const (
	VerdictKeep Verdict = iota
	VerdictStale
	VerdictSkipLiveServer
)

func (v Verdict) String() string {
	switch v {
	case VerdictStale:
		return "stale"
	case VerdictSkipLiveServer:
		return "skip-live-server"
	case VerdictKeep:
		return "keep"
	default:
		return "keep"
	}
}

// probe abstracts the host lookups classification needs so tests can run on
// synthetic trees without a real git or process table.
type probe struct {
	worktreePaths func(workspace string) ([]string, error)
	pidAlive      func(pid int) bool
}

func defaultProbe() probe {
	return probe{
		worktreePaths: gitWorktreePaths,
		pidAlive: func(pid int) bool {
			err := syscall.Kill(pid, 0)
			return err == nil || errors.Is(err, syscall.EPERM)
		},
	}
}

// discoverBases lists the output bases directly under each output user root.
// A directory counts as an output base when it carries the DO_NOT_BUILD_HERE
// marker Bazel writes with the workspace path.
func discoverBases(roots []string) ([]Base, error) {
	var bases []Base

	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			return nil, fmt.Errorf("read output user root %s: %w", root, err)
		}

		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}

			basePath := filepath.Join(root, entry.Name())

			marker, err := os.ReadFile(filepath.Join(basePath, "DO_NOT_BUILD_HERE"))
			if err != nil {
				continue
			}

			bases = append(bases, Base{
				Path:      basePath,
				Workspace: strings.TrimSpace(string(marker)),
			})
		}
	}

	return bases, nil
}

// classify decides whether a base can be reclaimed. A live Bazel server
// always wins: its base must not be deleted from under it. Stale means the
// workspace is positively gone. Any other stat or git failure keeps the base.
func classify(b Base, p probe) (Verdict, string) {
	if pid, ok := serverPID(b.Path); ok && p.pidAlive(pid) {
		return VerdictSkipLiveServer, fmt.Sprintf("bazel server pid %d alive", pid)
	}

	info, err := os.Stat(b.Workspace)
	if err != nil {
		if os.IsNotExist(err) {
			return VerdictStale, "workspace path no longer exists"
		}

		return VerdictKeep, "workspace path unreadable: " + err.Error()
	}

	if !info.IsDir() {
		return VerdictStale, "workspace path no longer exists"
	}

	// A .git file means a linked worktree. The directory can outlive its
	// registration (worktree removed without deleting files), so confirm the
	// workspace is still registered with its backing repository.
	gitPath := filepath.Join(b.Workspace, ".git")

	gitInfo, err := os.Stat(gitPath)
	if err != nil || gitInfo.IsDir() {
		return VerdictKeep, "workspace exists"
	}

	if missing, ok := gitdirMissing(gitPath); ok && missing {
		return VerdictStale, "worktree gitdir no longer exists"
	}

	registered, listErr := p.worktreePaths(b.Workspace)
	if listErr != nil {
		if worktreeRegistrationGone(listErr) {
			return VerdictStale, "worktree registration no longer exists: " + errText(listErr)
		}

		return VerdictKeep, "worktree registration unreadable: " + errText(listErr)
	}

	if !containsPath(registered, b.Workspace) {
		return VerdictStale, "worktree no longer registered with its backing repo"
	}

	return VerdictKeep, "workspace exists"
}

// gitdirMissing reports whether a linked worktree's gitdir target is absent.
// ok is false when the .git file or the target cannot be read, which is not
// proof that the registration was removed.
func gitdirMissing(gitFile string) (missing bool, ok bool) {
	raw, err := os.ReadFile(gitFile)
	if err != nil {
		return false, false
	}

	var target string

	for _, line := range strings.Split(string(raw), "\n") {
		rest, found := strings.CutPrefix(strings.TrimSpace(line), "gitdir:")
		if !found {
			continue
		}

		target = strings.TrimSpace(rest)

		break
	}

	if target == "" {
		return false, false
	}

	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(gitFile), target)
	}

	_, err = os.Stat(target)
	if err == nil {
		return false, true
	}

	if os.IsNotExist(err) {
		return true, true
	}

	return false, false
}

// worktreeRegistrationGone is true only when git itself reports that the
// worktree path is not a repository, which is how a removed gitdir shows up.
// Other failures (git missing, safe.directory, a non-zero exit while the
// gitdir still exists) are not proof the worktree is gone.
func worktreeRegistrationGone(err error) bool {
	if err == nil {
		return false
	}

	msg := errText(err)

	return strings.Contains(strings.ToLower(msg), "not a git repository")
}

func errText(err error) string {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if msg := strings.TrimSpace(string(exitErr.Stderr)); msg != "" {
			return msg
		}

		if exitErr.ProcessState != nil {
			return exitErr.Error()
		}

		return "git worktree list failed"
	}

	return err.Error()
}

func serverPID(basePath string) (int, bool) {
	raw, err := os.ReadFile(filepath.Join(basePath, "server", "server.pid.txt"))
	if err != nil {
		return 0, false
	}

	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return 0, false
	}

	return pid, true
}

func gitWorktreePaths(workspace string) ([]string, error) {
	out, err := exec.CommandContext(context.Background(), "git", "-C", workspace, "worktree", "list", "--porcelain").Output()
	if err != nil {
		return nil, err
	}

	var paths []string

	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "worktree "); ok {
			paths = append(paths, strings.TrimSpace(rest))
		}
	}

	return paths, nil
}

func containsPath(paths []string, target string) bool {
	cleanTarget := filepath.Clean(target)

	for _, p := range paths {
		if filepath.Clean(p) == cleanTarget {
			return true
		}
	}

	return false
}

// dirSize sums file sizes under root without following symlinks.
func dirSize(root string) int64 {
	var total int64

	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}

		if info, infoErr := d.Info(); infoErr == nil {
			total += info.Size()
		}

		return nil
	})

	return total
}
