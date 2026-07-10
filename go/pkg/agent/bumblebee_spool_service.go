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
	"github.com/google/uuid"
)

const maxBumblebeeSpoolBytes = 16 * 1024 * 1024

const (
	ocsfSchemaVersionDev                    = "1.9.0-dev"
	ocsfCategoryFindings                    = 2
	ocsfCategoryApplicationActivity         = 6
	ocsfClassApplicationSecurityPosture     = 2007
	ocsfClassScanActivity                   = 6007
	ocsfActivityFindingCreate               = 1
	ocsfActivityScanCompleted               = 2
	ocsfActivityScanError                   = 6
	ocsfStatusSuccess                       = 1
	ocsfStatusFailure                       = 2
	bumblebeeFindingDisplayContractID       = "com.carverauto.bumblebee.finding.display"
	bumblebeeScanActivityDisplayContractID  = "com.carverauto.bumblebee.scan_activity.display"
	bumblebeeFindingDisplayContractVersion  = "1.0.0"
	bumblebeeScanActivityDisplayContractVer = "1.0.0"
	bumblebeeTelemetryProducerID            = "bumblebee"
	bumblebeeStateFailed                    = "scan_failed"
	bumblebeeStateNotScanned                = "not_scanned"
	bumblebeeCoverageFailed                 = "failed"
	bumblebeeCoveragePartial                = "partial"
	bumblebeeSeverityCritical               = "critical"
	bumblebeeSeverityHigh                   = "high"
	bumblebeeSeverityMedium                 = "medium"
	bumblebeeSeverityLow                    = "low"
	bumblebeeSeverityInfo                   = "info"
	bumblebeeSeverityInformational          = "informational"
)

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
	if payload.State == bumblebeeStateNotScanned || payload.RunID == "" {
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

	records := s.bumblebeeTelemetryRecords(payload)
	if len(records) == 0 {
		return "", nil
	}

	return bumblebeeTelemetryProducerID, &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{
			SourceType:     bumblebeeTelemetryProducerID,
			SourceInstance: bumblebeeFirstNonEmpty(payload.AgentID, s.agentID, "agent"),
		},
		Records: records,
		Counters: &addonpb.TelemetryCounters{
			Received: uint64(len(records)),
			Emitted:  uint64(len(records)),
		},
	}
}

func (s *BumblebeeSpoolService) bumblebeeTelemetryRecords(payload bumblebee.ScanPayload) []*addonpb.TelemetryRecord {
	records := make([]*addonpb.TelemetryRecord, 0, 1+len(payload.Findings))
	if record := s.bumblebeeScanTelemetryRecord(payload); record != nil {
		records = append(records, record)
	}
	for _, finding := range payload.Findings {
		if record := s.bumblebeeFindingTelemetryRecord(payload, finding); record != nil {
			records = append(records, record)
		}
	}
	return records
}

func (s *BumblebeeSpoolService) bumblebeeScanTelemetryRecord(payload bumblebee.ScanPayload) *addonpb.TelemetryRecord {
	eventTime := payload.LastScanAt
	if eventTime.IsZero() {
		eventTime = time.Now().UTC()
	}
	eventTimeNano := eventTime.UnixNano()
	observedTimeNano := time.Now().UTC().UnixNano()
	eventID := bumblebeeDeterministicUUID("scan:" + payload.RunID)
	activityID := bumblebeeScanActivityID(payload)

	event := map[string]any{
		"id":            eventID,
		"time":          eventTimeNano,
		"class_uid":     ocsfClassScanActivity,
		"category_uid":  ocsfCategoryApplicationActivity,
		"type_uid":      ocsfTypeUID(ocsfClassScanActivity, activityID),
		"activity_id":   activityID,
		"activity_name": bumblebeeScanActivityName(activityID),
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
			"service_radar": bumblebeeServiceRadarMetadata(payload, "scan_activity"),
			"version":       ocsfSchemaVersionDev,
		},
		"actor":             map[string]any{},
		"device":            bumblebeeDeviceObject(payload, s.agentID),
		"scan":              bumblebeeScanObject(payload),
		"end_time":          eventTimeNano,
		"total":             payload.AttemptedRootCount,
		"num_detections":    len(payload.Findings),
		"num_skipped_items": payload.SkippedRootCount,
		"unmapped":          bumblebeeEventUnmapped(payload),
	}

	data, err := json.Marshal(event)
	if err != nil {
		return nil
	}

	return sraddon.AttachSignalSchemaRef(&addonpb.TelemetryRecord{
		EventId:              eventID,
		ObservedTimeUnixNano: observedTimeNano,
		EventTimeUnixNano:    eventTimeNano,
		PayloadKind:          addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:              data,
	}, sraddon.SignalSchemaRef{
		ProducerID:             bumblebeeTelemetryProducerID,
		ProducerVersion:        bumblebeeFirstNonEmpty(payload.ScannerVersion, "0.1.1"),
		SchemaID:               "ocsf.scan_activity",
		SchemaVersion:          "1.0.0",
		DisplayContractID:      bumblebeeScanActivityDisplayContractID,
		DisplayContractVersion: bumblebeeScanActivityDisplayContractVer,
		SignalType:             "event",
		PayloadKind:            "ocsf_event",
	})
}

func (s *BumblebeeSpoolService) bumblebeeFindingTelemetryRecord(payload bumblebee.ScanPayload, finding bumblebee.Finding) *addonpb.TelemetryRecord {
	eventTime := payload.LastScanAt
	if eventTime.IsZero() {
		eventTime = time.Now().UTC()
	}
	eventTimeNano := eventTime.UnixNano()
	observedTimeNano := time.Now().UTC().UnixNano()
	findingID := bumblebeeFirstNonEmpty(finding.FindingID, finding.ID, finding.CatalogID, finding.PackageName)
	if strings.TrimSpace(findingID) == "" {
		return nil
	}
	eventID := bumblebeeDeterministicUUID(strings.Join([]string{"finding", payload.RunID, findingID}, ":"))
	severityID := bumblebeeFindingSeverityID(finding)

	event := map[string]any{
		"id":            eventID,
		"time":          eventTimeNano,
		"class_uid":     ocsfClassApplicationSecurityPosture,
		"category_uid":  ocsfCategoryFindings,
		"type_uid":      ocsfTypeUID(ocsfClassApplicationSecurityPosture, ocsfActivityFindingCreate),
		"activity_id":   ocsfActivityFindingCreate,
		"activity_name": "Create",
		"severity_id":   severityID,
		"severity":      bumblebeeSeverityName(severityID),
		"status_id":     ocsfStatusSuccess,
		"status":        "Active",
		"status_code":   "bumblebee_finding_active",
		"message":       bumblebeeFindingMessage(payload, finding),
		"log_name":      "bumblebee.finding",
		"log_provider":  bumblebeeFirstNonEmpty(payload.AgentID, s.agentID, "agent"),
		"metadata": map[string]any{
			"product": map[string]any{
				"name":        "ServiceRadar Bumblebee Add-on",
				"vendor_name": "Carver Automation",
			},
			"service_radar": bumblebeeServiceRadarMetadata(payload, "application_security_posture_finding"),
			"version":       ocsfSchemaVersionDev,
		},
		"device":       bumblebeeDeviceObject(payload, s.agentID),
		"finding_info": bumblebeeFindingInfo(finding, findingID),
		"resources":    []any{bumblebeeFindingResource(finding)},
		"evidences":    []any{bumblebeeFindingEvidence(finding)},
		"observables":  bumblebeeFindingObservables(finding),
		"unmapped":     bumblebeeFindingUnmapped(payload, finding),
	}

	data, err := json.Marshal(event)
	if err != nil {
		return nil
	}

	return sraddon.AttachSignalSchemaRef(&addonpb.TelemetryRecord{
		EventId:              eventID,
		ObservedTimeUnixNano: observedTimeNano,
		EventTimeUnixNano:    eventTimeNano,
		PayloadKind:          addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:              data,
	}, sraddon.SignalSchemaRef{
		ProducerID:             bumblebeeTelemetryProducerID,
		ProducerVersion:        bumblebeeFirstNonEmpty(payload.ScannerVersion, "0.1.1"),
		SchemaID:               "ocsf.application_security_posture_finding",
		SchemaVersion:          "1.0.0",
		DisplayContractID:      bumblebeeFindingDisplayContractID,
		DisplayContractVersion: bumblebeeFindingDisplayContractVersion,
		SignalType:             "event",
		PayloadKind:            "ocsf_event",
	})
}

func (s *BumblebeeSpoolService) notScannedStatus() *proto.StatusResponse {
	payload := map[string]any{
		"schema_version": bumblebee.SchemaVersion,
		"agent_id":       s.agentID,
		"run_id":         "bumblebee-not-scanned",
		"state":          bumblebeeStateNotScanned,
		"coverage_state": bumblebeeStateNotScanned,
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

func ocsfTypeUID(classUID, activityID int) int {
	return classUID*100 + activityID
}

func bumblebeeDeterministicUUID(seed string) string {
	return uuid.NewSHA1(uuid.NameSpaceOID, []byte("serviceradar:bumblebee:"+seed)).String()
}

func bumblebeeScanActivityID(payload bumblebee.ScanPayload) int {
	if payload.State == bumblebeeStateFailed || payload.CoverageState == bumblebeeCoverageFailed {
		return ocsfActivityScanError
	}

	return ocsfActivityScanCompleted
}

func bumblebeeScanActivityName(activityID int) string {
	switch activityID {
	case ocsfActivityScanCompleted:
		return "Completed"
	case ocsfActivityScanError:
		return "Error"
	default:
		return "Unknown"
	}
}

func bumblebeeScanObject(payload bumblebee.ScanPayload) map[string]any {
	var endTime any
	if !payload.LastScanAt.IsZero() {
		endTime = payload.LastScanAt.UnixNano()
	}

	return map[string]any{
		"uid":        payload.RunID,
		"name":       "Bumblebee exposure scan",
		"type":       "software exposure",
		"total":      payload.AttemptedRootCount,
		"start_time": nil,
		"end_time":   endTime,
	}
}

func bumblebeeScanMessage(payload bumblebee.ScanPayload, fallbackAgentID string) string {
	agentID := bumblebeeFirstNonEmpty(payload.AgentID, fallbackAgentID, "agent")
	count := len(payload.Findings)
	if payload.State == bumblebeeStateFailed || payload.CoverageState == bumblebeeCoverageFailed {
		return fmt.Sprintf("Bumblebee scan failed on %s", agentID)
	}
	if count == 1 {
		return fmt.Sprintf("Bumblebee scan completed on %s: 1 active exposure finding", agentID)
	}

	return fmt.Sprintf("Bumblebee scan completed on %s: %d active exposure findings", agentID, count)
}

func bumblebeeFindingMessage(payload bumblebee.ScanPayload, finding bumblebee.Finding) string {
	agentID := bumblebeeFirstNonEmpty(payload.AgentID, "agent")
	packageID := bumblebeeFirstNonEmpty(finding.PackageName, finding.CatalogID, finding.FindingID, finding.ID, "package")
	if finding.PackageVersion != "" {
		packageID += "@" + finding.PackageVersion
	}

	return fmt.Sprintf("Bumblebee exposure finding on %s: %s", agentID, packageID)
}

func bumblebeeFindingInfo(finding bumblebee.Finding, findingID string) map[string]any {
	return map[string]any{
		"uid":        findingID,
		"title":      bumblebeeFirstNonEmpty(finding.CatalogID, finding.PackageName, findingID),
		"desc":       bumblebeeFirstNonEmpty(finding.Ecosystem, "Bumblebee application security posture finding"),
		"created_at": nil,
	}
}

func bumblebeeFindingResource(finding bumblebee.Finding) map[string]any {
	return map[string]any{
		"name":    finding.PackageName,
		"type":    "package",
		"version": finding.PackageVersion,
		"details": map[string]any{
			"ecosystem":  finding.Ecosystem,
			"catalog_id": finding.CatalogID,
		},
	}
}

func bumblebeeFindingEvidence(finding bumblebee.Finding) map[string]any {
	return map[string]any{
		"desc":       "Bumblebee local package/root scan evidence",
		"confidence": finding.Confidence,
		"data":       finding.Evidence,
	}
}

func bumblebeeFindingObservables(finding bumblebee.Finding) []any {
	observables := make([]any, 0, 2)
	if finding.PackageName != "" {
		observables = append(observables, map[string]any{
			"name":  "Package",
			"type":  "Software Package",
			"value": finding.PackageName,
		})
	}
	if finding.CatalogID != "" {
		observables = append(observables, map[string]any{
			"name":  "Catalog Rule",
			"type":  "Finding Rule",
			"value": finding.CatalogID,
		})
	}

	return observables
}

func bumblebeeServiceRadarMetadata(payload bumblebee.ScanPayload, ocsfClass string) map[string]any {
	metadata := map[string]any{
		"addon_id":    bumblebeeTelemetryProducerID,
		"agent_id":    bumblebeeFirstNonEmpty(payload.AgentID),
		"source_type": bumblebeeTelemetryProducerID,
		"ocsf_class":  ocsfClass,
		"run_id":      payload.RunID,
	}
	if strings.TrimSpace(payload.DeviceUID) != "" {
		metadata["device_uid"] = strings.TrimSpace(payload.DeviceUID)
	}
	if strings.TrimSpace(payload.CatalogSnapshotRef) != "" {
		metadata["catalog_snapshot_ref"] = strings.TrimSpace(payload.CatalogSnapshotRef)
	}
	return metadata
}

func bumblebeeDeviceObject(payload bumblebee.ScanPayload, fallbackAgentID string) map[string]any {
	agentID := bumblebeeFirstNonEmpty(payload.AgentID, fallbackAgentID, "agent")
	device := map[string]any{
		"name": agentID,
	}
	if strings.TrimSpace(payload.DeviceUID) != "" {
		device["uid"] = strings.TrimSpace(payload.DeviceUID)
	}
	return device
}

func bumblebeeEventUnmapped(payload bumblebee.ScanPayload) map[string]any {
	return map[string]any{
		"agent_id":              payload.AgentID,
		"device_uid":            payload.DeviceUID,
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

func bumblebeeFindingUnmapped(payload bumblebee.ScanPayload, finding bumblebee.Finding) map[string]any {
	return map[string]any{
		"agent_id":             payload.AgentID,
		"device_uid":           payload.DeviceUID,
		"run_id":               payload.RunID,
		"catalog_snapshot_ref": payload.CatalogSnapshotRef,
		"scanner_version":      payload.ScannerVersion,
		"source_type":          bumblebeeTelemetryProducerID,
		"finding_id":           bumblebeeFirstNonEmpty(finding.FindingID, finding.ID),
		"catalog_id":           finding.CatalogID,
		"ecosystem":            finding.Ecosystem,
		"package_name":         finding.PackageName,
		"package_version":      finding.PackageVersion,
		"risk_score":           finding.RiskScore,
		"confidence":           finding.Confidence,
		"metadata":             finding.Metadata,
	}
}

func bumblebeeStatusID(payload bumblebee.ScanPayload) int {
	if payload.State == bumblebeeStateFailed || payload.CoverageState == bumblebeeCoverageFailed {
		return ocsfStatusFailure
	}

	return ocsfStatusSuccess
}

func bumblebeeStatusName(statusID int) string {
	if statusID == ocsfStatusFailure {
		return "Failure"
	}

	return "Success"
}

func bumblebeeSeverityID(payload bumblebee.ScanPayload) int {
	if payload.State == bumblebeeStateFailed || payload.CoverageState == bumblebeeCoverageFailed {
		return 3
	}

	switch highestBumblebeeSeverity(payload.Findings) {
	case bumblebeeSeverityCritical:
		return 5
	case bumblebeeSeverityHigh:
		return 4
	case bumblebeeSeverityMedium:
		return 3
	case bumblebeeSeverityLow:
		return 2
	default:
		if payload.CoverageState == bumblebeeCoveragePartial {
			return 2
		}
		return 1
	}
}

func bumblebeeFindingSeverityID(finding bumblebee.Finding) int {
	switch normalizedToken(finding.Severity, "") {
	case bumblebeeSeverityCritical:
		return 5
	case bumblebeeSeverityHigh:
		return 4
	case bumblebeeSeverityMedium:
		return 3
	case bumblebeeSeverityLow:
		return 2
	default:
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
		bumblebeeSeverityCritical:      5,
		bumblebeeSeverityHigh:          4,
		bumblebeeSeverityMedium:        3,
		bumblebeeSeverityLow:           2,
		bumblebeeSeverityInfo:          1,
		bumblebeeSeverityInformational: 1,
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
