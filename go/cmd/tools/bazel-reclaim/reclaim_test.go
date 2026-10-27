package main

import (
	"errors"
	"flag"
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

func TestOutputUserRootKeepsCommaInPath(t *testing.T) {
	root := filepath.Join(t.TempDir(), "cache,root")
	other := filepath.Join(t.TempDir(), "other")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}

	ws := filepath.Join(t.TempDir(), "gone")
	base := makeBase(t, root, "hash", ws)

	fs := flag.NewFlagSet("bazel-reclaim", flag.ContinueOnError)
	var roots stringList
	fs.Var(&roots, "output-user-root", "")
	if err := fs.Parse([]string{"--output-user-root", root, "--output-user-root", other}); err != nil {
		t.Fatal(err)
	}

	if len(roots) != 2 || roots[0] != root || roots[1] != other {
		t.Fatalf("roots = %#v, want [%s %s]", roots, root, other)
	}

	bases, err := discoverBases([]string{roots[0]})
	if err != nil {
		t.Fatal(err)
	}

	if len(bases) != 1 || bases[0].Path != base.Path {
		t.Fatalf("discoverBases = %+v, want %s", bases, base.Path)
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
	fileWS := filepath.Join(wsDir, "not-a-directory")
	if err := os.WriteFile(fileWS, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

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
			name:  "workspace file is kept",
			base:  makeBase(t, root, "file", fileWS),
			probe: deadProbe(),
			want:  VerdictKeep,
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

func TestRunApplyKeepsUncertainServerPID(t *testing.T) {
	for _, tc := range []struct {
		name     string
		contents string
		mode     os.FileMode
	}{
		{name: "unreadable", contents: "4242\n", mode: 0},
		{name: "empty", mode: 0o644},
		{name: "malformed", contents: "not-a-pid", mode: 0o644},
		{name: "zero", contents: "0", mode: 0o644},
		{name: "negative", contents: "-1", mode: 0o644},
		{name: "overflow", contents: "999999999999999999999999", mode: 0o644},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			base := makeBase(t, root, "base", filepath.Join(t.TempDir(), "removed"))
			server := filepath.Join(base.Path, "server")
			if err := os.Mkdir(server, 0o755); err != nil {
				t.Fatal(err)
			}
			pidFile := filepath.Join(server, "server.pid.txt")
			if err := os.WriteFile(pidFile, []byte(tc.contents), tc.mode); err != nil {
				t.Fatal(err)
			}
			if tc.mode == 0 {
				t.Cleanup(func() { _ = os.Chmod(pidFile, 0o644) })
				if _, err := os.ReadFile(pidFile); err == nil {
					t.Skip("PID file remains readable without permissions")
				}
			}
			if err := run([]string{root}, true, false, defaultProbe()); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(base.Path); err != nil {
				t.Fatalf("apply removed base with uncertain server PID: %v", err)
			}
		})
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

func TestApplyIgnoresInheritedGitRepoEnv(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	// Two redirects that both make an uncleared probe lie: a successful list
	// of another repository, and a missing GIT_DIR that git reports as
	// "not a git repository" even though this worktree is registered.
	other := realGitRepo(t)
	missing := filepath.Join(t.TempDir(), "missing-git-dir")

	cases := []struct {
		name string
		env  []string
	}{
		{
			name: "other repository",
			env: []string{
				"GIT_DIR=" + filepath.Join(other, ".git"),
				"GIT_WORK_TREE=" + other,
				"GIT_COMMON_DIR=" + filepath.Join(other, ".git"),
				"GIT_OBJECT_DIRECTORY=" + filepath.Join(other, ".git", "objects"),
			},
		},
		{
			name: "missing repository",
			env: []string{
				"GIT_DIR=" + missing,
				"GIT_WORK_TREE=" + missing + "-worktree",
				"GIT_COMMON_DIR=" + missing + "-common",
				"GIT_OBJECT_DIRECTORY=" + missing + "-objects",
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, kv := range tc.env {
				key, val, _ := strings.Cut(kv, "=")
				t.Setenv(key, val)
			}

			root := t.TempDir()
			_, worktree := realLinkedWorktree(t)
			live := makeBase(t, root, "live", worktree)

			emptyWS := filepath.Join(t.TempDir(), "empty-ws")
			emptyGitdir := filepath.Join(t.TempDir(), "empty-gitdir")
			if err := os.MkdirAll(emptyWS, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(emptyGitdir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(emptyWS, ".git"), []byte("gitdir: "+emptyGitdir+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			empty := makeBase(t, root, "empty", emptyWS)

			got, reason := classify(live, defaultProbe())
			if got != VerdictKeep || reason != "workspace exists" {
				t.Fatalf("live classify = %s (%s), want keep (workspace exists)", got, reason)
			}

			got, reason = classify(empty, defaultProbe())
			if got != VerdictStale || !strings.Contains(strings.ToLower(reason), "not a git repository") {
				t.Fatalf("empty gitdir classify = %s (%s), want stale because git reports it is not a repository", got, reason)
			}

			if err := run([]string{root}, true, false, defaultProbe()); err != nil {
				t.Fatal(err)
			}

			if _, err := os.Stat(live.Path); err != nil {
				t.Fatalf("apply removed a registered worktree base: %v", err)
			}

			if _, err := os.Stat(empty.Path); !os.IsNotExist(err) {
				t.Fatalf("apply left the empty-gitdir base in place: %v", err)
			}
		})
	}
}

func realGitRepo(t *testing.T) string {
	t.Helper()

	repo := filepath.Join(t.TempDir(), "repo")
	gitRun(t, "init", "-b", "main", repo)
	gitRun(t, "-C", repo, "commit", "--allow-empty", "-m", "init")

	return repo
}

func realLinkedWorktree(t *testing.T) (repo string, worktree string) {
	t.Helper()

	repo = realGitRepo(t)
	worktree = filepath.Join(t.TempDir(), "wt")
	gitRun(t, "-C", repo, "worktree", "add", "--detach", worktree)

	return repo, worktree
}

func gitRun(t *testing.T, args ...string) {
	t.Helper()

	cmd := exec.Command("git", args...)
	cmd.Env = append(gitFixtureEnv(),
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=safe.directory",
		"GIT_CONFIG_VALUE_0=*",
		"GIT_AUTHOR_EMAIL=reclaim@example.com",
		"GIT_AUTHOR_NAME=reclaim",
		"GIT_COMMITTER_EMAIL=reclaim@example.com",
		"GIT_COMMITTER_NAME=reclaim",
	)

	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

func gitFixtureEnv() []string {
	var env []string

	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		switch key {
		case "PATH", "HOME", "TMPDIR", "TMP", "TEMP", "SYSTEMROOT":
			env = append(env, kv)
		}
	}

	return env
}

func TestApplyKeepsUnreadableGitdir(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	t.Run("mode 000 gitdir", func(t *testing.T) {
		_, worktree := realLinkedWorktree(t)
		gitdir := worktreeGitdir(t, worktree)
		t.Cleanup(func() { _ = os.Chmod(gitdir, 0o755) })

		if err := os.Chmod(gitdir, 0); err != nil {
			t.Fatal(err)
		}

		if _, err := os.ReadDir(gitdir); err == nil {
			t.Skip("process can still read a mode 000 gitdir")
		}

		root := t.TempDir()
		base := makeBase(t, root, "base", worktree)
		assertApplyKeeps(t, root, base)
	})

	t.Run("mode 000 gitdir parent", func(t *testing.T) {
		_, worktree := realLinkedWorktree(t)
		gitdir := worktreeGitdir(t, worktree)
		parent := filepath.Dir(gitdir)
		t.Cleanup(func() { _ = os.Chmod(parent, 0o755) })

		if err := os.Chmod(parent, 0); err != nil {
			t.Fatal(err)
		}

		if _, err := os.Stat(gitdir); err == nil {
			t.Skip("gitdir remained stat-able after removing parent search permission")
		}

		root := t.TempDir()
		base := makeBase(t, root, "base", worktree)
		assertApplyKeeps(t, root, base)
	})
}

func TestApplyKeepsWorktreeOmittedByUnreadableRegistration(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	for _, enumeration := range []bool{false, true} {
		name := "backlink"
		if enumeration {
			name = "enumeration directory"
		}
		t.Run(name, func(t *testing.T) {
			_, worktree := realLinkedWorktree(t)
			gitdir := worktreeGitdir(t, worktree)
			path := filepath.Join(gitdir, "gitdir")
			mode := os.FileMode(0)
			if enumeration {
				path = filepath.Dir(gitdir)
				mode = 0o111
			}
			denyPath(t, path)
			if err := os.Chmod(path, mode); err != nil {
				t.Fatal(err)
			}
			var readErr error
			if enumeration {
				_, readErr = os.ReadDir(path)
			} else {
				_, readErr = os.ReadFile(path)
			}
			if readErr == nil {
				t.Skip("process can still read restricted registration")
			}
			paths, err := gitWorktreePaths(worktree)
			if err != nil {
				t.Fatalf("expected successful incomplete enumeration: %v", err)
			}
			if containsPath(paths, worktree) {
				t.Fatal("expected Git to omit unreadable registration")
			}
			root := t.TempDir()
			base := makeBase(t, root, "base", worktree)
			assertApplyKeeps(t, root, base)
		})
	}
}

func worktreeGitdir(t *testing.T, workspace string) string {
	t.Helper()

	raw, err := os.ReadFile(filepath.Join(workspace, ".git"))
	if err != nil {
		t.Fatal(err)
	}

	rest, ok := strings.CutPrefix(strings.TrimSpace(string(raw)), "gitdir:")
	if !ok {
		t.Fatalf("%s .git file has no gitdir line", workspace)
	}

	target := strings.TrimSpace(rest)
	if !filepath.IsAbs(target) {
		target = filepath.Join(workspace, target)
	}

	return target
}

func assertApplyKeeps(t *testing.T, root string, base Base) {
	t.Helper()

	got, reason := classify(base, defaultProbe())
	if got != VerdictKeep {
		t.Fatalf("classify = %s (%s), want keep", got, reason)
	}

	if err := run([]string{root}, true, false, defaultProbe()); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(base.Path); err != nil {
		t.Fatalf("apply removed a base whose gitdir could not be read: %v", err)
	}
}

func TestDefaultRootsIncludesXDGCacheHome(t *testing.T) {
	home := t.TempDir()
	xdg := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USER", "reclaimtest")
	t.Setenv("XDG_CACHE_HOME", xdg)

	xdgRoot := filepath.Join(xdg, "bazel", "_bazel_reclaimtest")
	homeRoot := filepath.Join(home, ".cache", "bazel", "_bazel_reclaimtest")
	if err := os.MkdirAll(xdgRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(homeRoot, 0o755); err != nil {
		t.Fatal(err)
	}

	roots := defaultRoots()
	if !containsPath(roots, xdgRoot) || !containsPath(roots, homeRoot) {
		t.Fatalf("defaultRoots = %v, want %s and %s", roots, xdgRoot, homeRoot)
	}

	ws := filepath.Join(t.TempDir(), "gone")
	base := makeBase(t, xdgRoot, "hashxdg", ws)
	bases, err := discoverBases(roots)
	if err != nil {
		t.Fatal(err)
	}

	if len(bases) != 1 || bases[0].Path != base.Path {
		t.Fatalf("discoverBases = %+v, want %s", bases, base.Path)
	}

	t.Setenv("XDG_CACHE_HOME", filepath.Join(t.TempDir(), "missing"))
	for _, root := range defaultRoots() {
		if strings.Contains(root, "missing") {
			t.Fatalf("defaultRoots included a missing XDG cache: %s", root)
		}
	}
}

func TestApplyKeepsRegistrationWhenGitSaysNotARepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	cases := []struct {
		name   string
		target func(t *testing.T, repo, worktree string) string
		mode   os.FileMode
	}{
		{
			name: "gitdir without search permission",
			target: func(t *testing.T, _, worktree string) string {
				return worktreeGitdir(t, worktree)
			},
			mode: 0o444,
		},
		{
			name: "gitdir HEAD",
			target: func(t *testing.T, _, worktree string) string {
				return filepath.Join(worktreeGitdir(t, worktree), "HEAD")
			},
		},
		{
			name: "common objects",
			target: func(_ *testing.T, repo, _ string) string {
				return filepath.Join(repo, ".git", "objects")
			},
		},
		{
			name: "common refs",
			target: func(_ *testing.T, repo, _ string) string {
				return filepath.Join(repo, ".git", "refs")
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo, worktree := realLinkedWorktree(t)
			path := tc.target(t, repo, worktree)
			denyPath(t, path)
			if tc.mode != 0 {
				if err := os.Chmod(path, tc.mode); err != nil {
					t.Fatal(err)
				}
			}

			if !gitReportsNotARepository(worktree) {
				t.Skip("git did not report not a git repository for " + path)
			}

			root := t.TempDir()
			base := makeBase(t, root, "base", worktree)
			assertApplyKeeps(t, root, base)
		})
	}
}

func denyPath(t *testing.T, path string) {
	t.Helper()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	perm := info.Mode().Perm()
	t.Cleanup(func() { _ = os.Chmod(path, perm) })

	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
}

func gitReportsNotARepository(workspace string) bool {
	cmd := exec.Command("git", "-C", workspace, "worktree", "list", "--porcelain")
	cmd.Env = withoutEnv(os.Environ(), "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")
	out, err := cmd.CombinedOutput()
	if err == nil {
		return false
	}

	return strings.Contains(strings.ToLower(string(out)), "not a git repository")
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
