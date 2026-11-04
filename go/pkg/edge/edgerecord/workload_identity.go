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
	"fmt"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// WorkloadIdentityContractID and WorkloadIdentityContractVersion identify
	// the standing-grant workload identity snapshot contract in
	// EdgeOutputContractRefV1.
	WorkloadIdentityContractID             = "serviceradar.workload_identity.snapshot"
	WorkloadIdentityContractVersion uint32 = 1

	// WorkloadIdentityProjectedWriteBytesPerRecord is the cost model v1 per-row
	// write budget for serviceradar.workload_identity.snapshot in core's
	// ServiceRadar.Edge.ContractCatalog.
	WorkloadIdentityProjectedWriteBytesPerRecord = 8_192
)

// WorkloadIdentitySnapshotRows returns the projected row count for a workload
// identity snapshot: one row per container lookup, or one row for the snapshot
// envelope when identities is empty.
func WorkloadIdentitySnapshotRows(snap *edgev1.WorkloadIdentitySnapshotV1) int {
	return max(len(snap.GetIdentities()), 1)
}

// ValidateWorkloadIdentitySnapshot enforces the workload identity snapshot
// payload rules: a non-nil snapshot where every container lookup carries a
// non-empty container_id on the lookup or its nested identity record.
func ValidateWorkloadIdentitySnapshot(snap *edgev1.WorkloadIdentitySnapshotV1) error {
	if snap == nil {
		return fmt.Errorf("%w: workload identity snapshot is nil", ErrDiscoveryBatch)
	}
	for i, lookup := range snap.GetIdentities() {
		if strings.TrimSpace(lookup.GetContainerId()) == "" &&
			strings.TrimSpace(lookup.GetIdentity().GetContainerId()) == "" {
			return fmt.Errorf("%w: workload identity lookup %d has no container_id", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateWorkloadIdentityRecord is ValidateWorkloadIdentitySnapshot composed
// with the standing-grant record checks.
func ValidateWorkloadIdentityRecord(r *edgev1.EdgeRecordV1) error {
	var snap edgev1.WorkloadIdentitySnapshotV1
	return validateDiscoveryRecord(
		r,
		contractRef{WorkloadIdentityContractID, WorkloadIdentityContractVersion},
		&snap,
		func() (int, error) {
			return WorkloadIdentitySnapshotRows(&snap), ValidateWorkloadIdentitySnapshot(&snap)
		},
	)
}
