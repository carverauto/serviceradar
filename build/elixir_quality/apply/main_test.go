package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestRewritesOnlyChangedFiles(t *testing.T) {
	tree, workspace := t.TempDir(), t.TempDir()
	write(t, filepath.Join(tree, "elixir/app/lib/a.ex"), "formatted\n")
	write(t, filepath.Join(tree, "elixir/app/lib/b.ex"), "same\n")
	write(t, filepath.Join(workspace, "elixir/app/lib/a.ex"), "unformatted\n")
	write(t, filepath.Join(workspace, "elixir/app/lib/b.ex"), "same\n")

	changed, err := run(workspace, tree)
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 1 || changed[0] != filepath.Join("elixir", "app", "lib", "a.ex") {
		t.Fatalf("changed = %v, want only a.ex", changed)
	}
	if got := read(t, filepath.Join(workspace, "elixir/app/lib/a.ex")); got != "formatted\n" {
		t.Fatalf("a.ex = %q", got)
	}
}

func TestRefusesToCreateFiles(t *testing.T) {
	tree, workspace := t.TempDir(), t.TempDir()
	write(t, filepath.Join(tree, "elixir/app/lib/new.ex"), "x\n")

	_, err := run(workspace, tree)
	if err == nil || !strings.Contains(err.Error(), "not present in the workspace") {
		t.Fatalf("err = %v, want a missing-file error", err)
	}
	if _, statErr := os.Stat(filepath.Join(workspace, "elixir/app/lib/new.ex")); !os.IsNotExist(statErr) {
		t.Fatalf("new.ex was created")
	}
}

func TestRequiresBazelRun(t *testing.T) {
	if _, err := run("", "tree"); err == nil {
		t.Fatal("expected an error without BUILD_WORKSPACE_DIRECTORY")
	}
}

func TestFollowsSymlinkedTreeRoot(t *testing.T) {
	real, workspace := t.TempDir(), t.TempDir()
	write(t, filepath.Join(real, "elixir/app/lib/a.ex"), "formatted\n")
	write(t, filepath.Join(workspace, "elixir/app/lib/a.ex"), "unformatted\n")
	link := filepath.Join(t.TempDir(), "formatted")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}

	changed, err := run(workspace, link)
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 1 {
		t.Fatalf("changed = %v, want a.ex", changed)
	}
}
