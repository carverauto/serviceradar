// Package multiarch verifies that every published OCI image index really carries a native
// binary for each architecture it advertises.
//
// This exists because the shape of an index and the contents of an index can disagree, and
// only the shape is easy to check. An index whose two children are both linux/amd64, or one
// that labels an entry linux/arm64 while its layers hold x86-64 binaries, satisfies
// `docker manifest inspect`, satisfies a "does it have two entries" assertion, and then
// fails on an arm64 node. Both of those were real states of this repository: declaring the
// index targets was not enough, because the images underneath pinned an amd64 base and an
// amd64 rootfs, so the arm64 half was our own aarch64 binaries sitting on an x86-64 Alpine
// userland, published under an amd64 label.
//
// So the assertion here is on the ELF header of the packaged binaries, not on the manifest
// metadata -- the metadata is exactly what was wrong before.
package multiarch

import (
	"archive/tar"
	"compress/gzip"
	"debug/elf"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// descriptor is the subset of an OCI descriptor this test reads.
type descriptor struct {
	MediaType string `json:"mediaType"`
	Digest    string `json:"digest"`
	Platform  *struct {
		OS           string `json:"os"`
		Architecture string `json:"architecture"`
		Variant      string `json:"variant"`
	} `json:"platform"`
}

type indexDoc struct {
	Manifests []descriptor `json:"manifests"`
}

type manifestDoc struct {
	Config descriptor   `json:"config"`
	Layers []descriptor `json:"layers"`
}

type configDoc struct {
	Architecture string `json:"architecture"`
	OS           string `json:"os"`
}

// wantMachine maps an OCI architecture string to the ELF machine its binaries must report.
var wantMachine = map[string]elf.Machine{
	"amd64": elf.EM_X86_64,
	"arm64": elf.EM_AARCH64,
}

// resolve finds a data dependency whether the test runs from the runfiles tree or from the
// execroot. Bazel does not guarantee which, and a bare relative open works only in one.
// Same helper as //rust/netprobe:static_linkage_test, for the same reason.
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

	t.Fatalf("image index not found: %s (TEST_SRCDIR=%q TEST_WORKSPACE=%q)", rel, srcDir, workspace)
	return ""
}

func blobPath(root, digest string) string {
	alg, hex, found := strings.Cut(digest, ":")
	if !found {
		return filepath.Join(root, "blobs", digest)
	}
	return filepath.Join(root, "blobs", alg, hex)
}

func readJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
}

// collectPlatforms walks an index, following nested indexes, and returns every concrete
// image manifest with the platform its parent descriptor advertised.
func collectPlatforms(t *testing.T, root, digest string, plat *descriptor, out map[string]string) {
	t.Helper()

	var doc indexDoc
	readJSON(t, blobPath(root, digest), &doc)

	if len(doc.Manifests) == 0 {
		// Not an index: a concrete image manifest. Record it under its parent's platform.
		if plat == nil || plat.Platform == nil {
			t.Fatalf("image manifest %s has no platform descriptor", digest)
		}
		key := plat.Platform.OS + "/" + plat.Platform.Architecture
		if plat.Platform.Variant != "" {
			key += "/" + plat.Platform.Variant
		}
		if prev, dup := out[key]; dup {
			t.Errorf("platform %s advertised twice (%s and %s): an index with two entries for "+
				"the same platform is the bug this test exists to catch", key, prev, digest)
		}
		out[key] = digest
		return
	}

	for i := range doc.Manifests {
		d := doc.Manifests[i]
		collectPlatforms(t, root, d.Digest, &d, out)
	}
}

// machinesInLayers returns every distinct ELF machine found across an image's layers,
// mapped to one example path, so a failure can name the offending file.
func machinesInLayers(t *testing.T, root string, man manifestDoc) map[elf.Machine]string {
	t.Helper()

	found := map[elf.Machine]string{}
	for _, layer := range man.Layers {
		f, err := os.Open(blobPath(root, layer.Digest))
		if err != nil {
			t.Fatalf("open layer %s: %v", layer.Digest, err)
		}

		var r io.Reader = f
		if gz, err := gzip.NewReader(f); err == nil {
			r = gz
		} else {
			if _, err := f.Seek(0, io.SeekStart); err != nil {
				t.Fatalf("seek layer %s: %v", layer.Digest, err)
			}
		}

		tr := tar.NewReader(r)
		for {
			hdr, err := tr.Next()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				// A layer that is not a tar is not this test's concern.
				break
			}
			if hdr.Typeflag != tar.TypeReg || hdr.Size < 64 {
				continue
			}
			// debug/elf needs a ReaderAt, so the entry is buffered. Layers here are service
			// binaries and small Alpine packages, not disk images.
			buf, err := io.ReadAll(tr)
			if err != nil {
				break
			}
			ef, err := elf.NewFile(strings.NewReader(string(buf)))
			if err != nil {
				continue // not an ELF file
			}
			if _, seen := found[ef.FileHeader.Machine]; !seen {
				found[ef.FileHeader.Machine] = hdr.Name
			}
			ef.Close()
		}
		f.Close()
	}
	return found
}

func verifyIndex(t *testing.T, name, root string) {
	t.Helper()

	var top indexDoc
	readJSON(t, filepath.Join(root, "index.json"), &top)

	platforms := map[string]string{}
	for i := range top.Manifests {
		d := top.Manifests[i]
		collectPlatforms(t, root, d.Digest, &d, platforms)
	}

	for _, want := range []string{"linux/amd64", "linux/arm64/v8"} {
		if _, ok := platforms[want]; !ok {
			t.Errorf("%s: index does not advertise %s (has %v)", name, want, keys(platforms))
		}
	}

	for plat, digest := range platforms {
		var man manifestDoc
		readJSON(t, blobPath(root, digest), &man)

		var cfg configDoc
		readJSON(t, blobPath(root, man.Config.Digest), &cfg)

		arch := strings.TrimPrefix(plat, "linux/")
		arch, _, _ = strings.Cut(arch, "/")
		if cfg.Architecture != arch {
			t.Errorf("%s [%s]: config declares architecture %q but the index descriptor says %q",
				name, plat, cfg.Architecture, arch)
		}

		want, ok := wantMachine[arch]
		if !ok {
			continue
		}

		machines := machinesInLayers(t, root, man)
		if len(machines) == 0 {
			t.Errorf("%s [%s]: no ELF binary found in any layer, so this entry proves nothing",
				name, plat)
			continue
		}
		for got, example := range machines {
			if got != want {
				t.Errorf("%s [%s]: expected %v binaries but found %v (e.g. %s) -- "+
					"the entry is labelled %s while its contents are not",
					name, plat, want, got, example, arch)
			}
		}
	}
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestMultiArchIndexesCarryNativeBinaries(t *testing.T) {
	// Each entry is an env var set by the BUILD rule to the index's runfiles path.
	for _, env := range strings.Split(os.Getenv("MULTIARCH_INDEXES"), ",") {
		env = strings.TrimSpace(env)
		if env == "" {
			continue
		}
		root := os.Getenv(env)
		if root == "" {
			t.Errorf("env %s is not set; the BUILD rule and this test disagree on the index list", env)
			continue
		}
		t.Run(env, func(t *testing.T) {
			verifyIndex(t, env, resolve(t, root))
		})
	}
}
