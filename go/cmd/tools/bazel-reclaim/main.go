// bazel-reclaim lists stale Bazel output bases left behind by removed git
// worktrees and, with --apply, deletes them. Dry-run is the default: with no
// --apply it only reports. A base is stale only when its workspace path no
// longer exists or its worktree registration is gone; an uncertain stat or
// git failure is not stale. Bases with a live workspace or a running Bazel
// server are never deleted, because other sessions on the same workstation
// share these roots.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }

func (s *stringList) Set(v string) error {
	for _, part := range strings.Split(v, ",") {
		if part = strings.TrimSpace(part); part != "" {
			*s = append(*s, part)
		}
	}

	return nil
}

func main() {
	var roots stringList

	apply := flag.Bool("apply", false, "delete stale output bases (default: dry-run report only)")
	sizes := flag.Bool("sizes", true, "measure output-base sizes (walks each base)")
	flag.Var(&roots, "output-user-root", "Bazel output user root to scan (repeatable, comma-separated); default: platform locations that exist")
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
		return fmt.Errorf("no output user root found; pass --output-user-root (parent of bazel info output_base)")
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

// defaultRoots returns the platform output user roots that exist. A custom
// --output_user_root (for example in ~/.bazelrc) is passed explicitly.
func defaultRoots() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}

	user := os.Getenv("USER")

	candidates := []string{
		filepath.Join(home, "Library", "Caches", "bazel", "_bazel_"+user),
		filepath.Join(home, ".cache", "bazel", "_bazel_"+user),
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
