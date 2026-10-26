package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var (
	errGitNotOnPath    = errors.New("executable file not found in $PATH")
	errDubiousGitOwner = errors.New("fatal: detected dubious ownership in repository")
)

// makeBase creates a synthetic output base for workspace under root.
func makeBase(t *testing.T, root, name, workspace string) Base {
	t.Helper()

	basePath := filepath.Join(root, name)

	if err := os.MkdirAll(basePath, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(basePath, "DO_NOT_BUILD_HERE"), []byte(workspace+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	return Base{Path: basePath, Workspace: workspace}
}

func makeWorkspace(t *testing.T, dir, name string, gitDir bool) string {
	t.Helper()

	ws := filepath.Join(dir, name)

	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}

	if gitDir {
		if err := os.MkdirAll(filepath.Join(ws, ".git"), 0o755); err != nil {
			t.Fatal(err)
		}
	} else if err := os.WriteFile(filepath.Join(ws, ".git"), []byte("gitdir: "+filepath.Join(dir, "main", ".git", "worktrees", name)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	return ws
}

// materializeGitdir creates the directory named by a linked worktree's gitdir
// line so classification reaches the worktree list instead of the missing-gitdir path.
func materializeGitdir(t *testing.T, workspace string) {
	t.Helper()

	raw, err := os.ReadFile(filepath.Join(workspace, ".git"))
	if err != nil {
		t.Fatal(err)
	}

	rest, ok := strings.CutPrefix(strings.TrimSpace(string(raw)), "gitdir:")
	if !ok {
		t.Fatalf("%s .git file has no gitdir line", workspace)
	}

	if err := os.MkdirAll(strings.TrimSpace(rest), 0o755); err != nil {
		t.Fatal(err)
	}
}

func deadProbe() probe {
	return probe{
		worktreePaths: func(string) ([]string, error) { return nil, nil },
		pidAlive:      func(int) bool { return false },
	}
}

func TestDiscoverBasesSkipsNonBases(t *testing.T) {
	root := t.TempDir()
	want := makeBase(t, root, "abc123", "/synthetic/checkout")

	if err := os.MkdirAll(filepath.Join(root, "not-a-base"), 0o755); err != nil {
		t.Fatal(err)
	}

	bases, err := discoverBases([]string{root})
	if err != nil {
		t.Fatal(err)
	}

	if len(bases) != 1 || bases[0] != want {
		t.Fatalf("discoverBases = %+v, want [%+v]", bases, want)
	}
}

func TestClassify(t *testing.T) {
	root := t.TempDir()
	wsDir := t.TempDir()

	mainCheckout := makeWorkspace(t, wsDir, "main", true)
	registered := makeWorkspace(t, wsDir, "feature", false)
	materializeGitdir(t, registered)
	unregistered := makeWorkspace(t, wsDir, "leftover", false)
	materializeGitdir(t, unregistered)
	missingGitdir := makeWorkspace(t, wsDir, "pruned", false)
	relKeep := makeWorkspace(t, wsDir, "relkeep", false)
	relGitdir := filepath.Join(wsDir, ".git", "worktrees", "relkeep")
	if err := os.MkdirAll(relGitdir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(relKeep, ".git"), []byte("gitdir: ../.git/worktrees/relkeep\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(wsDir, "removed")

	liveBase := makeBase(t, root, "live", gone)
	if err := os.MkdirAll(filepath.Join(liveBase.Path, "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveBase.Path, "server", "server.pid.txt"), []byte("4242\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name  string
		base  Base
		probe probe
		want  Verdict
	}{
		{
			name:  "workspace gone is stale",
			base:  makeBase(t, root, "gone", gone),
			probe: deadProbe(),
			want:  VerdictStale,
		},
		{
			name:  "main checkout is kept",
			base:  makeBase(t, root, "main", mainCheckout),
			probe: deadProbe(),
			want:  VerdictKeep,
		},
		{
			name: "registered worktree is kept",
			base: makeBase(t, root, "feature", registered),
			probe: probe{
				worktreePaths: func(string) ([]string, error) { return []string{mainCheckout, registered}, nil },
				pidAlive:      func(int) bool { return false },
			},
			want: VerdictKeep,
		},
		{
			name: "unregistered worktree directory is stale",
			base: makeBase(t, root, "leftover", unregistered),
			probe: probe{
				worktreePaths: func(string) ([]string, error) { return []string{mainCheckout}, nil },
				pidAlive:      func(int) bool { return false },
			},
			want: VerdictStale,
		},
		{
			name: "missing gitdir is stale when git cannot be asked",
			base: makeBase(t, root, "pruned", missingGitdir),
			probe: probe{
				worktreePaths: func(string) ([]string, error) { return nil, errGitNotOnPath },
				pidAlive:      func(int) bool { return false },
			},
			want: VerdictStale,
		},
		{
			name: "git reports missing repository is stale",
			base: makeBase(t, root, "notrepo", unregistered),
			probe: probe{
				worktreePaths: func(string) ([]string, error) {
					return nil, &exec.ExitError{Stderr: []byte("fatal: not a git repository: /synthetic/gitdir\n")}
				},
				pidAlive: func(int) bool { return false },
			},
			want: VerdictStale,
		},
		{
			name: "other git failure keeps the base",
			base: makeBase(t, root, "uncertain", unregistered),
			probe: probe{
				worktreePaths: func(string) ([]string, error) {
					return nil, errDubiousGitOwner
				},
				pidAlive: func(int) bool { return false },
			},
			want: VerdictKeep,
		},
		{
			name: "relative gitdir that exists is kept when registered",
			base: makeBase(t, root, "relkeep", relKeep),
			probe: probe{
				worktreePaths: func(string) ([]string, error) { return []string{relKeep}, nil },
				pidAlive:      func(int) bool { return false },
			},
			want: VerdictKeep,
		},
		{
			name: "live server is never reclaimed",
			base: liveBase,
			probe: probe{
				worktreePaths: func(string) ([]string, error) { return nil, nil },
				pidAlive:      func(pid int) bool { return pid == 4242 },
			},
			want: VerdictSkipLiveServer,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got, _ := classify(tc.base, tc.probe); got != tc.want {
				t.Fatalf("classify = %s, want %s", got, tc.want)
			}
		})
	}
}

func TestRunApplyDeletesOnlyStaleBases(t *testing.T) {
	root := t.TempDir()
	wsDir := t.TempDir()

	keepWS := makeWorkspace(t, wsDir, "main", true)
	keep := makeBase(t, root, "keep", keepWS)
	stale := makeBase(t, root, "stale", filepath.Join(wsDir, "removed"))

	// Dry-run first: nothing may be removed.
	if err := run([]string{root}, false, false, deadProbe()); err != nil {
		t.Fatal(err)
	}

	for _, b := range []Base{keep, stale} {
		if _, err := os.Stat(b.Path); err != nil {
			t.Fatalf("dry run removed %s: %v", b.Path, err)
		}
	}

	if err := run([]string{root}, true, false, deadProbe()); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(stale.Path); !os.IsNotExist(err) {
		t.Fatalf("stale base still exists after apply: %v", err)
	}

	if _, err := os.Stat(keep.Path); err != nil {
		t.Fatalf("live-workspace base removed by apply: %v", err)
	}
}

func TestClassifyUnreadableWorkspaceIsKept(t *testing.T) {
	root := t.TempDir()
	outer := t.TempDir()
	parent := filepath.Join(outer, "parent")
	ws := filepath.Join(parent, "ws")

	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}

	base := makeBase(t, root, "base", ws)

	if err := os.Chmod(parent, 0); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() { _ = os.Chmod(parent, 0o755) })

	if _, err := os.Stat(ws); err == nil {
		t.Skip("workspace remained stat-able after removing parent search permission")
	}

	got, reason := classify(base, deadProbe())
	if got != VerdictKeep {
		t.Fatalf("classify = %s (%s), want keep", got, reason)
	}
}

func TestRunApplySkipsBaseThatBecomesRegistered(t *testing.T) {
	root := t.TempDir()
	wsDir := t.TempDir()
	ws := makeWorkspace(t, wsDir, "feature", false)
	materializeGitdir(t, ws)
	base := makeBase(t, root, "base", ws)

	var calls int

	p := probe{
		worktreePaths: func(string) ([]string, error) {
			calls++
			if calls == 1 {
				return nil, nil
			}

			return []string{ws}, nil
		},
		pidAlive: func(int) bool { return false },
	}

	if err := run([]string{root}, true, true, p); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(base.Path); err != nil {
		t.Fatalf("apply removed a base that was registered again before delete: %v", err)
	}

	if calls < 2 {
		t.Fatalf("apply classified %d time(s), want a second check before delete", calls)
	}
}

func TestClassifyRealGitMissingRepositoryIsStale(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	root := t.TempDir()
	wsDir := t.TempDir()
	ws := makeWorkspace(t, wsDir, "feature", false)
	materializeGitdir(t, ws)
	base := makeBase(t, root, "base", ws)

	got, reason := classify(base, defaultProbe())
	if got != VerdictStale {
		t.Fatalf("classify = %s (%s), want stale", got, reason)
	}
}
