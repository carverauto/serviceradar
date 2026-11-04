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

package agent

import (
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// Workload identity snapshots ride the standing-grant contract
// serviceradar.workload_identity.snapshot through the agent's open edge spool.
// The producer holds at most one built snapshot in memory, pausing reads of
// the on-disk snapshot file until every record for that snapshot has been
// admitted to the spool, and commits the file signature only after admission.
// Built parts keep the event IDs they were first built with across spool
// retries.

type workloadIdentityBuiltItem struct {
	sig     workloadIdentityFileSignature
	records []*edgev1.EdgeRecordV1
	bodies  [][]byte
	next    int
}

type workloadIdentityEdgeQueue struct {
	built *workloadIdentityBuiltItem
}

func (p *PushLoop) edgeWorkloadIdentityCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgeDiscoverySpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.WorkloadIdentityContractID, now)
}

func (p *PushLoop) spoolWorkloadIdentity(capability *edgev1.EdgeSignedCapabilityV1) bool {
	q := &p.workloadIdentityEdge
	if q.built == nil {
		raw, sig, ok := p.nextWorkloadIdentitySnapshot()
		if !ok {
			return false
		}
		records, bodies, dropped, err := workloadIdentityChunks(raw, capability)
		p.dropEdgeTelemetry(edgeProducerWorkloadIdentity, edgeDropInvalidRecord, dropped)
		if err != nil {
			p.logger.Warn().Err(err).Str("contract", edgerecord.WorkloadIdentityContractID).
				Msg("Dropping workload identity snapshot that cannot form an edge record")
			if len(records) == 0 {
				p.commitWorkloadIdentitySignature(sig)
				return false
			}
		}
		q.built = &workloadIdentityBuiltItem{
			sig:     sig,
			records: records,
			bodies:  bodies,
		}
	}
	if !p.appendWorkloadIdentityBuilt(q.built) {
		return false
	}
	p.commitWorkloadIdentitySignature(q.built.sig)
	q.built = nil
	return true
}

func (p *PushLoop) appendWorkloadIdentityBuilt(built *workloadIdentityBuiltItem) bool {
	if p == nil || p.edgeDiscoverySpool == nil {
		return false
	}
	for built.next < len(built.records) {
		record := built.records[built.next]
		if _, err := p.edgeDiscoverySpool.AppendFlow(edgeAdmissionFlow(record), record.GetEventId(), built.bodies[built.next]); err != nil {
			p.logger.Warn().Err(err).Str("contract", edgerecord.WorkloadIdentityContractID).
				Msg("Failed to spool workload identity record; will retry")
			return false
		}
		built.next++
	}
	return true
}

func workloadIdentityChunks(
	raw []byte,
	capability *edgev1.EdgeSignedCapabilityV1,
) (records []*edgev1.EdgeRecordV1, bodies [][]byte, dropped int, err error) {
	snap, dropped, err := parseWorkloadIdentitySnapshot(raw)
	if err != nil {
		return nil, nil, max(dropped, 1), err
	}

	if len(snap.GetIdentities()) == 0 {
		record, body, recErr := workloadIdentityEdgeRecord(snap, capability)
		if recErr != nil {
			return nil, nil, dropped + 1, recErr
		}
		return []*edgev1.EdgeRecordV1{record}, [][]byte{body}, dropped, nil
	}

	remaining := snap.GetIdentities()
	for len(remaining) > 0 {
		n, record, body := longestWorkloadIdentityPrefix(snap, remaining, capability)
		if n == 0 {
			dropped++
			remaining = remaining[1:]
			continue
		}
		records = append(records, record)
		bodies = append(bodies, body)
		remaining = remaining[n:]
	}
	if len(records) == 0 {
		return nil, nil, max(dropped, 1), errDiscoveryNoValidRecord
	}
	return records, bodies, dropped, nil
}

func longestWorkloadIdentityPrefix(
	base *edgev1.WorkloadIdentitySnapshotV1,
	identities []*edgev1.WorkloadIdentityContainerLookupV1,
	capability *edgev1.EdgeSignedCapabilityV1,
) (int, *edgev1.EdgeRecordV1, []byte) {
	limit := len(identities)
	if maxRows := workloadIdentityMaxRows(capability); uint64(limit) > maxRows {
		limit = int(maxRows)
	}

	bestN := 0
	var bestRecord *edgev1.EdgeRecordV1
	var bestBody []byte
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		part := workloadIdentitySnapshotPart(base, identities[:mid])
		record, body, err := workloadIdentityEdgeRecord(part, capability)
		if err == nil {
			bestN, bestRecord, bestBody = mid, record, body
			lo = mid + 1
			continue
		}
		hi = mid - 1
	}
	return bestN, bestRecord, bestBody
}

func workloadIdentitySnapshotPart(
	base *edgev1.WorkloadIdentitySnapshotV1,
	identities []*edgev1.WorkloadIdentityContainerLookupV1,
) *edgev1.WorkloadIdentitySnapshotV1 {
	count := uint32(len(identities))
	if len(identities) == len(base.GetIdentities()) && base.GetCount() > 0 {
		count = base.GetCount()
	}
	return &edgev1.WorkloadIdentitySnapshotV1{
		ObservedAtUnixNano: base.GetObservedAtUnixNano(),
		Enabled:            base.GetEnabled(),
		Endpoint:           base.GetEndpoint(),
		Count:              count,
		Identities:         identities,
		DegradationReason:  base.GetDegradationReason(),
		ContextName:        base.GetContextName(),
		ClusterId:          base.GetClusterId(),
		ClusterName:        base.GetClusterName(),
	}
}

func workloadIdentityMaxRows(capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(
		uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.WorkloadIdentityProjectedWriteBytesPerRecord,
	)
}

func workloadIdentityEdgeRecord(
	snap *edgev1.WorkloadIdentitySnapshotV1,
	capability *edgev1.EdgeSignedCapabilityV1,
) (*edgev1.EdgeRecordV1, []byte, error) {
	rows := edgerecord.WorkloadIdentitySnapshotRows(snap)
	record, body, _, err := edgeBatchRecord(
		snap,
		capability,
		rows,
		workloadIdentityMaxRows(capability),
		edgerecord.WorkloadIdentityProjectedWriteBytesPerRecord,
		errDiscoveryRecordTooLarge,
		edgerecord.ValidateWorkloadIdentityRecord,
	)
	return record, body, err
}
