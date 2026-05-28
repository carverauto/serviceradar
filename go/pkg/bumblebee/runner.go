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
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	stateScanned     = "scanned"
	stateScanFailed  = "scan_failed"
	coverageComplete = "complete"
	coveragePartial  = "partial"
	coverageFailed   = "failed"
)

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
	payload.AttemptedRoots = rootPaths(roots)
	payload.SkippedRoots = append(payload.SkippedRoots, skipped...)
	payload.RootCovered = false

	if len(roots) == 0 {
		payload.Metadata["error"] = "no scan roots discovered"
		payload.SkippedRootCount = len(payload.SkippedRoots)
		return payload, nil
	}

	version := r.scannerVersion(ctx)
	if version != "" {
		payload.ScannerVersion = version
	}

	for _, root := range roots {
		findings, err := r.scanRoot(ctx, root.Path)
		if err != nil {
			payload.SkippedRoots = append(payload.SkippedRoots, SkippedRoot{Path: root.Path, Reason: "scan_failed:" + err.Error()})
			continue
		}

		payload.ScannedRootCount++
		payload.ScannedRoots = append(payload.ScannedRoots, root.Path)
		if root.Path == "/root" {
			payload.RootCovered = true
		}
		payload.Findings = append(payload.Findings, findings...)
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
		if payload.SkippedRootCount > 0 || payload.ScannedRootCount < payload.AttemptedRootCount || !payload.RootCovered {
			payload.CoverageState = coveragePartial
		}
	}

	return payload, nil
}

func (r *Runner) scanRoot(parent context.Context, root string) ([]Finding, error) {
	timeout := ScanTimeout(r.cfg)
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	outFile, err := os.CreateTemp(r.cfg.TmpDir, ".bumblebee-output-*.json")
	if err != nil {
		return nil, fmt.Errorf("create scanner output file: %w", err)
	}
	outPath := outFile.Name()
	defer os.Remove(outPath)
	defer outFile.Close()

	var stderr limitedBuffer
	stderr.limit = 64 * 1024

	args := r.commandForRoot(root, outPath)
	if len(args) == 0 {
		return nil, errors.New("empty command template")
	}

	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Stdout = outFile
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("%w: %s", err, stderr.String())
	}

	if err := outFile.Close(); err != nil {
		return nil, fmt.Errorf("close scanner output file: %w", err)
	}

	return ParseFindingsFile(outPath, r.cfg.MaxOutputBytes, r.cfg.MaxFindings)
}

func (r *Runner) commandForRoot(root string, outputPath string) []string {
	template := r.cfg.CommandTemplate
	if len(template) == 0 {
		template = []string{
			r.cfg.BumblebeeBin,
			"scan",
			"--profile",
			"deep",
			"--findings-only",
			"--exposure-catalog",
			"{catalog_path}",
			"--max-duration",
			"{scan_timeout}",
			"--root",
			"{root_path}",
		}
	}

	values := map[string]string{
		"{bumblebee_bin}": r.cfg.BumblebeeBin,
		"{catalog_path}":  r.cfg.CatalogPath,
		"{root_path}":     root,
		"{output_path}":   outputPath,
		"{ecosystems}":    strings.Join(r.cfg.Ecosystems, ","),
		"{scan_timeout}":  r.cfg.ScanTimeout,
	}

	args := make([]string, 0, len(template))
	for _, part := range template {
		for key, value := range values {
			part = strings.ReplaceAll(part, key, value)
		}
		args = append(args, part)
	}

	return args
}

func (r *Runner) scannerVersion(ctx context.Context) string {
	if strings.TrimSpace(r.cfg.BumblebeeBin) == "" {
		return ""
	}

	versionCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(versionCtx, r.cfg.BumblebeeBin, "--version")
	var out limitedBuffer
	out.limit = 4096
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Run(); err != nil {
		return ""
	}

	return strings.TrimSpace(out.String())
}

func ParseFindingsFile(path string, maxBytes int64, maxFindings int) ([]Finding, error) {
	file, err := os.Open(filepath.Clean(path))
	if err != nil {
		return nil, err
	}
	defer file.Close()

	if maxBytes <= 0 {
		maxBytes = defaultMaxOutputBytes
	}

	limited := io.LimitReader(file, maxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("scanner output exceeds %d bytes", maxBytes)
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
		return []Finding{findingFromMap(typed)}
	default:
		return nil
	}
}

func findingsFromList(list []any, maxFindings int) []Finding {
	findings := make([]Finding, 0, min(len(list), maxFindings))
	for _, item := range list {
		if itemMap, ok := item.(map[string]any); ok {
			findings = append(findings, findingFromMap(itemMap))
			if len(findings) >= maxFindings {
				break
			}
		}
	}

	return findings
}

func findingFromMap(item map[string]any) Finding {
	finding := Finding{
		ID:             stringField(item, "id"),
		FindingID:      firstString(item, "finding_id", "findingId", "id"),
		CatalogID:      firstString(item, "catalog_id", "catalogId", "rule_id", "ruleId"),
		Severity:       firstString(item, "severity", "level"),
		RiskScore:      intField(item, "risk_score"),
		Ecosystem:      firstString(item, "ecosystem", "type"),
		PackageName:    firstString(item, "package_name", "packageName", "package", "name"),
		PackageVersion: firstString(item, "package_version", "packageVersion", "version"),
		Confidence:     firstString(item, "confidence"),
		Metadata:       cloneMap(item),
	}

	evidence := make(map[string]any)
	for _, key := range []string{"path", "file", "location", "line", "title", "summary", "description", "url"} {
		if value, ok := item[key]; ok {
			evidence[key] = value
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

func cloneMap(item map[string]any) map[string]any {
	out := make(map[string]any, len(item))
	for key, value := range item {
		out[key] = value
	}

	return out
}

func rootPaths(roots []RootCandidate) []string {
	paths := make([]string, 0, len(roots))
	for _, root := range roots {
		paths = append(paths, root.Path)
	}

	return paths
}

func newRunID(now time.Time) string {
	var randomBytes [6]byte
	_, _ = rand.Read(randomBytes[:])

	return fmt.Sprintf("bumblebee-%d-%s", now.UnixNano(), hex.EncodeToString(randomBytes[:]))
}

type limitedBuffer struct {
	buf   bytes.Buffer
	limit int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.limit <= 0 {
		return len(p), nil
	}

	remaining := b.limit - b.buf.Len()
	if remaining > 0 {
		_, _ = b.buf.Write(p[:min(len(p), remaining)])
	}

	return len(p), nil
}

func (b *limitedBuffer) String() string {
	return strings.TrimSpace(b.buf.String())
}
