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

import (
	"errors"
	"testing"
	"time"
)

func TestEvaluateManifestQuerySupportsExistsCountAndDetail(t *testing.T) {
	scannedAt := time.Unix(100, 0).UTC()
	manifest := endpointInventoryQueryManifest(scannedAt)
	cfg := DefaultConfig()
	cfg.AgentID = configTestAgentID
	cfg.CacheStaleThreshold = endpointInventoryTestTenMins
	now := scannedAt.Add(2 * time.Minute)

	exists, err := EvaluateManifestQuery(cfg, manifest, EndpointInventoryQuery{
		Mode: QueryModeExists,
		Predicate: PackagePredicate{
			PackageManager: PackageSourceDpkg,
			Name:           "nginx",
		},
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	if !exists.Matched || exists.Count != 2 || exists.Freshness.Verdict != FreshnessFresh {
		t.Fatalf("unexpected exists result: %#v", exists)
	}

	count, err := EvaluateManifestQuery(cfg, manifest, EndpointInventoryQuery{
		Mode: QueryModeCount,
		Predicate: PackagePredicate{
			CPE: "cpe:2.3:a:nginx:nginx:1.25:*:*:*:*:*:*:*",
		},
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	if !count.Matched || count.Count != 1 || len(count.Packages) != 0 {
		t.Fatalf("unexpected count result: %#v", count)
	}

	detail, err := EvaluateManifestQuery(cfg, manifest, EndpointInventoryQuery{
		Mode: QueryModeDetail,
		Predicate: PackagePredicate{
			Name: "nginx",
		},
		Limit: 1,
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	if detail.Count != 2 || len(detail.Packages) != 1 || !detail.Truncated {
		t.Fatalf("unexpected detail result: %#v", detail)
	}
}

func TestEvaluateManifestQueryReportsStaleAndRejectsUnsafeInput(t *testing.T) {
	scannedAt := time.Unix(100, 0).UTC()
	manifest := endpointInventoryQueryManifest(scannedAt)
	cfg := DefaultConfig()
	now := scannedAt.Add(20 * time.Minute)

	result, err := EvaluateManifestQuery(cfg, manifest, EndpointInventoryQuery{
		Mode: QueryModeCount,
		Predicate: PackagePredicate{
			Name: "missing",
		},
		StaleThresholdSeconds: 60,
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Matched || result.Freshness.Verdict != FreshnessStale {
		t.Fatalf("unexpected stale non-match result: %#v", result)
	}

	_, err = EvaluateManifestQuery(cfg, manifest, EndpointInventoryQuery{
		Mode:      QueryModeDetail,
		Predicate: PackagePredicate{Name: "nginx"},
		Limit:     maxDetailLimit + 1,
	}, now)
	if !errors.Is(err, ErrUnsafeQueryLimit) {
		t.Fatalf("err = %v, want ErrUnsafeQueryLimit", err)
	}

	_, err = EvaluateManifestQuery(cfg, manifest, EndpointInventoryQuery{
		Mode: QueryModeCount,
	}, now)
	if !errors.Is(err, ErrEmptyQueryPredicate) {
		t.Fatalf("err = %v, want ErrEmptyQueryPredicate", err)
	}
}

func TestDefaultFreshnessThresholdUsesTwentySixHourGrace(t *testing.T) {
	scannedAt := time.Unix(100, 0).UTC()
	manifest := endpointInventoryQueryManifest(scannedAt)
	cfg := DefaultConfig()
	predicate := EndpointInventoryQuery{Mode: QueryModeCount, Predicate: PackagePredicate{Name: "nginx"}}

	fresh, err := EvaluateManifestQuery(cfg, manifest, predicate, scannedAt.Add(25*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Freshness.Verdict != FreshnessFresh {
		t.Fatalf("25-hour inventory = %q, want fresh", fresh.Freshness.Verdict)
	}

	stale, err := EvaluateManifestQuery(cfg, manifest, predicate, scannedAt.Add(27*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if stale.Freshness.Verdict != FreshnessStale {
		t.Fatalf("27-hour inventory = %q, want stale", stale.Freshness.Verdict)
	}

	cfg.CacheStaleThreshold = "invalid"
	fallback, err := EvaluateManifestQuery(cfg, manifest, predicate, scannedAt.Add(25*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if fallback.Freshness.Verdict != FreshnessFresh || fallback.StaleThresholdSeconds != 26*60*60 {
		t.Fatalf("invalid-config fallback did not use 26h: %#v", fallback.Freshness)
	}
}

func endpointInventoryQueryManifest(scannedAt time.Time) *InventoryCacheManifest {
	return &InventoryCacheManifest{
		SchemaVersion:        CacheVersion,
		AgentID:              configTestAgentID,
		PackageSetHash:       "package-hash",
		ArtifactHash:         "artifact-hash",
		HashAlgorithm:        HashAlgorithm,
		LastSuccessfulScanAt: &scannedAt,
		Packages: []Package{
			{
				Name:      "nginx",
				Version:   "1.24.0",
				Manager:   PackageSourceDpkg,
				Ecosystem: "deb",
				PURL:      "pkg:deb/nginx@1.24.0?arch=amd64",
			},
			{
				Name:      "nginx",
				Version:   "1.25.0",
				Manager:   PackageSourceDpkg,
				Ecosystem: "deb",
				CPEs:      []string{"cpe:2.3:a:nginx:nginx:1.25:*:*:*:*:*:*:*"},
			},
			{
				Name:      "openssl",
				Version:   "3.0.0",
				Manager:   PackageSourceDpkg,
				Ecosystem: "deb",
			},
		},
		SourceSummaries: []SourceSummary{
			{Source: PackageSourceDpkg, State: "scanned", PackageCount: 3},
		},
	}
}
