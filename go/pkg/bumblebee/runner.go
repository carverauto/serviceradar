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

package bumblebee

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream"
)

const (
	stateScanned     = "scanned"
	stateScanFailed  = "scan_failed"
	coverageComplete = "complete"
	coveragePartial  = "partial"
	coverageFailed   = "failed"
)

var errScannerOutputTooLarge = errors.New("scanner output exceeds configured limit")

type Runner struct {
	cfg Config
}

func NewRunner(cfg Config) *Runner {
	applyDefaults(&cfg)
	return &Runner{cfg: cfg}
}

func (r *Runner) Run(ctx context.Context) (*ScanPayload, error) {
	now := time.Now().UTC()
	runID := newRunID(now)
	catalogSnapshotRef := r.cfg.CatalogSnapshotRef
	if catalogSnapshotRef == "" {
		if assignment, err := LoadCatalogAssignmentMetadata(r.cfg.CatalogPath); err == nil {
			catalogSnapshotRef = assignment.SnapshotRef
		}
	}

	payload := &ScanPayload{
		SchemaVersion:      SchemaVersion,
		AgentID:            r.cfg.AgentID,
		DeviceUID:          r.cfg.DeviceUID,
		RunID:              runID,
		CatalogSnapshotRef: catalogSnapshotRef,
		State:              stateScanFailed,
		CoverageState:      coverageFailed,
		LastScanAt:         now,
		Findings:           []Finding{},
		Metadata: map[string]any{
			"catalog_path": r.cfg.CatalogPath,
			"scan_timeout": r.cfg.ScanTimeout,
		},
	}

	if !r.cfg.Enabled {
		payload.State = "not_scanned"
		payload.CoverageState = "not_scanned"
		payload.Metadata["disabled"] = true
		return payload, nil
	}

	roots, skipped := DiscoverRoots(r.cfg)
	payload.AttemptedRootCount = len(roots)
	payload.AttemptedRoots = sanitizedRootPaths(roots)
	payload.SkippedRoots = append(payload.SkippedRoots, sanitizeSkippedRoots(skipped)...)
	payload.RootCovered = false

	if len(roots) == 0 {
		payload.Metadata["error"] = "no scan roots discovered"
		payload.SkippedRootCount = len(payload.SkippedRoots)
		return payload, nil
	}

	payload.ScannerVersion = upstream.Version
	rootCoverageRequired := rootCoverageRequired(r.cfg)

	for _, root := range roots {
		findings, err := r.scanRoot(ctx, runID, root.Path)
		if err != nil {
			payload.SkippedRoots = append(payload.SkippedRoots, SkippedRoot{
				Path:   sanitizeLocalPath(root.Path),
				Reason: "scan_failed:" + err.Error(),
			})
			continue
		}

		payload.ScannedRootCount++
		payload.ScannedRoots = append(payload.ScannedRoots, sanitizeLocalPath(root.Path))
		if root.Path == "/root" {
			payload.RootCovered = true
		}
		payload.Findings = appendDedupedFindings(payload.Findings, findings)
		if len(payload.Findings) >= r.cfg.MaxFindings {
			payload.Findings = payload.Findings[:r.cfg.MaxFindings]
			payload.Metadata["finding_limit_reached"] = true
			break
		}
	}

	payload.SkippedRootCount = len(payload.SkippedRoots)
	payload.Findings = dedupeFindings(payload.Findings)
	if payload.ScannedRootCount > 0 {
		payload.State = stateScanned
		payload.LastSuccessfulScanAt = &now
		payload.CoverageState = coverageComplete
		if payload.SkippedRootCount > 0 ||
			payload.ScannedRootCount < payload.AttemptedRootCount ||
			(rootCoverageRequired && !payload.RootCovered) {
			payload.CoverageState = coveragePartial
		}
	}

	return payload, nil
}

func rootCoverageRequired(cfg Config) bool {
	if !cfg.IncludeRoot {
		return false
	}

	excluded := excludeSet(cfg.ExcludeRoots)
	_, ok := excluded["/root"]

	return !ok
}

func appendDedupedFindings(existing []Finding, next []Finding) []Finding {
	if len(next) == 0 {
		return existing
	}

	return dedupeFindings(append(existing, next...))
}

func (r *Runner) scanRoot(parent context.Context, runID string, root string) ([]Finding, error) {
	timeout := ScanTimeout(r.cfg)
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	result, err := upstream.ScanRoot(ctx, upstream.ScanOptions{
		Root:        root,
		CatalogPath: r.cfg.CatalogPath,
		RunID:       runID,
		Ecosystems:  r.cfg.Ecosystems,
		MaxDuration: timeout,
		MaxOutput:   r.cfg.MaxOutputBytes,
	})
	if err != nil {
		return nil, err
	}

	if int64(len(result.Records)) > r.cfg.MaxOutputBytes {
		return nil, fmt.Errorf("%w: %d bytes", errScannerOutputTooLarge, r.cfg.MaxOutputBytes)
	}

	return ParseFindings(result.Records, r.cfg.MaxFindings)
}

func ParseFindingsFile(path string, maxBytes int64, maxFindings int) ([]Finding, error) {
	file, err := os.Open(filepath.Clean(path))
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()

	if maxBytes <= 0 {
		maxBytes = defaultMaxOutputBytes
	}

	limited := io.LimitReader(file, maxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("%w: %d bytes", errScannerOutputTooLarge, maxBytes)
	}

	return ParseFindings(data, maxFindings)
}

func ParseFindings(data []byte, maxFindings int) ([]Finding, error) {
	data = bytes.TrimSpace(data)
	if len(data) == 0 {
		return nil, nil
	}
	if maxFindings <= 0 {
		maxFindings = defaultMaxFindings
	}

	var decoded any
	if err := json.Unmarshal(data, &decoded); err == nil {
		return findingsFromAny(decoded, maxFindings), nil
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	var findings []Finding
	for decoder.More() || decoder.InputOffset() < int64(len(data)) {
		var item map[string]any
		if err := decoder.Decode(&item); err != nil {
			return nil, err
		}
		if !isFindingRecord(item) {
			continue
		}
		findings = append(findings, findingFromMap(item))
		if len(findings) >= maxFindings {
			break
		}
	}

	return findings, nil
}

func findingsFromAny(value any, maxFindings int) []Finding {
	switch typed := value.(type) {
	case []any:
		return findingsFromList(typed, maxFindings)
	case map[string]any:
		if findings, ok := typed["findings"].([]any); ok {
			return findingsFromList(findings, maxFindings)
		}
		if results, ok := typed["results"].([]any); ok {
			return findingsFromList(results, maxFindings)
		}
		if !isFindingRecord(typed) {
			return nil
		}
		return []Finding{findingFromMap(typed)}
	default:
		return nil
	}
}

func findingsFromList(list []any, maxFindings int) []Finding {
	findings := make([]Finding, 0, min(len(list), maxFindings))
	for _, item := range list {
		if itemMap, ok := item.(map[string]any); ok {
			if !isFindingRecord(itemMap) {
				continue
			}
			findings = append(findings, findingFromMap(itemMap))
			if len(findings) >= maxFindings {
				break
			}
		}
	}

	return findings
}

func isFindingRecord(item map[string]any) bool {
	recordType := firstString(item, "record_type", "recordType")

	return recordType == "" || recordType == "finding"
}

func findingFromMap(item map[string]any) Finding {
	finding := Finding{
		ID:             firstString(item, "record_id", "recordId", "id"),
		FindingID:      firstString(item, "finding_id", "findingId", "record_id", "recordId", "id"),
		CatalogID:      firstString(item, "catalog_id", "catalogId", "rule_id", "ruleId"),
		Severity:       firstString(item, "severity", "level"),
		RiskScore:      intField(item, "risk_score"),
		Ecosystem:      firstString(item, "ecosystem", "type"),
		PackageName:    firstString(item, "package_name", "packageName", "package", "name"),
		PackageVersion: firstString(item, "package_version", "packageVersion", "version"),
		Confidence:     firstString(item, "confidence"),
		Metadata:       safeFindingMetadata(item),
	}

	evidence := make(map[string]any)
	for _, key := range []string{"path", "file", "source_file", "project_path", "location", "line", "title", "summary", "description", "url"} {
		if value, ok := item[key]; ok {
			evidence[key] = sanitizeEvidenceValue(value)
		}
	}
	if len(evidence) > 0 {
		finding.Evidence = evidence
	}
	if finding.FindingID == "" {
		finding.FindingID = generatedFindingID(finding)
	}

	return finding
}

func generatedFindingID(finding Finding) string {
	sum := sha256.Sum256([]byte(strings.Join([]string{
		finding.CatalogID,
		finding.Ecosystem,
		finding.PackageName,
		finding.PackageVersion,
		fmt.Sprint(finding.Evidence),
	}, "|")))

	return hex.EncodeToString(sum[:])
}

func dedupeFindings(findings []Finding) []Finding {
	seen := make(map[string]struct{}, len(findings))
	out := make([]Finding, 0, len(findings))

	for _, finding := range findings {
		key := finding.FindingID
		if key == "" {
			key = generatedFindingID(finding)
			finding.FindingID = key
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, finding)
	}

	return out
}

func stringField(item map[string]any, key string) string {
	value, ok := item[key]
	if !ok {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case int:
		return strconv.Itoa(typed)
	default:
		return ""
	}
}

func firstString(item map[string]any, keys ...string) string {
	for _, key := range keys {
		if value := stringField(item, key); value != "" {
			return value
		}
	}

	return ""
}

func intField(item map[string]any, key string) int {
	value, ok := item[key]
	if !ok {
		return 0
	}

	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case string:
		parsed, _ := strconv.Atoi(strings.TrimSpace(typed))
		return parsed
	default:
		return 0
	}
}

func safeFindingMetadata(item map[string]any) map[string]any {
	keys := []string{
		"record_type",
		"record_id",
		"catalog_id",
		"rule_id",
		"title",
		"summary",
		"description",
		"url",
		"source",
		"scanner",
		"confidence",
	}

	out := make(map[string]any, len(keys))
	for _, key := range keys {
		value, ok := item[key]
		if !ok {
			continue
		}
		if safeValue, ok := safeMetadataValue(value); ok {
			out[key] = safeValue
		}
	}
	if len(out) == 0 {
		return nil
	}

	return out
}

func safeMetadataValue(value any) (any, bool) {
	switch typed := value.(type) {
	case string:
		return sanitizeLocalPath(typed), true
	case float64, int, bool:
		return typed, true
	default:
		return nil, false
	}
}

func sanitizeEvidenceValue(value any) any {
	switch typed := value.(type) {
	case string:
		return sanitizeLocalPath(typed)
	case []any:
		out := make([]any, 0, len(typed))
		for _, item := range typed {
			out = append(out, sanitizeEvidenceValue(item))
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, item := range typed {
			out[key] = sanitizeEvidenceValue(item)
		}
		return out
	default:
		return value
	}
}

func sanitizedRootPaths(roots []RootCandidate) []string {
	paths := make([]string, 0, len(roots))
	for _, root := range roots {
		paths = append(paths, sanitizeLocalPath(root.Path))
	}

	return paths
}

func sanitizeSkippedRoots(skipped []SkippedRoot) []SkippedRoot {
	out := make([]SkippedRoot, 0, len(skipped))
	for _, skippedRoot := range skipped {
		reason := skippedRoot.Reason
		if strings.HasPrefix(reason, "home_unavailable:") {
			reason = "home_unavailable"
		}
		out = append(out, SkippedRoot{
			Path:   sanitizeLocalPath(skippedRoot.Path),
			Reason: reason,
		})
	}

	return out
}

func sanitizeLocalPath(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	clean := filepath.Clean(value)
	if !filepath.IsAbs(clean) {
		return value
	}

	if clean == "/root" {
		return "~root"
	}
	if strings.HasPrefix(clean, "/root/") {
		return "~root/" + strings.TrimPrefix(clean, "/root/")
	}

	for _, prefix := range []string{"/home/", "/Users/"} {
		if strings.HasPrefix(clean, prefix) {
			rest := strings.TrimPrefix(clean, prefix)
			parts := strings.SplitN(rest, string(os.PathSeparator), 2)
			if len(parts) == 1 {
				return "~"
			}
			return "~/" + parts[1]
		}
	}

	return clean
}

func newRunID(now time.Time) string {
	var randomBytes [6]byte
	_, _ = rand.Read(randomBytes[:])

	return fmt.Sprintf("bumblebee-%d-%s", now.UnixNano(), hex.EncodeToString(randomBytes[:]))
}
