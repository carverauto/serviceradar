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
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/proto"
)

var errFakeObjectNotFound = errors.New("fake object store: key not found")

const testPushedBinaryA = "/pushed/a"

type fakeObjectStore struct {
	data map[string][]byte
	err  error
}

func (f *fakeObjectStore) DownloadObject(_ context.Context, key string) ([]byte, error) {
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

func TestStageAddonArtifactHashMismatch(t *testing.T) {
	root := t.TempDir()
	key := "addons/x"
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
	t.Setenv(releasePublicKeyEnv, "")

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
		addonSupervisionSystemdService:  addonDispatchExternalUnimplemented,
		addonSupervisionSystemdTimer:    addonDispatchExternalUnimplemented,
		addonSupervisionEphemeralHelper: addonDispatchExternalUnimplemented,
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
	t.Setenv(releasePublicKeyEnv, hex.EncodeToString(pub))

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
