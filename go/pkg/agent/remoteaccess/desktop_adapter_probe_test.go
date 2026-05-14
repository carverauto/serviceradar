/*
 * Copyright 2025 Carver Automation Corporation.
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

package remoteaccess

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveRDPAdapterPath(t *testing.T) {
	t.Parallel()

	if got := NormalizeRDPAdapterPath(" "); got != DefaultRDPAdapterBinary {
		t.Fatalf("default adapter path = %q, want %q", got, DefaultRDPAdapterBinary)
	}

	dir := t.TempDir()
	adapterPath := filepath.Join(dir, DefaultRDPAdapterBinary)
	if err := os.WriteFile(adapterPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}

	resolved, err := ResolveRDPAdapterPath(adapterPath)
	if err != nil {
		t.Fatalf("ResolveRDPAdapterPath returned error: %v", err)
	}
	if resolved != adapterPath {
		t.Fatalf("resolved adapter path = %q, want %q", resolved, adapterPath)
	}
	if !RDPAdapterBinaryAvailable(adapterPath) {
		t.Fatal("RDPAdapterBinaryAvailable returned false for executable helper")
	}

	if _, err := ResolveRDPAdapterPath(filepath.Join(dir, "missing")); !errors.Is(err, ErrDesktopAdapterUnavailable) {
		t.Fatalf("missing adapter error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}
}
