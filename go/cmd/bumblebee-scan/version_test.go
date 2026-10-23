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
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

func TestAddonVersionMatchesManifest(t *testing.T) {
	path, err := runfiles.Rlocation("_main/addons/bumblebee-scan/addon.yaml")
	if err != nil {
		t.Fatalf("runfiles.Rlocation: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read addon.yaml: %v", err)
	}

	var manifestVersion string
	for line := range strings.Lines(string(data)) {
		if rest, ok := strings.CutPrefix(line, "version:"); ok {
			manifestVersion = strings.TrimSpace(rest)
			break
		}
	}

	if manifestVersion == "" {
		t.Fatal("addon.yaml has no top-level version field")
	}
	if addonVersion != manifestVersion {
		t.Fatalf("addonVersion = %q, want manifest version %q", addonVersion, manifestVersion)
	}
}
