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

	"github.com/carverauto/serviceradar/proto"
)

var errFakeObjectNotFound = errors.New("fake object store: key not found")

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

func TestLastKnownGoodAddonBinaryFallback(t *testing.T) {
	root := t.TempDir()
	payload := []byte("addon-v1-binary")
	key := "addons/lkg/linux-amd64"
	a := &proto.AddonAssignmentConfig{
		AddonId:           "lkg",
		Version:           "1.0.0",
		BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-lkg-addon",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(payload),
	}

	// Nothing staged yet: no last-known-good.
	if _, ok := lastKnownGoodAddonBinary(root, a); ok {
		t.Fatal("expected no last-known-good before any staging")
	}

	// Stage once successfully.
	store := &fakeObjectStore{data: map[string][]byte{key: payload}}
	good, err := stageAddonArtifact(context.Background(), store, root, a)
	if err != nil {
		t.Fatalf("initial stage: %v", err)
	}

	lkg, ok := lastKnownGoodAddonBinary(root, a)
	if !ok {
		t.Fatal("expected last-known-good after a successful stage")
	}
	if lkg != good {
		t.Fatalf("last-known-good = %q, want %q", lkg, good)
	}

	// A later delivery that fails (object store down) must leave the
	// last-known-good binary intact for the caller to fall back to.
	failing := &fakeObjectStore{err: errFakeObjectNotFound}
	if _, err := stageAddonArtifact(context.Background(), failing, root, a); err == nil {
		t.Fatal("expected staging to fail with a failing object store")
	}

	again, ok := lastKnownGoodAddonBinary(root, a)
	if !ok || again != good {
		t.Fatalf("last-known-good lost after a failed delivery: ok=%v path=%q", ok, again)
	}

	data, err := os.ReadFile(again)
	if err != nil || !bytes.Equal(data, payload) {
		t.Fatalf("last-known-good binary not intact: err=%v", err)
	}
}

func TestApplyLocalAddonOverridesMissingFileIsNoop(t *testing.T) {
	pushed := []*proto.AddonAssignmentConfig{{AddonId: "a", BinaryPath: "/pushed/a"}}

	got, err := applyLocalAddonOverrides(pushed, filepath.Join(t.TempDir(), "absent.json"))
	if err != nil {
		t.Fatalf("missing file should be a no-op, got %v", err)
	}
	if len(got) != 1 || got[0].GetBinaryPath() != "/pushed/a" {
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
		{AddonId: "a", BinaryPath: "/pushed/a", Enabled: true},
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
		t.Fatalf("local override did not replace pushed 'a': %q", byID["a"].GetBinaryPath())
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

	pushed := []*proto.AddonAssignmentConfig{{AddonId: "a", BinaryPath: "/pushed/a"}}

	got, err := applyLocalAddonOverrides(pushed, path)
	if err == nil {
		t.Fatal("expected an error for malformed override")
	}
	if len(got) != 1 || got[0].GetBinaryPath() != "/pushed/a" {
		t.Fatalf("malformed override must return pushed unchanged: %#v", got)
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
