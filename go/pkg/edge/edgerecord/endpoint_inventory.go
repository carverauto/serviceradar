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

const (
	EndpointInventoryContractID             = "serviceradar.endpoint_inventory.scan"
	EndpointInventoryContractVersion uint32 = 1

	// EndpointInventoryProjectedWriteBytesPerRecord is the catalogued projected
	// write cost of one endpoint inventory scan payload. It must match
	// write_bytes_per_row for this contract in core's
	// ServiceRadar.Edge.ContractCatalog.
	EndpointInventoryProjectedWriteBytesPerRecord = 16_384
)

// EndpointInventoryScanRows returns the projected row count for an endpoint
// inventory scan record. Each scan report represents a single projected row.
func EndpointInventoryScanRows(scan *edgev1.EndpointInventoryScanPayloadV1) int {
	if scan == nil {
		return 0
	}
	return 1
}

func validJSONObject(raw []byte) bool {
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return false
	}
	return obj != nil
}

// ValidateEndpointInventoryScan enforces that an endpoint inventory scan
// payload carries the host-stamped agent identity, a scan identifier, and
// well-formed JSON object metadata when metadata_json is present.
func ValidateEndpointInventoryScan(scan *edgev1.EndpointInventoryScanPayloadV1) error {
	if scan == nil {
		return fmt.Errorf("%w: empty endpoint inventory scan", ErrDiscoveryBatch)
	}
	if strings.TrimSpace(scan.GetAgentId()) == "" {
		return fmt.Errorf("%w: endpoint inventory scan has no agent_id", ErrDiscoveryBatch)
	}
	if strings.TrimSpace(scan.GetScanId()) == "" {
		return fmt.Errorf("%w: endpoint inventory scan has no scan_id", ErrDiscoveryBatch)
	}
	if len(scan.GetMetadataJson()) > 0 && !validJSONObject(scan.GetMetadataJson()) {
		return fmt.Errorf("%w: endpoint inventory metadata_json is not a JSON object", ErrDiscoveryBatch)
	}
	return nil
}

// ValidateEndpointInventoryRecord validates an EdgeRecordV1 for the
// serviceradar.endpoint_inventory.scan standing-grant contract.
func ValidateEndpointInventoryRecord(r *edgev1.EdgeRecordV1) error {
	var scan edgev1.EndpointInventoryScanPayloadV1
	return validateDiscoveryRecord(
		r,
		contractRef{EndpointInventoryContractID, EndpointInventoryContractVersion},
		&scan,
		func() (int, error) {
			return EndpointInventoryScanRows(&scan), ValidateEndpointInventoryScan(&scan)
		},
	)
}
