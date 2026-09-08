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
	"fmt"
	"strings"
	"time"
)

const (
	QueryModeExists = "exists"
	QueryModeCount  = "count"
	QueryModeDetail = "detail"

	FreshnessFresh   = "fresh"
	FreshnessStale   = "stale"
	FreshnessUnknown = "unknown"

	defaultDetailLimit = 25
	maxDetailLimit     = 100
)

var (
	ErrInventoryCacheUnavailable = errors.New("endpoint inventory cache unavailable")
	ErrInvalidQueryMode          = errors.New("invalid endpoint inventory query mode")
	ErrUnsafeQueryLimit          = errors.New("unsafe endpoint inventory query limit")
	ErrEmptyQueryPredicate       = errors.New("empty endpoint inventory query predicate")
)

type QueryMode string

type EndpointInventoryQuery struct {
	Schema                string                 `json:"schema,omitempty"`
	Mode                  string                 `json:"mode,omitempty"`
	Predicate             PackagePredicate       `json:"predicate"`
	Limit                 int                    `json:"limit,omitempty"`
	StaleThresholdSeconds int64                  `json:"stale_threshold_seconds,omitempty"`
	Metadata              map[string]interface{} `json:"metadata,omitempty"`
}

type EndpointInventoryForceFreshCommand struct {
	Schema     string                  `json:"schema,omitempty"`
	Authorized bool                    `json:"authorized,omitempty"`
	Sources    []string                `json:"sources,omitempty"`
	Query      *EndpointInventoryQuery `json:"query,omitempty"`
	Metadata   map[string]interface{}  `json:"metadata,omitempty"`
}

type PackagePredicate struct {
	PackageManager string `json:"package_manager,omitempty"`
	Name           string `json:"name,omitempty"`
	Version        string `json:"version,omitempty"`
	Architecture   string `json:"architecture,omitempty"`
	Ecosystem      string `json:"ecosystem,omitempty"`
	PURL           string `json:"purl,omitempty"`
	CPE            string `json:"cpe,omitempty"`
}

type EndpointInventoryQueryResult struct {
	Schema                  string           `json:"schema"`
	AgentID                 string           `json:"agent_id"`
	Mode                    string           `json:"mode"`
	Matched                 bool             `json:"matched"`
	Count                   int              `json:"count"`
	Packages                []Package        `json:"packages,omitempty"`
	PackageSetHash          string           `json:"package_set_hash,omitempty"`
	ArtifactHash            string           `json:"artifact_hash,omitempty"`
	HashAlgorithm           string           `json:"hash_algorithm,omitempty"`
	LastSuccessfulScanAt    *time.Time       `json:"last_successful_scan_at,omitempty"`
	LastChangedScanAt       *time.Time       `json:"last_changed_scan_at,omitempty"`
	UnchangedScanCount      int              `json:"unchanged_scan_count"`
	SourceSummaries         []SourceSummary  `json:"source_summaries,omitempty"`
	Freshness               FreshnessVerdict `json:"freshness"`
	StaleThresholdSeconds   int64            `json:"stale_threshold_seconds"`
	EvaluatedAt             time.Time        `json:"evaluated_at"`
	Truncated               bool             `json:"truncated,omitempty"`
	UnsupportedCapabilities []string         `json:"unsupported_capabilities,omitempty"`
	Metadata                map[string]any   `json:"metadata,omitempty"`
}

type FreshnessVerdict struct {
	Verdict               string     `json:"verdict"`
	AgeSeconds            int64      `json:"age_seconds,omitempty"`
	StaleThresholdSeconds int64      `json:"stale_threshold_seconds,omitempty"`
	LastSuccessfulScanAt  *time.Time `json:"last_successful_scan_at,omitempty"`
}

func EvaluateCacheQuery(cfg Config, query EndpointInventoryQuery, now time.Time) (*EndpointInventoryQueryResult, error) {
	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		return nil, err
	}
	if manifest == nil || manifest.PackageSetHash == "" {
		return nil, ErrInventoryCacheUnavailable
	}

	return EvaluateManifestQuery(cfg, manifest, query, now)
}

func EvaluateManifestQuery(
	cfg Config,
	manifest *InventoryCacheManifest,
	query EndpointInventoryQuery,
	now time.Time,
) (*EndpointInventoryQueryResult, error) {
	if manifest == nil || manifest.PackageSetHash == "" {
		return nil, ErrInventoryCacheUnavailable
	}

	mode := normalizeQueryMode(query.Mode)
	if mode == "" {
		return nil, ErrInvalidQueryMode
	}
	limit, err := normalizedQueryLimit(mode, query.Limit)
	if err != nil {
		return nil, err
	}
	if !query.Predicate.hasAnyField() {
		return nil, ErrEmptyQueryPredicate
	}

	matches := matchingPackages(manifest.Packages, query.Predicate, limit)
	result := &EndpointInventoryQueryResult{
		Schema:                "serviceradar.endpoint_inventory.query_result.v1",
		AgentID:               firstNonEmpty(manifest.AgentID, cfg.AgentID),
		Mode:                  mode,
		Matched:               len(matches) > 0,
		Count:                 countMatchingPackages(manifest.Packages, query.Predicate),
		PackageSetHash:        manifest.PackageSetHash,
		ArtifactHash:          manifest.ArtifactHash,
		HashAlgorithm:         firstNonEmpty(manifest.HashAlgorithm, HashAlgorithm),
		LastSuccessfulScanAt:  manifest.LastSuccessfulScanAt,
		LastChangedScanAt:     manifest.LastChangedScanAt,
		UnchangedScanCount:    manifest.UnchangedScanCount,
		SourceSummaries:       append([]SourceSummary(nil), manifest.SourceSummaries...),
		StaleThresholdSeconds: staleThresholdSeconds(cfg, query),
		EvaluatedAt:           now.UTC(),
	}
	result.Freshness = freshnessVerdict(manifest.LastSuccessfulScanAt, result.StaleThresholdSeconds, now)

	if mode == QueryModeDetail {
		result.Packages = matches
		result.Truncated = result.Count > len(matches)
	}

	return result, nil
}

func normalizeQueryMode(mode string) string {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "", QueryModeExists:
		return QueryModeExists
	case QueryModeCount:
		return QueryModeCount
	case QueryModeDetail:
		return QueryModeDetail
	default:
		return ""
	}
}

func normalizedQueryLimit(mode string, requested int) (int, error) {
	if mode != QueryModeDetail {
		return 0, nil
	}
	if requested == 0 {
		return defaultDetailLimit, nil
	}
	if requested < 0 || requested > maxDetailLimit {
		return 0, fmt.Errorf("%w: %d", ErrUnsafeQueryLimit, requested)
	}

	return requested, nil
}

func countMatchingPackages(packages []Package, predicate PackagePredicate) int {
	count := 0
	for _, pkg := range packages {
		if predicate.matches(pkg) {
			count++
		}
	}

	return count
}

func matchingPackages(packages []Package, predicate PackagePredicate, limit int) []Package {
	matches := make([]Package, 0)
	for _, pkg := range packages {
		if !predicate.matches(pkg) {
			continue
		}
		matches = append(matches, pkg)
		if limit > 0 && len(matches) >= limit {
			break
		}
	}

	return matches
}

func staleThresholdSeconds(cfg Config, query EndpointInventoryQuery) int64 {
	if query.StaleThresholdSeconds > 0 {
		return query.StaleThresholdSeconds
	}

	threshold, err := time.ParseDuration(cfg.CacheStaleThreshold)
	if err != nil || threshold <= 0 {
		threshold = 26 * time.Hour
	}

	return int64(threshold.Seconds())
}

func freshnessVerdict(lastSuccessful *time.Time, staleThresholdSeconds int64, now time.Time) FreshnessVerdict {
	verdict := FreshnessVerdict{
		Verdict:               FreshnessUnknown,
		StaleThresholdSeconds: staleThresholdSeconds,
		LastSuccessfulScanAt:  lastSuccessful,
	}
	if lastSuccessful == nil {
		return verdict
	}

	age := int64(now.UTC().Sub(lastSuccessful.UTC()).Seconds())
	if age < 0 {
		age = 0
	}
	verdict.AgeSeconds = age
	if staleThresholdSeconds > 0 && age > staleThresholdSeconds {
		verdict.Verdict = FreshnessStale
	} else {
		verdict.Verdict = FreshnessFresh
	}

	return verdict
}

func (p PackagePredicate) hasAnyField() bool {
	return strings.TrimSpace(p.PackageManager) != "" ||
		strings.TrimSpace(p.Name) != "" ||
		strings.TrimSpace(p.Version) != "" ||
		strings.TrimSpace(p.Architecture) != "" ||
		strings.TrimSpace(p.Ecosystem) != "" ||
		strings.TrimSpace(p.PURL) != "" ||
		strings.TrimSpace(p.CPE) != ""
}

func (p PackagePredicate) matches(pkg Package) bool {
	if !matchesField(p.PackageManager, pkg.Manager) {
		return false
	}
	if !matchesField(p.Name, pkg.Name) {
		return false
	}
	if !matchesField(p.Version, pkg.Version) {
		return false
	}
	if !matchesField(p.Architecture, pkg.Arch) {
		return false
	}
	if !matchesField(p.Ecosystem, pkg.Ecosystem) {
		return false
	}
	if purl := strings.TrimSpace(p.PURL); purl != "" && purl != CanonicalPackagePURL(pkg) && purl != strings.TrimSpace(pkg.PURL) {
		return false
	}
	if cpe := strings.TrimSpace(p.CPE); cpe != "" && !containsString(pkg.CPEs, cpe) {
		return false
	}

	return true
}

func matchesField(want string, got string) bool {
	trimmed := strings.TrimSpace(want)
	if trimmed == "" {
		return true
	}

	return trimmed == strings.TrimSpace(got)
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) == want {
			return true
		}
	}

	return false
}
