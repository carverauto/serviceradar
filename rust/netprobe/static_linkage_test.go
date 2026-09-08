// Asserts the shape of the released netprobe binaries: fully static, no dynamic
// interpreter, no shared-library dependencies, and above all no libpcap.
//
// Replaces the "Verify static linkage" step of .forgejo/workflows/rust-musl.yml together
// with scripts/ci/assert-netprobe-libpcap-free.sh. That step ran `bazel build`, then
// `bazel cquery --output=files | tail -n 1` to recover the artifact path, then shelled out
// to file(1), readelf(1) and ldd(1) against it.
//
// Two reasons this is Go rather than the shell script it replaces:
//
//   - The tools are not there. A first attempt as an sh_test failed on the RBE executor
//     with "file(1) is required to assert static linkage": the executor image does not
//     carry file(1), and //.bazelrc deliberately does NOT forward PATH to test actions, so
//     a test sees only /bin:/usr/bin:/usr/local/bin. Depending on host binaries would make
//     this gate silently environment-dependent, which is what it exists to prevent.
//   - debug/elf is stdlib and architecture-neutral. Parsing an aarch64 ELF on an x86_64
//     executor is ordinary, so both release architectures are checked from one test rather
//     than one per runner. It is also exact: DT_NEEDED entries are read as a list instead
//     of grepped out of readelf's prose.
//
// libpcap is the assertion with product meaning. The musl build exists to be a single
// portable binary with no runtime library expectations of the host it lands on, and a
// libpcap link silently destroys that. The static/INTERP/NEEDED checks are the ways such a
// dependency creeps back in, so they are asserted directly rather than debugged later.
package netprobe_test

import (
	"debug/elf"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// binaries maps a human-readable architecture to the env var carrying its runfiles path.
// //rust/netprobe:BUILD.bazel sets both via $(rootpath) on a platform_transition_filegroup.
var binaries = map[string]string{
	"linux_x86_64_musl":  "NETPROBE_X86_64_MUSL",
	"linux_aarch64_musl": "NETPROBE_AARCH64_MUSL",
}

// resolve finds a data dependency whether the test runs from the runfiles tree or from the
// execroot. Bazel does not guarantee which, and a bare relative open works only in one.
func resolve(t *testing.T, rel string) string {
	t.Helper()

	if _, err := os.Stat(rel); err == nil {
		return rel
	}

	srcDir := os.Getenv("TEST_SRCDIR")
	workspace := os.Getenv("TEST_WORKSPACE")
	if srcDir != "" {
		for _, candidate := range []string{
			filepath.Join(srcDir, workspace, rel),
			filepath.Join(srcDir, rel),
		} {
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}

	t.Fatalf("netprobe binary not found: %s (TEST_SRCDIR=%q TEST_WORKSPACE=%q)", rel, srcDir, workspace)
	return ""
}

func TestNetprobeIsStaticAndLibpcapFree(t *testing.T) {
	for arch, envVar := range binaries {
		rel := os.Getenv(envVar)
		if rel == "" {
			// Fail rather than skip. A missing path means the BUILD rule stopped passing
			// the binary, and a gate that quietly passes when handed nothing is worse than
			// no gate at all.
			t.Fatalf("%s is unset; //rust/netprobe:BUILD.bazel must pass $(rootpath) for %s", envVar, arch)
		}

		t.Run(arch, func(t *testing.T) {
			path := resolve(t, rel)

			f, err := elf.Open(path)
			if err != nil {
				t.Fatalf("not a parseable ELF: %v", err)
			}
			defer f.Close()

			// A fully static binary requests no dynamic loader.
			for _, prog := range f.Progs {
				if prog.Type == elf.PT_INTERP {
					t.Errorf("declares a dynamic interpreter (PT_INTERP); expected a static binary")
				}
			}

			// DynString returns an error when there is no dynamic section at all, which is
			// the passing case for a static binary. Only a populated NEEDED list is a
			// failure.
			needed, err := f.DynString(elf.DT_NEEDED)
			if err == nil {
				for _, lib := range needed {
					t.Errorf("declares shared-library dependency %q; expected a static binary", lib)
				}
			}

			// Belt and braces: catch libpcap arriving through any dynamic entry, not just
			// DT_NEEDED (DT_RPATH and DT_RUNPATH have carried it before).
			for _, tag := range []elf.DynTag{elf.DT_NEEDED, elf.DT_RPATH, elf.DT_RUNPATH, elf.DT_SONAME} {
				values, err := f.DynString(tag)
				if err != nil {
					continue
				}
				for _, value := range values {
					if strings.Contains(value, "libpcap") {
						t.Errorf("references libpcap via %v: %q", tag, value)
					}
				}
			}
		})
	}
}
