// Stale Bazel output-base discovery and classification.
//
// Bazel keys each output base on the workspace path, so every git worktree
// gets its own multi-gigabyte base under the output user root. Removing the
// worktree does not remove the base. A base is stale only when its workspace
// is gone: the path does not exist, the linked worktree's gitdir does not
// exist, git reports "not a git repository" and the readable gitdir has
// neither HEAD nor commondir, or a successful `git worktree list --porcelain`
// omits it. That list is taken with
// GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR, and GIT_OBJECT_DIRECTORY cleared,
// so an inherited environment cannot point git at another repository.
// A stat or git failure that does not prove the workspace is gone keeps the
// base. A live checkout is never stale, because other sessions on the same
// workstation share these roots.
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
	pid, pidErr := serverPID(b.Path)
	if pidErr != nil {
		return VerdictKeep, "bazel server pid uncertain: " + pidErr.Error()
	}
	if pid > 0 && p.pidAlive(pid) {
		return VerdictSkipLiveServer, fmt.Sprintf("bazel server pid %d alive", pid)
	}

	_, err := os.Stat(b.Workspace)
	if err != nil {
		if os.IsNotExist(err) {
			return VerdictStale, "workspace path no longer exists"
		}

		return VerdictKeep, "workspace path unreadable: " + err.Error()
	}

	// A .git file means a linked worktree. The directory can outlive its
	// registration (worktree removed without deleting files), so confirm the
	// workspace is still registered with its backing repository.
	gitPath := filepath.Join(b.Workspace, ".git")

	gitInfo, err := os.Stat(gitPath)
	if err != nil || gitInfo.IsDir() {
		return VerdictKeep, "workspace exists"
	}

	missing, ok := gitdirMissing(gitPath)
	if !ok {
		return VerdictKeep, "worktree gitdir unreadable"
	}

	if missing {
		return VerdictStale, "worktree gitdir no longer exists"
	}

	registered, listErr := p.worktreePaths(b.Workspace)
	if listErr != nil {
		if worktreeRegistrationGone(listErr) && gitdirRegistrationMissing(gitPath) {
			return VerdictStale, "worktree registration no longer exists: " + errText(listErr)
		}

		return VerdictKeep, "worktree registration unreadable: " + errText(listErr)
	}

	if !containsPath(registered, b.Workspace) {
		return VerdictStale, "worktree no longer registered with its backing repo"
	}

	return VerdictKeep, "workspace exists"
}

func gitdirTarget(gitFile string) (string, bool) {
	raw, err := os.ReadFile(gitFile)
	if err != nil {
		return "", false
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
		return "", false
	}

	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(gitFile), target)
	}

	return target, true
}

// gitdirMissing reports whether a linked worktree's gitdir target is absent.
// ok is false when the .git file or the target cannot be read, which is not
// proof that the registration was removed.
func gitdirMissing(gitFile string) (missing bool, ok bool) {
	target, ok := gitdirTarget(gitFile)
	if !ok {
		return false, false
	}

	info, err := os.Stat(target)
	if err != nil {
		if os.IsNotExist(err) {
			return true, true
		}

		return false, false
	}

	if !info.IsDir() {
		return false, false
	}

	if _, err = os.ReadDir(target); err != nil {
		return false, false
	}

	return false, true
}

func gitdirRegistrationMissing(gitFile string) bool {
	target, ok := gitdirTarget(gitFile)
	if !ok {
		return false
	}

	for _, name := range []string{"HEAD", "commondir"} {
		if _, err := os.Stat(filepath.Join(target, name)); !os.IsNotExist(err) {
			return false
		}
	}

	return true
}

// worktreeRegistrationGone is true only when git reports that the path is
// not a repository. Other failures are not proof the worktree is gone.
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

func serverPID(basePath string) (int, error) {
	raw, err := os.ReadFile(filepath.Join(basePath, "server", "server.pid.txt"))
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}

	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return 0, errors.New("invalid server PID")
	}

	return pid, nil
}

func gitWorktreePaths(workspace string) ([]string, error) {
	cmd := exec.CommandContext(context.Background(), "git", "-C", workspace, "worktree", "list", "--porcelain")
	cmd.Env = withoutEnv(os.Environ(), "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")

	out, err := cmd.Output()
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

func withoutEnv(env []string, drop ...string) []string {
	skip := make(map[string]struct{}, len(drop))
	for _, key := range drop {
		skip[key] = struct{}{}
	}

	kept := make([]string, 0, len(env))

	for _, kv := range env {
		key, _, _ := strings.Cut(kv, "=")
		if _, ok := skip[key]; ok {
			continue
		}

		kept = append(kept, kv)
	}

	return kept
}

func containsPath(paths []string, target string) bool {
	for _, p := range paths {
		if samePath(p, target) {
			return true
		}
	}

	return false
}

func samePath(a, b string) bool {
	if filepath.Clean(a) == filepath.Clean(b) {
		return true
	}

	infoA, errA := os.Stat(a)
	infoB, errB := os.Stat(b)
	if errA != nil || errB != nil {
		return false
	}

	return os.SameFile(infoA, infoB)
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
