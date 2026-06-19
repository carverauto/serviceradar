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

package addon

import (
	"path/filepath"
	"testing"
)

func TestAddonCgroupParentUsesManifestSlice(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "sys", "fs", "cgroup")
	res := Resources{Slice: "serviceradar-addons.slice"}

	want := filepath.Join(root, "serviceradar-addons.slice")
	if got := addonCgroupParent(root, res); got != want {
		t.Fatalf("addonCgroupParent = %q, want %q", got, want)
	}
}

func TestAddonCgroupParentDoesNotDuplicateSliceRoot(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "sys", "fs", "cgroup", "serviceradar-addons.slice")
	res := Resources{Slice: "serviceradar-addons.slice"}

	if got := addonCgroupParent(root, res); got != root {
		t.Fatalf("addonCgroupParent = %q, want existing slice root %q", got, root)
	}
}
