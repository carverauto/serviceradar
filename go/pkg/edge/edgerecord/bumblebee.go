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

package edgerecord

import (
	"encoding/json"
	"fmt"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The Bumblebee endpoint scan output contract. Bumblebee scans run from the
// agent's spooled scan results under a standing output grant, so their records
// carry no source authorization. The projected row count is the finding count
// or one for a zero-finding scan (which still updates the device scan state).
const (
	BumblebeeScanContractID             = "serviceradar.bumblebee.scan"
	BumblebeeScanContractVersion uint32 = 1

	BumblebeeScanProjectedWriteBytesPerRecord = 16_384
)

// BumblebeeScanRows returns the projected row count for a Bumblebee scan
// payload: the number of findings, or 1 when the scan completed with zero
// findings (because the device scan state row is still written).
func BumblebeeScanRows(scan *edgev1.BumblebeeScanPayloadV1) uint32 {
	return uint32(max(len(scan.GetFindings()), 1))
}

// ValidateBumblebeeScan enforces the Bumblebee scan payload rules: a non-nil
// scan naming the agent and scan run, optional JSON object metadata on the
// scan, and for each finding a finding identifier and optional JSON object
// evidence and metadata.
func ValidateBumblebeeScan(scan *edgev1.BumblebeeScanPayloadV1) error {
	if scan == nil {
		return fmt.Errorf("%w: empty bumblebee scan", ErrDiscoveryBatch)
	}
	if strings.TrimSpace(scan.GetAgentId()) == "" {
		return fmt.Errorf("%w: bumblebee scan has no agent_id", ErrDiscoveryBatch)
	}
	if strings.TrimSpace(scan.GetRunId()) == "" {
		return fmt.Errorf("%w: bumblebee scan has no run_id", ErrDiscoveryBatch)
	}
	if !validJSONObjectBytes(scan.GetMetadataJson()) {
		return fmt.Errorf("%w: bumblebee scan metadata_json is not a JSON object", ErrDiscoveryBatch)
	}
	for i, finding := range scan.GetFindings() {
		if finding == nil ||
			(strings.TrimSpace(finding.GetFindingId()) == "" && strings.TrimSpace(finding.GetId()) == "") {
			return fmt.Errorf("%w: bumblebee finding %d has no finding_id or id", ErrDiscoveryBatch, i)
		}
		if !validJSONObjectBytes(finding.GetEvidenceJson()) {
			return fmt.Errorf("%w: bumblebee finding %d evidence_json is not a JSON object", ErrDiscoveryBatch, i)
		}
		if !validJSONObjectBytes(finding.GetMetadataJson()) {
			return fmt.Errorf("%w: bumblebee finding %d metadata_json is not a JSON object", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateBumblebeeScanRecord is ValidateBumblebeeScan composed over a whole
// edge record.
func ValidateBumblebeeScanRecord(r *edgev1.EdgeRecordV1) error {
	var scan edgev1.BumblebeeScanPayloadV1
	return validateDiscoveryRecord(r,
		contractRef{BumblebeeScanContractID, BumblebeeScanContractVersion}, &scan,
		func() (int, error) { return int(BumblebeeScanRows(&scan)), ValidateBumblebeeScan(&scan) })
}

func validJSONObjectBytes(raw []byte) bool {
	if len(raw) == 0 {
		return true
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil || decoded == nil {
		return false
	}
	return true
}
