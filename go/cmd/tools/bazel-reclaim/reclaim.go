// Stale Bazel output-base discovery and classification.
//
// Bazel keys each output base on the workspace path, so every git worktree
// gets its own multi-gigabyte base under the output user root. Removing the
// worktree does not remove the base. A base is stale only when its workspace
// is gone: the path no longer exists, or the path is a leftover directory
// whose git worktree registration was removed. A base whose workspace still
// exists as a live checkout is never stale, because other sessions on the
// same workstation share these roots.
package main

import (
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
			return err == nil || err == syscall.EPERM
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
// always wins: its base must not be deleted from under it.
func classify(b Base, p probe) (Verdict, string) {
	if pid, ok := serverPID(b.Path); ok && p.pidAlive(pid) {
		return VerdictSkipLiveServer, fmt.Sprintf("bazel server pid %d alive", pid)
	}

	info, err := os.Stat(b.Workspace)
	if err != nil || !info.IsDir() {
		return VerdictStale, "workspace path no longer exists"
	}

	// A .git file means a linked worktree. The directory can outlive its
	// registration (worktree removed without deleting files), so confirm the
	// workspace is still registered with its backing repository.
	gitPath := filepath.Join(b.Workspace, ".git")

	gitInfo, err := os.Stat(gitPath)
	if err == nil && !gitInfo.IsDir() {
		registered, listErr := p.worktreePaths(b.Workspace)
		if listErr != nil {
			return VerdictStale, "worktree registration unreadable: " + listErr.Error()
		}

		if !containsPath(registered, b.Workspace) {
			return VerdictStale, "worktree no longer registered with its backing repo"
		}
	}

	return VerdictKeep, "workspace exists"
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
	out, err := exec.Command("git", "-C", workspace, "worktree", "list", "--porcelain").Output()
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
