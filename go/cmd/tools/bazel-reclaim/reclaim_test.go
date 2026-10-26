package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
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
	unregistered := makeWorkspace(t, wsDir, "leftover", false)
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
			name: "unreadable registration is stale",
			base: makeBase(t, root, "broken", unregistered),
			probe: probe{
				worktreePaths: func(string) ([]string, error) { return nil, errors.New("not a git repository") },
				pidAlive:      func(int) bool { return false },
			},
			want: VerdictStale,
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
