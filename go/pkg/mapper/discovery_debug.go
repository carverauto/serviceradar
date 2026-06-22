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

package mapper

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type discoveryDebugBundlePayload struct {
	DiscoveryID   string                 `json:"discovery_id"`
	GeneratedAt   string                 `json:"generated_at"`
	Status        *DiscoveryStatus       `json:"status"`
	Contract      DiscoveryContract      `json:"contract"`
	Devices       []*DiscoveredDevice    `json:"devices"`
	Interfaces    []*DiscoveredInterface `json:"interfaces"`
	TopologyLinks []*TopologyLink        `json:"topology_links"`
}

func (e *DiscoveryEngine) maybeExportDebugBundle(job *DiscoveryJob) {
	if job == nil || job.Params == nil {
		return
	}
	if !isTruthyOption(job.Params.Options[mapperDebugBundleOption]) {
		return
	}

	exportDir := strings.TrimSpace(job.Params.Options[mapperDebugBundlePathOption])
	if exportDir == "" {
		exportDir = defaultMapperDebugBundleDir
	}
	filename := fmt.Sprintf("%s-debug-bundle.json", job.ID)
	exportPath := filepath.Join(exportDir, filename)
	now := time.Now().UTC()

	var payload discoveryDebugBundlePayload
	job.mu.Lock()
	payload = discoveryDebugBundlePayload{
		DiscoveryID:   job.ID,
		GeneratedAt:   now.Format(time.RFC3339Nano),
		Status:        job.Status,
		Contract:      job.Results.Contract,
		Devices:       append([]*DiscoveredDevice(nil), job.Results.Devices...),
		Interfaces:    append([]*DiscoveredInterface(nil), job.Results.Interfaces...),
		TopologyLinks: append([]*TopologyLink(nil), job.Results.TopologyLinks...),
	}
	job.Results.Contract.DebugBundle.Enabled = true
	job.Results.Contract.DebugBundle.ExportPath = exportPath
	job.Results.Contract.DebugBundle.ExportedAtUnix = now.Unix()
	job.Results.Contract.DebugBundle.DeviceCount = len(job.Results.Devices)
	job.Results.Contract.DebugBundle.InterfaceCount = len(job.Results.Interfaces)
	job.Results.Contract.DebugBundle.TopologyCount = len(job.Results.TopologyLinks)
	job.Results.Contract.DebugBundle.Error = ""
	job.mu.Unlock()

	if err := os.MkdirAll(exportDir, 0o750); err != nil {
		e.recordDebugBundleError(job, err)
		e.logger.Warn().Str("job_id", job.ID).Str("path", exportPath).
			Err(err).Msg("Failed to create mapper debug bundle directory")
		return
	}

	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		e.recordDebugBundleError(job, err)
		e.logger.Warn().Str("job_id", job.ID).Str("path", exportPath).
			Err(err).Msg("Failed to marshal mapper debug bundle")
		return
	}
	if err := os.WriteFile(exportPath, raw, 0o640); err != nil {
		e.recordDebugBundleError(job, err)
		e.logger.Warn().Str("job_id", job.ID).Str("path", exportPath).
			Err(err).Msg("Failed to write mapper debug bundle")
		return
	}

	e.logger.Info().Str("job_id", job.ID).Str("path", exportPath).
		Int("devices", len(payload.Devices)).
		Int("interfaces", len(payload.Interfaces)).
		Int("topology_links", len(payload.TopologyLinks)).
		Msg("Mapper debug bundle exported")
}

func isTruthyOption(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", stringTrueValue, stringYesValue, "y", "on":
		return true
	default:
		return false
	}
}

func (e *DiscoveryEngine) recordDebugBundleError(job *DiscoveryJob, err error) {
	if job == nil || err == nil {
		return
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	job.Results.Contract.DebugBundle.Enabled = true
	job.Results.Contract.DebugBundle.Error = err.Error()
}

func (e *DiscoveryEngine) recordContractParseFailure(job *DiscoveryJob, parserType, detail string) {
	if job == nil {
		return
	}
	key := strings.TrimSpace(parserType)
	if key == "" {
		key = fallbackUnknown
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	diag := &job.Results.Contract.ParseDiagnostics
	if diag.ParseFailures == nil {
		diag.ParseFailures = make(map[string]int)
	}
	if diag.LastFailureByType == nil {
		diag.LastFailureByType = make(map[string]string)
	}
	diag.ParseFailures[key]++
	if detail != "" {
		diag.LastFailureByType[key] = detail
	}
}

func (e *DiscoveryEngine) recordContractParserMismatch(job *DiscoveryJob, parserType string) {
	if job == nil {
		return
	}
	key := strings.TrimSpace(parserType)
	if key == "" {
		key = fallbackUnknown
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	diag := &job.Results.Contract.ParseDiagnostics
	if diag.ParserMismatches == nil {
		diag.ParserMismatches = make(map[string]int)
	}
	diag.ParserMismatches[key]++
}

func (e *DiscoveryEngine) recordContractUnknownTopLevel(job *DiscoveryJob, source string, keys []string) {
	if job == nil || len(keys) == 0 {
		return
	}
	scope := strings.TrimSpace(source)
	if scope == "" {
		scope = fallbackUnknown
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	diag := &job.Results.Contract.ParseDiagnostics
	if diag.UnknownTopLevel == nil {
		diag.UnknownTopLevel = make(map[string]int)
	}
	for _, key := range keys {
		trimmed := strings.TrimSpace(key)
		if trimmed == "" {
			continue
		}
		diag.UnknownTopLevel[scope+"."+trimmed]++
	}
}
