/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errFakeObjectNotFound        = errors.New("fake object store: key not found")
	errUnexpectedAddonRedownload = errors.New("unchanged assignment should not fetch again")
)

const testPushedBinaryA = "/pushed/a"

const testAddonKeyX = "addons/x"

type fakeObjectStore struct {
	data      map[string][]byte
	err       error
	downloads int
}

func (f *fakeObjectStore) DownloadObject(_ context.Context, key string) ([]byte, error) {
	f.downloads++
	if f.err != nil {
		return nil, f.err
	}

	d, ok := f.data[key]
	if !ok {
		return nil, fmt.Errorf("%w: %s", errFakeObjectNotFound, key)
	}

	return d, nil
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func TestStageAddonArtifactSuccess(t *testing.T) {
	root := t.TempDir()
	payload := []byte("#!/bin/sh\necho hi\n")
	key := "addons/sample/linux-amd64"
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "sample",
		Version:           "1.0.0",
		BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-sample-addon",
		Delivery:          "pushed_artifact",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
	}

	got, err := stageAddonArtifact(context.Background(), store, root, a)
	if err != nil {
		t.Fatalf("stage: %v", err)
	}

	if filepath.Base(got) != "serviceradar-sample-addon" {
		t.Fatalf("resolved binary name = %q, want serviceradar-sample-addon", filepath.Base(got))
	}

	data, err := os.ReadFile(got)
	if err != nil {
		t.Fatalf("read staged binary via current symlink: %v", err)
	}
	if !bytes.Equal(data, payload) {
		t.Fatalf("staged content mismatch")
	}

	info, err := os.Stat(got)
	if err != nil {
		t.Fatalf("stat staged binary: %v", err)
	}
	if info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("staged binary not executable: %v", info.Mode())
	}

	// current must be a symlink pointing at the versioned dir.
	cur := filepath.Join(root, "sample", addonCurrentLink)
	fi, err := os.Lstat(cur)
	if err != nil {
		t.Fatalf("lstat current: %v", err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("current is not a symlink: %v", fi.Mode())
	}

	// The versioned copy exists independently of the symlink.
	if _, err := os.Stat(filepath.Join(root, "sample", addonVersionsDir, "1.0.0", "serviceradar-sample-addon")); err != nil {
		t.Fatalf("versioned binary missing: %v", err)
	}
}

func TestStageAddonArtifactSkipsUnchangedCurrentArtifact(t *testing.T) {
	root := t.TempDir()
	payload := []byte("#!/bin/sh\necho hi\n")
	key := "addons/sample/linux-amd64"
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "sample",
		Version:           "1.0.0",
		BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-sample-addon",
		Delivery:          "pushed_artifact",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
	}

	got1, err := stageAddonArtifact(context.Background(), store, root, a)
	if err != nil {
		t.Fatalf("initial stage: %v", err)
	}
	if store.downloads != 1 {
		t.Fatalf("initial downloads = %d, want 1", store.downloads)
	}

	metadataPath := filepath.Join(root, "sample", addonVersionsDir, "1.0.0", addonStageMetaFile)
	if _, err := os.Stat(metadataPath); err != nil {
		t.Fatalf("expected trusted stage metadata: %v", err)
	}

	store.err = errUnexpectedAddonRedownload
	got2, err := stageAddonArtifact(context.Background(), store, root, a)
	if err != nil {
		t.Fatalf("restage unchanged assignment: %v", err)
	}
	if got2 != got1 {
		t.Fatalf("restaged path = %q, want %q", got2, got1)
	}
	if store.downloads != 1 {
		t.Fatalf("downloads after unchanged restage = %d, want 1", store.downloads)
	}
}

func TestStageAddonArtifactHashMismatch(t *testing.T) {
	root := t.TempDir()
	key := testAddonKeyX
	store := &fakeObjectStore{data: map[string][]byte{key: []byte("real-bytes")}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "x",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex([]byte("different-bytes")),
	}

	if _, err := stageAddonArtifact(context.Background(), store, root, a); !errors.Is(err, ErrAddonArtifactHashMismatch) {
		t.Fatalf("want ErrAddonArtifactHashMismatch, got %v", err)
	}
}

func TestStageAddonArtifactNilStore(t *testing.T) {
	a := &proto.AddonAssignmentConfig{AddonId: "x", ArtifactObjectKey: "k", ArtifactSha256: "abc"}

	if _, err := stageAddonArtifact(context.Background(), nil, t.TempDir(), a); !errors.Is(err, ErrAddonObjectStoreUnavailable) {
		t.Fatalf("want ErrAddonObjectStoreUnavailable, got %v", err)
	}
}

func TestStageAddonArtifactIncomplete(t *testing.T) {
	store := &fakeObjectStore{data: map[string][]byte{}}
	a := &proto.AddonAssignmentConfig{AddonId: "x"} // no object_key / sha256

	if _, err := stageAddonArtifact(context.Background(), store, t.TempDir(), a); !errors.Is(err, ErrAddonArtifactIncomplete) {
		t.Fatalf("want ErrAddonArtifactIncomplete, got %v", err)
	}
}

func TestStageAddonArtifactBinaryPathTraversalFallsBack(t *testing.T) {
	root := t.TempDir()
	payload := []byte("bin")
	key := "addons/dd"
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}

	// A crafted binary_path basename of ".." must NOT escape the version dir: the
	// derived name falls back to the safe synthesized name instead.
	a := &proto.AddonAssignmentConfig{
		AddonId:           "dd",
		Version:           "1.0.0",
		BinaryPath:        "..",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
	}

	got, err := stageAddonArtifact(context.Background(), store, root, a)
	if err != nil {
		t.Fatalf("stage: %v", err)
	}
	if filepath.Base(got) != "serviceradar-dd-addon" {
		t.Fatalf("binary_path %q should fall back to synthesized name, got base %q", "..", filepath.Base(got))
	}

	// The real staged file must live under the version dir (not its parent), and the
	// returned current-symlink path must resolve to it.
	if _, err := os.Stat(filepath.Join(root, "dd", addonVersionsDir, "1.0.0", "serviceradar-dd-addon")); err != nil {
		t.Fatalf("staged binary not under version dir: %v", err)
	}
	data, err := os.ReadFile(got)
	if err != nil || !bytes.Equal(data, payload) {
		t.Fatalf("staged binary not readable via current symlink: %v", err)
	}
}

func TestAddonBinaryNameRejectsUnsafeBase(t *testing.T) {
	cases := map[string]string{
		"..":            "serviceradar-x-addon", // traversal -> fallback
		"/":             "serviceradar-x-addon",
		"":              "serviceradar-x-addon", // empty binary_path -> fallback
		"/usr/bin/real": "real",                 // normal case keeps the basename
	}
	for bp, want := range cases {
		a := &proto.AddonAssignmentConfig{AddonId: "x", BinaryPath: bp}
		if got := addonBinaryName(a); got != want {
			t.Fatalf("addonBinaryName(binary_path=%q) = %q, want %q", bp, got, want)
		}
	}
}

func TestApplyLocalAddonOverridesMissingFileIsNoop(t *testing.T) {
	pushed := []*proto.AddonAssignmentConfig{{AddonId: "a", BinaryPath: testPushedBinaryA}}

	got, err := applyLocalAddonOverrides(pushed, filepath.Join(t.TempDir(), "absent.json"))
	if err != nil {
		t.Fatalf("missing file should be a no-op, got %v", err)
	}
	if len(got) != 1 || got[0].GetBinaryPath() != testPushedBinaryA {
		t.Fatalf("pushed assignments changed by missing override: %#v", got)
	}
}

func TestApplyLocalAddonOverridesReplacesAndAppends(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, addonLocalOverrideFile)
	// Override "a" (local binary), add local-only "c"; leave pushed "b" untouched.
	content := `{"addons":[
	  {"addon_id":"a","binary_path":"/local/a","enabled":true},
	  {"addon_id":"c","binary_path":"/local/c"}
	]}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	pushed := []*proto.AddonAssignmentConfig{
		// 'a' carries config + capabilities the override does NOT mention; they must
		// be inherited (the override patches binary_path only).
		{AddonId: "a", BinaryPath: testPushedBinaryA, Enabled: true, ConfigJson: []byte(`{"k":1}`), Capabilities: []string{"cap-a"}},
		{AddonId: "b", BinaryPath: "/pushed/b", Enabled: true},
	}

	got, err := applyLocalAddonOverrides(pushed, path)
	if err != nil {
		t.Fatalf("apply overrides: %v", err)
	}

	byID := map[string]*proto.AddonAssignmentConfig{}
	for _, a := range got {
		byID[a.GetAddonId()] = a
	}

	if len(got) != 3 {
		t.Fatalf("merged length = %d, want 3 (%#v)", len(got), got)
	}
	if byID["a"].GetBinaryPath() != "/local/a" {
		t.Fatalf("local override did not patch pushed 'a' binary_path: %q", byID["a"].GetBinaryPath())
	}
	// Merge, not replace: fields the override omitted are inherited from pushed.
	if string(byID["a"].GetConfigJson()) != `{"k":1}` || len(byID["a"].GetCapabilities()) != 1 {
		t.Fatalf("override should inherit pushed config/capabilities for 'a': %#v", byID["a"])
	}
	if byID["b"].GetBinaryPath() != "/pushed/b" {
		t.Fatalf("pushed 'b' should be untouched: %q", byID["b"].GetBinaryPath())
	}
	if byID["c"].GetBinaryPath() != "/local/c" || !byID["c"].GetEnabled() {
		t.Fatalf("local-only 'c' missing or not enabled-by-default: %#v", byID["c"])
	}
}

func TestApplyLocalAddonOverridesMalformedReturnsPushed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, addonLocalOverrideFile)
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	pushed := []*proto.AddonAssignmentConfig{{AddonId: "a", BinaryPath: testPushedBinaryA}}

	got, err := applyLocalAddonOverrides(pushed, path)
	if err == nil {
		t.Fatal("expected an error for malformed override")
	}
	if len(got) != 1 || got[0].GetBinaryPath() != testPushedBinaryA {
		t.Fatalf("malformed override must return pushed unchanged: %#v", got)
	}
}

func TestStageAddonArtifactRejectsUnsafePath(t *testing.T) {
	root := t.TempDir()
	payload := []byte("x")
	key := "addons/evil"
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}

	cases := []struct {
		name    string
		addonID string
		version string
	}{
		{"traversal addon_id", "../../etc", "1.0.0"},
		{"slash addon_id", "a/b", "1.0.0"},
		{"empty addon_id", "", "1.0.0"},
		{"traversal version", "evil", "../../tmp"},
		{"dotdot version", "evil", ".."},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a := &proto.AddonAssignmentConfig{
				AddonId:           tc.addonID,
				Version:           tc.version,
				ArtifactObjectKey: key,
				ArtifactSha256:    sha256Hex(payload),
			}
			if _, err := stageAddonArtifact(context.Background(), store, root, a); !errors.Is(err, ErrAddonUnsafePath) {
				t.Fatalf("want ErrAddonUnsafePath, got %v", err)
			}
		})
	}

	// Nothing should have been created under or outside root.
	entries, _ := os.ReadDir(root)
	if len(entries) != 0 {
		t.Fatalf("unsafe staging created entries under root: %v", entries)
	}
}

func TestStageAddonArtifactFailsClosedWhenSignedButKeyUnset(t *testing.T) {
	// No release verification key configured...
	setReleaseVerificationKey(t, "")

	root := t.TempDir()
	payload := []byte("signed-but-unverifiable")
	key := "addons/signed"
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "signed",
		Version:           "1.0.0",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
		ArtifactSignature: "abcdef", // a signature is supplied
	}

	// ...so a supplied signature must fail closed (not silently activate).
	if _, err := stageAddonArtifact(context.Background(), store, root, a); err == nil {
		t.Fatal("expected staging to fail closed when a signature is supplied but no verification key is configured")
	}
}

func TestApplyLocalAddonOverridesCanDisable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, addonLocalOverrideFile)
	if err := os.WriteFile(path, []byte(`{"addons":[{"addon_id":"a","enabled":false}]}`), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	pushed := []*proto.AddonAssignmentConfig{{AddonId: "a", BinaryPath: testPushedBinaryA, Enabled: true}}

	got, err := applyLocalAddonOverrides(pushed, path)
	if err != nil {
		t.Fatalf("apply overrides: %v", err)
	}
	// enabled=false disables it, but the pushed binary_path is still inherited (merge).
	if len(got) != 1 || got[0].GetEnabled() || got[0].GetBinaryPath() != testPushedBinaryA {
		t.Fatalf("local override enabled=false should disable but preserve the pushed add-on: %#v", got)
	}
}

func TestAddonLastGoodSpecCache(t *testing.T) {
	pl := &PushLoop{}
	if _, ok := pl.lastGoodAddonSpec("a"); ok {
		t.Fatal("expected empty cache initially")
	}

	spec := agentaddon.Spec{ID: "a", Version: "1.0.0", BinaryPath: "/run/a", Args: []string{"--x"}}
	pl.rememberAddonSpec(spec)

	got, ok := pl.lastGoodAddonSpec("a")
	if !ok || got.BinaryPath != "/run/a" || got.Version != "1.0.0" {
		t.Fatalf("cache did not return the remembered spec: ok=%v spec=%#v", ok, got)
	}
}

func TestClassifyAddonSupervision(t *testing.T) {
	cases := map[string]addonDispatch{
		addonSupervisionAgentSidecar:    addonDispatchSidecar,
		addonSupervisionConfigToggle:    addonDispatchConfigToggle,
		addonSupervisionSystemdService:  addonDispatchSystemd,
		addonSupervisionSystemdTimer:    addonDispatchSystemd,
		addonSupervisionEphemeralHelper: addonDispatchEphemeral,
		"something_new":                 addonDispatchUnsupported,
	}
	for sup, want := range cases {
		if got := classifyAddonSupervision(sup); got != want {
			t.Fatalf("classifyAddonSupervision(%q) = %d, want %d", sup, got, want)
		}
	}
}

func TestPruneAddonCache(t *testing.T) {
	pl := &PushLoop{}
	pl.rememberAddonSpec(agentaddon.Spec{ID: "keep", BinaryPath: "/run/keep"})
	pl.rememberAddonSpec(agentaddon.Spec{ID: "drop", BinaryPath: "/run/drop"})

	// Only "keep" is still assigned; "drop" must be evicted so a re-add cannot fall
	// back to its stale spec.
	pl.pruneAddonCache(map[string]bool{"keep": true})

	if _, ok := pl.lastGoodAddonSpec("keep"); !ok {
		t.Fatal("expected 'keep' to survive prune")
	}
	if _, ok := pl.lastGoodAddonSpec("drop"); ok {
		t.Fatal("expected 'drop' to be evicted by prune")
	}
}

func TestStageAddonArtifactVerifiesSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	// stageAddonArtifact reuses the agent release ed25519 trust root.
	setReleaseVerificationKey(t, hex.EncodeToString(pub))

	root := t.TempDir()
	payload := []byte("signed-addon-binary")
	key := "addons/signed"
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "signed",
		Version:           "1.0.0",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
		ArtifactSignature: hex.EncodeToString(ed25519.Sign(priv, payload)),
	}

	if _, err := stageAddonArtifact(context.Background(), store, root, a); err != nil {
		t.Fatalf("valid signature should stage: %v", err)
	}

	// A signature over different bytes must be rejected before staging.
	a.ArtifactSignature = hex.EncodeToString(ed25519.Sign(priv, []byte("other-bytes")))
	if _, err := stageAddonArtifact(context.Background(), store, root, a); !errors.Is(err, ErrAddonSignatureInvalid) {
		t.Fatalf("want ErrAddonSignatureInvalid, got %v", err)
	}
}

// stageTestAddon stages a payload as version `version` of add-on `addonID` under root,
// publishing the `current` symlink, for the rollback tests below.
func stageTestAddon(t *testing.T, root, version string, payload []byte) {
	t.Helper()
	const addonID = "np"
	key := "addons/" + addonID + "/" + version
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}
	a := &proto.AddonAssignmentConfig{
		AddonId:           addonID,
		Version:           version,
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
	}
	if _, err := stageAddonArtifact(context.Background(), store, root, a); err != nil {
		t.Fatalf("stage %s %s: %v", addonID, version, err)
	}
}

func TestRollbackAddonCurrentRestoresPriorVersion(t *testing.T) {
	root := t.TempDir()
	addonDir := filepath.Join(root, "np")

	stageTestAddon(t, root, "1.0.0", []byte("v1-binary"))
	prior, ok := readAddonCurrentTarget(addonDir)
	if !ok || prior != filepath.Join(addonVersionsDir, "1.0.0") {
		t.Fatalf("prior target = %q ok=%v, want versions/1.0.0", prior, ok)
	}

	// A new version is staged and becomes current...
	stageTestAddon(t, root, "2.0.0", []byte("v2-binary"))
	if cur, _ := readAddonCurrentTarget(addonDir); cur != filepath.Join(addonVersionsDir, "2.0.0") {
		t.Fatalf("current after staging v2 = %q, want versions/2.0.0", cur)
	}

	// ...then a downstream activation step fails, so we roll current back to v1.
	if err := rollbackAddonCurrent(root, "np", prior); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if cur, _ := readAddonCurrentTarget(addonDir); cur != filepath.Join(addonVersionsDir, "1.0.0") {
		t.Fatalf("current after rollback = %q, want versions/1.0.0", cur)
	}
	data, err := os.ReadFile(filepath.Join(addonDir, addonCurrentLink, "serviceradar-np-addon"))
	if err != nil || !bytes.Equal(data, []byte("v1-binary")) {
		t.Fatalf("rollback did not restore v1 binary via current: data=%q err=%v", data, err)
	}
}

func TestRollbackAddonCurrentNoPriorRemovesSymlink(t *testing.T) {
	root := t.TempDir()
	addonDir := filepath.Join(root, "np")

	// First-time activation: nothing to roll back to.
	if _, ok := readAddonCurrentTarget(addonDir); ok {
		t.Fatal("expected no current symlink before first stage")
	}
	stageTestAddon(t, root, "1.0.0", []byte("v1"))

	if err := rollbackAddonCurrent(root, "np", ""); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(addonDir, addonCurrentLink)); !os.IsNotExist(err) {
		t.Fatalf("current symlink should be removed on no-prior rollback, lstat err=%v", err)
	}
}

func TestRollbackAddonCurrentTargetMissing(t *testing.T) {
	root := t.TempDir()
	addonDir := filepath.Join(root, "np")

	stageTestAddon(t, root, "1.0.0", []byte("v1"))
	prior, _ := readAddonCurrentTarget(addonDir)
	stageTestAddon(t, root, "2.0.0", []byte("v2"))

	// The prior version dir is gone, so rollback must refuse rather than dangle.
	if err := os.RemoveAll(filepath.Join(addonDir, addonVersionsDir, "1.0.0")); err != nil {
		t.Fatalf("remove prior version dir: %v", err)
	}
	if err := rollbackAddonCurrent(root, "np", prior); !errors.Is(err, ErrAddonRollbackTargetMissing) {
		t.Fatalf("want ErrAddonRollbackTargetMissing, got %v", err)
	}
}

func TestRollbackAddonCurrentRejectsUnsafeID(t *testing.T) {
	if err := rollbackAddonCurrent(t.TempDir(), "../etc", filepath.Join(addonVersionsDir, "1.0.0")); !errors.Is(err, ErrAddonUnsafePath) {
		t.Fatalf("want ErrAddonUnsafePath, got %v", err)
	}
}

// makeAddonTarGz builds a gzip tarball of name->content regular-file entries.
func makeAddonTarGz(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatalf("tar header %s: %v", name, err)
		}
		if _, err := tw.Write(content); err != nil {
			t.Fatalf("tar write %s: %v", name, err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("tar close: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}

	return buf.Bytes()
}

func readJSONMap(t *testing.T, path string) map[string]any {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}

	return out
}

func TestStageAddonArtifactExtractsTarball(t *testing.T) {
	root := t.TempDir()
	tgz := makeAddonTarGz(t, map[string][]byte{
		"serviceradar-np-addon":   []byte("#!/bin/sh\necho np\n"),
		"addon.yaml":              []byte("id: netprobe\n"),
		"serviceradar-np.service": []byte("[Service]\nExecStart=/bin/true\n"),
		"serviceradar-np.timer":   []byte("[Timer]\nOnUnitActiveSec=6h\n"),
	})
	key := "addons/netprobe/linux-amd64"
	store := &fakeObjectStore{data: map[string][]byte{key: tgz}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "netprobe",
		Version:           "1.0.0",
		BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-np-addon",
		Delivery:          "pushed_artifact",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(tgz),
	}

	got, err := stageAddonArtifact(context.Background(), store, root, a)
	if err != nil {
		t.Fatalf("stage: %v", err)
	}

	// The binary resolves under current/ and is executable.
	if filepath.Base(got) != "serviceradar-np-addon" {
		t.Fatalf("binary base = %q", filepath.Base(got))
	}
	info, err := os.Stat(got)
	if err != nil || info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("binary missing/not executable: mode=%v err=%v", info.Mode(), err)
	}

	// The manifest + systemd units are extracted alongside the binary under current/,
	// where the agent discovers them and the updater installs them.
	cur := filepath.Join(root, "netprobe", addonCurrentLink)
	for _, f := range []string{"addon.yaml", "serviceradar-np.service", "serviceradar-np.timer"} {
		fi, statErr := os.Stat(filepath.Join(cur, f))
		if statErr != nil {
			t.Fatalf("expected extracted %s: %v", f, statErr)
		}
		if fi.Mode().Perm()&0o111 != 0 {
			t.Fatalf("non-binary file %s should not be executable: %v", f, fi.Mode())
		}
	}
}

func TestApplyStagedAddonRuntimeConfigMergesAssignmentConfig(t *testing.T) {
	runtimeRoot := t.TempDir()
	root := resolveAddonArtifactRoot(runtimeRoot)
	tgz := makeAddonTarGz(t, map[string][]byte{
		"serviceradar-workload-identity": []byte("#!/bin/sh\necho workload\n"),
		"workload-identity.json": []byte(`{
  "enabled": true,
  "root": "/",
  "context_name": "",
  "refresh_interval_s": 60,
  "spool_dir": "/var/lib/serviceradar/workload-identity/spool"
}
`),
		"serviceradar-workload-identity.service": []byte("[Service]\nExecStart=/bin/true\n"),
	})
	key := "addons/workload-identity/linux-amd64"
	store := &fakeObjectStore{data: map[string][]byte{key: tgz}}

	a := &proto.AddonAssignmentConfig{
		AddonId:           "workload-identity",
		Version:           "0.1.3",
		BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-workload-identity",
		Delivery:          "pushed_artifact",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(tgz),
		ConfigJson:        []byte(`{"context_name":"default-cp3"}`),
	}

	if _, err := stageAddonArtifact(context.Background(), store, root, a); err != nil {
		t.Fatalf("stage: %v", err)
	}
	if err := applyStagedAddonRuntimeConfig(runtimeRoot, a); err != nil {
		t.Fatalf("apply config: %v", err)
	}

	configPath := filepath.Join(root, "workload-identity", addonCurrentLink, "workload-identity.json")
	config := readJSONMap(t, configPath)
	if config["enabled"] != true {
		t.Fatalf("enabled = %#v, want true", config["enabled"])
	}
	if config["context_name"] != "default-cp3" {
		t.Fatalf("context_name = %#v, want default-cp3", config["context_name"])
	}

	// Re-applying a changed assignment should merge from the preserved artifact base,
	// not from the previously written runtime config, so removed fields do not stick.
	a.ConfigJson = []byte(`{"refresh_interval_s":30}`)
	if err := applyStagedAddonRuntimeConfig(runtimeRoot, a); err != nil {
		t.Fatalf("reapply config: %v", err)
	}
	config = readJSONMap(t, configPath)
	if config["context_name"] != "" {
		t.Fatalf("context_name = %#v, want artifact default after override removal", config["context_name"])
	}
	if config["refresh_interval_s"] != float64(30) {
		t.Fatalf("refresh_interval_s = %#v, want 30", config["refresh_interval_s"])
	}
}

func TestStageAddonArtifactTarballMissingBinary(t *testing.T) {
	root := t.TempDir()
	tgz := makeAddonTarGz(t, map[string][]byte{
		"addon.yaml": []byte("id: x\n"),
		"x.service":  []byte("[Service]\n"),
	})
	key := testAddonKeyX
	store := &fakeObjectStore{data: map[string][]byte{key: tgz}}
	a := &proto.AddonAssignmentConfig{
		AddonId: "x", Version: "1.0.0", BinaryPath: "serviceradar-x-addon",
		ArtifactObjectKey: key, ArtifactSha256: sha256Hex(tgz),
	}

	if _, err := stageAddonArtifact(context.Background(), store, root, a); !errors.Is(err, ErrAddonTarballBinaryMissing) {
		t.Fatalf("want ErrAddonTarballBinaryMissing, got %v", err)
	}
}

func TestStageAddonArtifactTarballRejectsUnsafeEntries(t *testing.T) {
	root := t.TempDir()

	build := func(hdr *tar.Header, body []byte) []byte {
		var buf bytes.Buffer
		gz := gzip.NewWriter(&buf)
		tw := tar.NewWriter(gz)
		if hdr.Size == 0 && len(body) > 0 {
			hdr.Size = int64(len(body))
		}
		_ = tw.WriteHeader(hdr)
		_, _ = tw.Write(body)
		_ = tw.Close()
		_ = gz.Close()
		return buf.Bytes()
	}

	cases := map[string][]byte{
		"traversal": build(&tar.Header{Name: "../evil", Mode: 0o644, Typeflag: tar.TypeReg}, []byte("x")),
		"subdir":    build(&tar.Header{Name: "sub/x.service", Mode: 0o644, Typeflag: tar.TypeReg}, []byte("x")),
		"symlink":   build(&tar.Header{Name: "serviceradar-x-addon", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"}, nil),
	}

	for name, tgz := range cases {
		t.Run(name, func(t *testing.T) {
			key := testAddonKeyX
			store := &fakeObjectStore{data: map[string][]byte{key: tgz}}
			a := &proto.AddonAssignmentConfig{
				AddonId: "x", Version: "1.0.0", BinaryPath: "serviceradar-x-addon",
				ArtifactObjectKey: key, ArtifactSha256: sha256Hex(tgz),
			}
			if _, err := stageAddonArtifact(context.Background(), store, root, a); !errors.Is(err, ErrAddonTarballUnsafe) {
				t.Fatalf("want ErrAddonTarballUnsafe, got %v", err)
			}
		})
	}
}

func TestEphemeralHelperRegistry(t *testing.T) {
	const rdpHelperPath = "/staged/rdp/current/serviceradar-rdp-adapter"

	pl := &PushLoop{logger: logger.NewTestLogger()}

	if _, ok := pl.EphemeralHelperPath("rdp"); ok {
		t.Fatal("expected empty ephemeral-helper registry")
	}

	pl.rememberEphemeralHelper("rdp", rdpHelperPath)
	if path, ok := pl.EphemeralHelperPath("rdp"); !ok || path != rdpHelperPath {
		t.Fatalf("EphemeralHelperPath = %q,%v", path, ok)
	}

	// A helper that becomes unassigned is deregistered; the still-desired one remains.
	pl.rememberEphemeralHelper("gone", "/staged/gone/current/bin")
	pl.reconcileEphemeralHelpers(map[string]bool{"rdp": true})
	if _, ok := pl.EphemeralHelperPath("gone"); ok {
		t.Fatal("expected 'gone' to be deregistered after reconcile")
	}
	if _, ok := pl.EphemeralHelperPath("rdp"); !ok {
		t.Fatal("expected 'rdp' to remain registered")
	}
}

func TestStageAddonArtifactTarballRejectsTooManyEntries(t *testing.T) {
	root := t.TempDir()
	files := make(map[string][]byte, maxAddonTarballEntries+2)
	for i := 0; i <= maxAddonTarballEntries+1; i++ {
		files[fmt.Sprintf("f%d.service", i)] = []byte("[Service]\n")
	}
	tgz := makeAddonTarGz(t, files)
	store := &fakeObjectStore{data: map[string][]byte{testAddonKeyX: tgz}}
	a := &proto.AddonAssignmentConfig{
		AddonId: "x", Version: "1.0.0", BinaryPath: "serviceradar-x-addon",
		ArtifactObjectKey: testAddonKeyX, ArtifactSha256: sha256Hex(tgz),
	}

	if _, err := stageAddonArtifact(context.Background(), store, root, a); !errors.Is(err, ErrAddonTarballTooLarge) {
		t.Fatalf("want ErrAddonTarballTooLarge, got %v", err)
	}
}

// TestStageAddonArtifactViaGatewayHTTP verifies that, with a gateway download_url, the
// artifact is fetched over HTTP (presenting the download token) and still passes sha256
// + ed25519 verification before staging - all WITHOUT an object store (the external-agent
// path). It also confirms the gateway path does not call DownloadObject.
func TestStageAddonArtifactViaGatewayHTTP(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	setReleaseVerificationKey(t, hex.EncodeToString(pub))

	payload := []byte("gateway-delivered-addon-binary")
	const wantToken = "signed-download-token"

	var gotToken, gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotToken = r.Header.Get("X-ServiceRadar-Plugin-Token")
		gotMethod = r.Method
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	root := t.TempDir()
	a := &proto.AddonAssignmentConfig{
		AddonId:           "gw",
		Version:           "1.0.0",
		ArtifactObjectKey: "addons/gw/linux-amd64",
		ArtifactSha256:    sha256Hex(payload),
		ArtifactSignature: hex.EncodeToString(ed25519.Sign(priv, payload)),
		DownloadUrl:       srv.URL,
		DownloadToken:     wantToken,
	}

	// No object store: external agents have none; the gateway URL must drive the fetch.
	got, err := stageAddonArtifactWithClient(context.Background(), nil, srv.Client(), root, a)
	if err != nil {
		t.Fatalf("stage via gateway: %v", err)
	}
	if gotToken != wantToken {
		t.Fatalf("download token header = %q, want %q", gotToken, wantToken)
	}
	if gotMethod != http.MethodPost {
		t.Fatalf("download method = %q, want POST (token present)", gotMethod)
	}

	staged, err := os.ReadFile(got)
	if err != nil {
		t.Fatalf("read staged binary: %v", err)
	}
	if !bytes.Equal(staged, payload) {
		t.Fatalf("staged content mismatch")
	}
}

// TestStageAddonArtifactGatewayHashMismatch confirms a gateway-delivered artifact is still
// rejected when its bytes do not match the assigned sha256 (verification is not skipped on
// the HTTP path).
func TestStageAddonArtifactGatewayHashMismatch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("tampered-bytes"))
	}))
	defer srv.Close()

	a := &proto.AddonAssignmentConfig{
		AddonId:           "gw",
		Version:           "1.0.0",
		ArtifactObjectKey: "addons/gw/linux-amd64",
		ArtifactSha256:    sha256Hex([]byte("expected-bytes")),
		DownloadUrl:       srv.URL,
		DownloadToken:     "tok",
	}

	if _, err := stageAddonArtifactWithClient(context.Background(), nil, srv.Client(), t.TempDir(), a); !errors.Is(err, ErrAddonArtifactHashMismatch) {
		t.Fatalf("want ErrAddonArtifactHashMismatch, got %v", err)
	}
}

// TestStageAddonArtifactGatewayMissingClient confirms that a gateway download_url with no
// HTTP client (gateway security unconfigured) surfaces as object-store-unavailable rather
// than silently falling back to a nil store.
func TestStageAddonArtifactGatewayMissingClient(t *testing.T) {
	a := &proto.AddonAssignmentConfig{
		AddonId:           "gw",
		Version:           "1.0.0",
		ArtifactObjectKey: "addons/gw/linux-amd64",
		ArtifactSha256:    sha256Hex([]byte("x")),
		DownloadUrl:       "https://gateway.example:50053/artifacts/addons/p/blob/download",
		DownloadToken:     "tok",
	}

	if _, err := stageAddonArtifactWithClient(context.Background(), nil, nil, t.TempDir(), a); !errors.Is(err, ErrAddonObjectStoreUnavailable) {
		t.Fatalf("want ErrAddonObjectStoreUnavailable, got %v", err)
	}
}

func TestGatewayAddonHTTPClientRequiresGatewaySecurity(t *testing.T) {
	pl := &PushLoop{}
	client := pl.gatewayAddonHTTPClient(&proto.AddonAssignmentConfig{
		AddonId:     "gw",
		DownloadUrl: "https://demo-gw.serviceradar.cloud:50053/artifacts/addons/pkg/blob/download",
	})
	if client != nil {
		t.Fatalf("expected nil client without gateway security, got %#v", client)
	}
}

// TestApplyConfigResponseDefersVersionWhenAddonDeliveryFails covers a TRANSIENT delivery
// failure: the assignment references an object-store artifact but the agent has no object
// store configured (ErrAddonObjectStoreUnavailable). That may clear once the store comes
// up, so the config-version ack is deferred and delivery retried on the next poll.
func TestApplyConfigResponseDefersVersionWhenAddonDeliveryFails(t *testing.T) {
	pl := &PushLoop{
		server: &Server{
			addonManager: agentaddon.NewManager(agentaddon.Config{
				RuntimeDir: filepath.Join(t.TempDir(), "addons"),
			}),
		},
		logger:                         logger.NewTestLogger(),
		hostNetworkVisibilitySupported: func() bool { return true },
	}
	pl.setConfigVersion(testOldConfigVersion)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons: []*proto.AddonAssignmentConfig{
			{
				AddonId:           "netprobe",
				Enabled:           true,
				Delivery:          addonDeliveryPushedArtifact,
				Supervision:       addonSupervisionAgentSidecar,
				ArtifactObjectKey: "native-addons/netprobe/0.2.1/linux/amd64/netprobe.tar.gz",
				ArtifactSha256:    sha256Hex([]byte("artifact")),
			},
		},
	}, "poll")

	if ok {
		t.Fatal("applyConfigResponse() = true, want false when add-on delivery fails transiently")
	}
	if got := pl.getConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("config version = %q, want %s", got, testOldConfigVersion)
	}
}

// TestStageAddonArtifactGatewayNon200 confirms a non-200 gateway response is surfaced as a
// download failure rather than staged as artifact bytes.
func TestStageAddonArtifactGatewayNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	a := &proto.AddonAssignmentConfig{
		AddonId:           "gw",
		Version:           "1.0.0",
		ArtifactObjectKey: "addons/gw/linux-amd64",
		ArtifactSha256:    sha256Hex([]byte("x")),
		DownloadUrl:       srv.URL,
		DownloadToken:     "tok",
	}

	if _, err := stageAddonArtifactWithClient(context.Background(), nil, srv.Client(), t.TempDir(), a); !errors.Is(err, ErrAddonArtifactDownloadFailed) {
		t.Fatalf("want ErrAddonArtifactDownloadFailed, got %v", err)
	}
}

func TestAddonResourcesFromProto(t *testing.T) {
	if got := addonResourcesFromProto(nil); !got.IsZero() {
		t.Fatalf("nil proto resources should map to the zero value, got %+v", got)
	}

	got := addonResourcesFromProto(&proto.AddonResources{
		CpuMaxPercent:   50,
		MemoryMaxBytes:  268435456,
		MemoryHighBytes: 201326592,
		TasksMax:        32,
		Slice:           "serviceradar-addons.slice",
	})

	want := agentaddon.Resources{
		CPUMaxPercent:   50,
		MemoryMaxBytes:  268435456,
		MemoryHighBytes: 201326592,
		TasksMax:        32,
		Slice:           "serviceradar-addons.slice",
	}

	if got != want {
		t.Fatalf("addonResourcesFromProto = %+v, want %+v", got, want)
	}
}

// setReleaseVerificationKey points the agent's release trust root at key for the duration of t.
//
// It sets BOTH channels that releaseVerificationKey() consults, and the package variable is the
// one that matters: ReleaseSigningPublicKey is embedded from a committed source file and takes
// precedence, so the env var alone is only honoured when that embedded value is empty. It used
// to be empty in every non-release build -- the key was injected by --stamp, which only the
// release job passed -- so setting the env var alone happened to work here while testing a
// configuration that never shipped.
func setReleaseVerificationKey(t *testing.T, key string) {
	t.Helper()

	t.Setenv(releasePublicKeyEnv, key)

	previous := ReleaseSigningPublicKey
	ReleaseSigningPublicKey = key
	t.Cleanup(func() { ReleaseSigningPublicKey = previous })
}
