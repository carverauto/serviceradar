// Command apply copies Bazel-formatted Elixir sources back into the workspace.
//
// `mix format` runs on the remote executors as a build action (see //build:elixir_quality.bzl),
// which emits every formatter input of a project, formatted, under its workspace-relative path.
// This tool is what `bazel run //elixir/<project>:format` executes on the caller's machine: it
// walks those trees and overwrites each workspace file whose bytes differ. It never creates a
// file: a formatted input with no counterpart in the checkout means the tree and the checkout
// disagree about what exists, and that is reported instead of papered over.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	changed, err := run(os.Getenv("BUILD_WORKSPACE_DIRECTORY"), os.Getenv("ELIXIR_FORMATTED_TREES"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "elixir format:", err)
		os.Exit(1)
	}
	if len(changed) == 0 {
		fmt.Println("elixir format: already formatted")
		return
	}
	for _, path := range changed {
		fmt.Println("formatted", path)
	}
}

func run(workspace, trees string) ([]string, error) {
	if workspace == "" {
		return nil, errors.New("BUILD_WORKSPACE_DIRECTORY is not set; run this with `bazel run`")
	}
	if trees == "" {
		return nil, errors.New("ELIXIR_FORMATTED_TREES is not set")
	}

	var changed []string
	for _, tree := range strings.Split(trees, string(os.PathListSeparator)) {
		paths, err := applyTree(tree, workspace)
		if err != nil {
			return changed, err
		}
		changed = append(changed, paths...)
	}
	return changed, nil
}

// applyTree copies every regular file under tree to the same relative path under workspace
// when the contents differ, and returns the workspace-relative paths it rewrote.
func applyTree(tree, workspace string) ([]string, error) {
	// In runfiles a tree artifact is a symlink to the real directory, and WalkDir does not
	// descend through a symlinked root.
	root, err := filepath.EvalSymlinks(tree)
	if err != nil {
		return nil, err
	}
	var changed []string
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		formatted, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		target := filepath.Join(workspace, rel)
		info, err := os.Stat(target)
		if err != nil {
			return fmt.Errorf("%s: formatted, but not present in the workspace: %w", rel, err)
		}
		current, err := os.ReadFile(target)
		if err != nil {
			return err
		}
		if bytes.Equal(current, formatted) {
			return nil
		}
		if err := os.WriteFile(target, formatted, info.Mode().Perm()); err != nil {
			return err
		}
		changed = append(changed, rel)
		return nil
	})
	return changed, err
}
