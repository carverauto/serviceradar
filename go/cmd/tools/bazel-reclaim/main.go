// bazel-reclaim lists stale Bazel output bases left behind by removed git
// worktrees and, with --apply, deletes them. Dry-run is the default: with no
// --apply it only reports. A base is stale only when its workspace path no
// longer exists or its worktree registration is gone; an uncertain stat or
// git failure is not stale. Bases with a live workspace or a running Bazel
// server are never deleted, because other sessions on the same workstation
// share these roots.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var errNoOutputUserRoot = errors.New("no output user root found; pass --output-user-root (parent of bazel info output_base)")

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }

func (s *stringList) Set(v string) error {
	*s = append(*s, v)

	return nil
}

func main() {
	var roots stringList

	apply := flag.Bool("apply", false, "delete stale output bases (default: dry-run report only)")
	sizes := flag.Bool("sizes", true, "measure output-base sizes (walks each base)")
	flag.Var(&roots, "output-user-root", "Bazel output user root to scan (repeatable); default: existing $XDG_CACHE_HOME/bazel/_bazel_$USER when XDG_CACHE_HOME is set, plus the platform _bazel_$USER directories that exist")
	flag.Parse()

	if err := run(roots, *apply, *sizes, defaultProbe()); err != nil {
		fmt.Fprintln(os.Stderr, "bazel-reclaim:", err)
		os.Exit(1)
	}
}

func run(roots []string, apply bool, sizes bool, p probe) error {
	if len(roots) == 0 {
		roots = defaultRoots()
	}

	if len(roots) == 0 {
		return errNoOutputUserRoot
	}

	bases, err := discoverBases(roots)
	if err != nil {
		return err
	}

	sort.Slice(bases, func(i, j int) bool { return bases[i].Path < bases[j].Path })

	var staleBytes int64
	var staleCount, keepCount, skipCount int

	for _, b := range bases {
		verdict, reason := classify(b, p)

		var size int64
		if sizes {
			size = dirSize(b.Path)
		}

		if apply && verdict == VerdictStale {
			verdict, reason = classify(b, p)
		}

		fmt.Printf("%s\t%s\t%s\t%s (%s)\n", verdict, humanSize(size, sizes), b.Workspace, b.Path, reason)

		switch verdict {
		case VerdictStale:
			staleCount++
			staleBytes += size

			if apply {
				if err := os.RemoveAll(b.Path); err != nil {
					return fmt.Errorf("remove stale base %s: %w", b.Path, err)
				}

				fmt.Printf("deleted\t%s\n", b.Path)
			}
		case VerdictSkipLiveServer:
			skipCount++
		case VerdictKeep:
			keepCount++
		default:
			keepCount++
		}
	}

	fmt.Printf("output bases: %d keep, %d stale (%s reclaimable), %d skipped (live server)\n",
		keepCount, staleCount, humanSize(staleBytes, sizes), skipCount)

	if !apply && staleCount > 0 {
		fmt.Println("dry run: nothing deleted; re-run with --apply to delete the stale bases")
	}

	return nil
}

// defaultRoots returns the output user roots that exist as directories. When
// XDG_CACHE_HOME is set, $XDG_CACHE_HOME/bazel/_bazel_$USER is a candidate
// along with the platform defaults. A custom --output_user_root (for example
// in ~/.bazelrc) is passed explicitly.
func defaultRoots() []string {
	user := os.Getenv("USER")

	var candidates []string

	if xdg := strings.TrimSpace(os.Getenv("XDG_CACHE_HOME")); xdg != "" {
		candidates = append(candidates, filepath.Join(xdg, "bazel", "_bazel_"+user))
	}

	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, "Library", "Caches", "bazel", "_bazel_"+user),
			filepath.Join(home, ".cache", "bazel", "_bazel_"+user),
		)
	}

	var roots []string

	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && info.IsDir() {
			roots = append(roots, c)
		}
	}

	return roots
}

func humanSize(bytes int64, measured bool) string {
	if !measured {
		return "-"
	}

	const unit = 1024

	if bytes < unit {
		return fmt.Sprintf("%dB", bytes)
	}

	div, exp := int64(unit), 0

	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}

	return fmt.Sprintf("%.1f%cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
