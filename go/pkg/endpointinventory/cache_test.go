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

package endpointinventory

import "testing"

func TestCacheCanSkipFullScanRespectsForceFullScanInterval(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.ForceFullScanInterval = 2
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
	}

	if !cacheCanSkipFullScan(cfg, manifest, current) {
		t.Fatal("cache should skip before the forced full scan interval")
	}

	manifest.ScansSinceFull = 1
	if cacheCanSkipFullScan(cfg, manifest, current) {
		t.Fatal("cache should not skip at the forced full scan interval")
	}
}
