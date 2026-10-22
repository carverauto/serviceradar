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

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadManifestReadsFileInNestedDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "addons", "sample-addon")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	path := filepath.Join(dir, "addon.yaml")
	want := []byte("name: sample-addon\n")
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	got, err := readManifest(path)
	if err != nil {
		t.Fatalf("readManifest: %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("readManifest = %q, want %q", got, want)
	}
}

func TestReadManifestRejectsMissingFileAndSymlinkEscape(t *testing.T) {
	root := t.TempDir()

	if _, err := readManifest(filepath.Join(root, "missing.yaml")); err == nil {
		t.Fatal("readManifest of a missing file must return an error")
	}

	outside := filepath.Join(t.TempDir(), "outside.yaml")
	if err := os.WriteFile(outside, []byte("name: outside\n"), 0o600); err != nil {
		t.Fatalf("write outside file: %v", err)
	}
	link := filepath.Join(root, "addon.yaml")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	if _, err := readManifest(link); err == nil {
		t.Fatal("readManifest must not follow a symlink out of the manifest directory")
	}
}
