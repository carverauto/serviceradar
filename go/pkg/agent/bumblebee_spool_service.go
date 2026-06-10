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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	sraddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

const maxBumblebeeSpoolBytes = 16 * 1024 * 1024

var errBumblebeeSpoolTooLarge = errors.New("bumblebee spool payload exceeds size budget")

type BumblebeeSpoolService struct {
	agentID          string
	spoolPath        string
	telemetryMu      sync.Mutex
	lastTelemetryKey string
}

func NewBumblebeeSpoolService(agentID string, cfg *BumblebeeStatusConfig) *BumblebeeSpoolService {
	return &BumblebeeSpoolService{
		agentID:   agentID,
		spoolPath: cfg.effectiveSpoolPath(),
	}
}

func (s *BumblebeeSpoolService) Start(context.Context) error { return nil }
func (s *BumblebeeSpoolService) Stop(context.Context) error  { return nil }
func (s *BumblebeeSpoolService) Name() string                { return bumblebee.ServiceName }
func (s *BumblebeeSpoolService) StatusServiceType() string   { return bumblebee.ServiceType }
func (s *BumblebeeSpoolService) StatusSource() string        { return bumblebee.SourceResults }
func (s *BumblebeeSpoolService) UpdateConfig(*models.Config) error {
	return nil
}

func (s *BumblebeeSpoolService) GetStatus(context.Context) (*proto.StatusResponse, error) {
	data, err := os.ReadFile(s.spoolPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s.notScannedStatus(), nil
		}
		return nil, err
	}
	if len(data) > maxBumblebeeSpoolBytes {
		return nil, errBumblebeeSpoolTooLarge
	}

	data = ensureBumblebeeAgentID(data, s.agentID)

	return &proto.StatusResponse{
		Available:   true,
		Message:     data,
		ServiceName: bumblebee.ServiceName,
		ServiceType: bumblebee.ServiceType,
	}, nil
}

func (s *BumblebeeSpoolService) AddonTelemetryBatch(status *proto.StatusResponse) (string, *addonpb.TelemetryBatch) {
	if status == nil || !status.Available || len(status.Message) == 0 {
		return "", nil
	}

	var payload bumblebee.ScanPayload
	if err := json.Unmarshal(status.Message, &payload); err != nil {
		return "", nil
	}
	if payload.State == "not_scanned" || payload.RunID == "" {
		return "", nil
	}

	key := strings.Join([]string{
		payload.RunID,
		payload.State,
		payload.CoverageState,
		fmt.Sprint(len(payload.Findings)),
	}, "|")

	s.telemetryMu.Lock()
	if key == s.lastTelemetryKey {
		s.telemetryMu.Unlock()
		return "", nil
	}
	s.lastTelemetryKey = key
	s.telemetryMu.Unlock()

	record := s.bumblebeeScanTelemetryRecord(payload)
	if record == nil {
		return "", nil
	}

	return "bumblebee", &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{
			SourceType:     "bumblebee",
			SourceInstance: bumblebeeFirstNonEmpty(payload.AgentID, s.agentID, "agent"),
		},
		Records: []*addonpb.TelemetryRecord{record},
		Counters: &addonpb.TelemetryCounters{
			Received: 1,
			Emitted:  1,
		},
	}
}

func (s *BumblebeeSpoolService) bumblebeeScanTelemetryRecord(payload bumblebee.ScanPayload) *addonpb.TelemetryRecord {
	eventTime := payload.LastScanAt
	if eventTime.IsZero() {
		eventTime = time.Now().UTC()
	}
	eventTimeNano := eventTime.UnixNano()
	observedTimeNano := time.Now().UTC().UnixNano()

	event := map[string]any{
		"class_uid":     4001,
		"category_uid":  1,
		"type_uid":      400103,
		"activity_id":   3,
		"activity_name": "Update",
		"severity_id":   bumblebeeSeverityID(payload),
		"severity":      bumblebeeSeverityName(bumblebeeSeverityID(payload)),
		"status_id":     bumblebeeStatusID(payload),
		"status":        bumblebeeStatusName(bumblebeeStatusID(payload)),
		"status_code":   "bumblebee_scan_" + normalizedToken(payload.State, "unknown"),
		"message":       bumblebeeScanMessage(payload, s.agentID),
		"log_name":      "bumblebee.scan",
		"log_provider":  bumblebeeFirstNonEmpty(payload.AgentID, s.agentID, "agent"),
		"metadata": map[string]any{
			"product": map[string]any{
				"name":        "ServiceRadar Bumblebee Add-on",
				"vendor_name": "Carver Automation",
			},
			"version": "1.8.0",
		},
		"actor": map[string]any{},
		"device": map[string]any{
			"name": bumblebeeFirstNonEmpty(payload.AgentID, s.agentID, "agent"),
		},
		"unmapped": bumblebeeEventUnmapped(payload),
	}

	data, err := json.Marshal(event)
	if err != nil {
		return nil
	}

	return sraddon.AttachSignalSchemaRef(&addonpb.TelemetryRecord{
		EventId:              "bumblebee-scan-" + payload.RunID,
		ObservedTimeUnixNano: observedTimeNano,
		EventTimeUnixNano:    eventTimeNano,
		PayloadKind:          addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:              data,
	}, sraddon.SignalSchemaRef{
		ProducerID:             "bumblebee",
		ProducerVersion:        bumblebeeFirstNonEmpty(payload.ScannerVersion, "0.1.1"),
		SchemaID:               "com.carverauto.bumblebee.scan",
		SchemaVersion:          "1.0.0",
		DisplayContractID:      "com.carverauto.bumblebee.scan.display",
		DisplayContractVersion: "1.0.0",
		SignalType:             "event",
		PayloadKind:            "ocsf_event",
	})
}

func (s *BumblebeeSpoolService) notScannedStatus() *proto.StatusResponse {
	payload := map[string]any{
		"schema_version": bumblebee.SchemaVersion,
		"agent_id":       s.agentID,
		"run_id":         "bumblebee-not-scanned",
		"state":          "not_scanned",
		"coverage_state": "not_scanned",
		"findings":       []bumblebee.Finding{},
		"metadata": map[string]any{
			"spool_path": s.spoolPath,
			"reason":     "spool_not_found",
		},
	}

	data, _ := json.Marshal(payload)

	return &proto.StatusResponse{
		Available:   false,
		Message:     data,
		ServiceName: bumblebee.ServiceName,
		ServiceType: bumblebee.ServiceType,
	}
}

func ensureBumblebeeAgentID(data []byte, agentID string) []byte {
	if agentID == "" {
		return data
	}

	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}

	payload["agent_id"] = agentID
	updated, err := json.Marshal(payload)
	if err != nil {
		return data
	}

	return updated
}

func bumblebeeScanMessage(payload bumblebee.ScanPayload, fallbackAgentID string) string {
	agentID := bumblebeeFirstNonEmpty(payload.AgentID, fallbackAgentID, "agent")
	count := len(payload.Findings)
	if payload.State == "scan_failed" || payload.CoverageState == "failed" {
		return fmt.Sprintf("Bumblebee scan failed on %s", agentID)
	}
	if count == 1 {
		return fmt.Sprintf("Bumblebee scan completed on %s: 1 active exposure finding", agentID)
	}

	return fmt.Sprintf("Bumblebee scan completed on %s: %d active exposure findings", agentID, count)
}

func bumblebeeEventUnmapped(payload bumblebee.ScanPayload) map[string]any {
	return map[string]any{
		"agent_id":              payload.AgentID,
		"run_id":                payload.RunID,
		"catalog_snapshot_ref":  payload.CatalogSnapshotRef,
		"scanner_version":       payload.ScannerVersion,
		"state":                 payload.State,
		"coverage_state":        payload.CoverageState,
		"active_finding_count":  len(payload.Findings),
		"attempted_root_count":  payload.AttemptedRootCount,
		"scanned_root_count":    payload.ScannedRootCount,
		"skipped_root_count":    payload.SkippedRootCount,
		"root_covered":          payload.RootCovered,
		"highest_severity":      highestBumblebeeSeverity(payload.Findings),
		"finding_limit_reached": payload.Metadata["finding_limit_reached"],
	}
}

func bumblebeeStatusID(payload bumblebee.ScanPayload) int {
	if payload.State == "scan_failed" || payload.CoverageState == "failed" {
		return 2
	}

	return 1
}

func bumblebeeStatusName(statusID int) string {
	if statusID == 2 {
		return "Failure"
	}

	return "Success"
}

func bumblebeeSeverityID(payload bumblebee.ScanPayload) int {
	if payload.State == "scan_failed" || payload.CoverageState == "failed" {
		return 3
	}

	switch highestBumblebeeSeverity(payload.Findings) {
	case "critical":
		return 5
	case "high":
		return 4
	case "medium":
		return 3
	case "low":
		return 2
	default:
		if payload.CoverageState == "partial" {
			return 2
		}
		return 1
	}
}

func bumblebeeSeverityName(severityID int) string {
	switch severityID {
	case 5:
		return "Critical"
	case 4:
		return "High"
	case 3:
		return "Medium"
	case 2:
		return "Low"
	default:
		return "Informational"
	}
}

func highestBumblebeeSeverity(findings []bumblebee.Finding) string {
	rank := map[string]int{
		"critical":      5,
		"high":          4,
		"medium":        3,
		"low":           2,
		"info":          1,
		"informational": 1,
	}
	best := ""
	bestRank := 0
	for _, finding := range findings {
		severity := normalizedToken(finding.Severity, "")
		if rank[severity] > bestRank {
			best = severity
			bestRank = rank[severity]
		}
	}

	return best
}

func normalizedToken(value, fallback string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.ReplaceAll(value, " ", "_")
	if value == "" {
		return fallback
	}

	return value
}

func bumblebeeFirstNonEmpty(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}

	return ""
}
