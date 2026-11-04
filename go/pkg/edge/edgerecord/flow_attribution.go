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
	"errors"
	"fmt"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// FlowAttributionContractID is the canonical output contract for netprobe flow attribution batches.
	FlowAttributionContractID = "serviceradar.netprobe.flow_attribution"
	// FlowAttributionContractVersion is the v1 schema version for flow attribution batches.
	FlowAttributionContractVersion uint32 = 1
	// FlowAttributionMaxRows is the contract's max_projected_rows bound (4,096 events per record).
	FlowAttributionMaxRows = 4096
	// FlowAttributionWriteBytesPerRow is the contract's write_bytes_per_row factor.
	FlowAttributionWriteBytesPerRow uint64 = 983029
)

var (
	// ErrFlowAttributionBatch reports a malformed or out-of-contract FlowAttributionEventBatch payload.
	ErrFlowAttributionBatch = errors.New("edgerecord: invalid flow attribution batch payload")
	// ErrFlowAttributionSourceAuthorization reports a standing-grant flow attribution record carrying source_authorization.
	ErrFlowAttributionSourceAuthorization = errors.New("edgerecord: flow attribution record must not carry source authorization")
)

// ValidateFlowAttributionRecord validates an EdgeRecordV1 under the standing-grant
// contract serviceradar.netprobe.flow_attribution v1, decompresses its inner
// FlowAttributionEventBatch payload, and checks the batch and cost invariants.
func ValidateFlowAttributionRecord(r *edgev1.EdgeRecordV1) error {
	if err := ValidateRecord(r); err != nil {
		return err
	}
	contract := r.GetOutputContract()
	if contract.GetContractId() != FlowAttributionContractID ||
		contract.GetContractVersion() != FlowAttributionContractVersion {
		return fmt.Errorf("%w: %s v%d", ErrContractDispatch, contract.GetContractId(), contract.GetContractVersion())
	}
	if err := requireFramingFamily(r); err != nil {
		return err
	}
	if r.GetSourceAuthorization() != nil {
		return ErrFlowAttributionSourceAuthorization
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var batch netprobepb.FlowAttributionEventBatch
	if err := unmarshalPayload(inner, &batch); err != nil {
		return err
	}
	if err := ValidateFlowAttributionBatch(&batch); err != nil {
		return err
	}
	expectedRows := uint64(len(batch.GetEvents()))
	if uint64(r.GetProjectedRowCount()) != expectedRows {
		return fmt.Errorf(
			"%w: projected_row_count %d != events %d",
			ErrFlowAttributionBatch, r.GetProjectedRowCount(), expectedRows,
		)
	}
	expectedWriteBytes := expectedRows * FlowAttributionWriteBytesPerRow
	if r.GetProjectedWriteBytes() != expectedWriteBytes {
		return fmt.Errorf(
			"%w: projected_write_bytes %d != expected %d",
			ErrFlowAttributionBatch, r.GetProjectedWriteBytes(), expectedWriteBytes,
		)
	}
	return nil
}

// ValidateFlowAttributionBatch validates a decoded FlowAttributionEventBatch against
// the serviceradar.netprobe.flow_attribution v1 contract rules.
func ValidateFlowAttributionBatch(batch *netprobepb.FlowAttributionEventBatch) error {
	if batch == nil {
		return fmt.Errorf("%w: nil batch", ErrFlowAttributionBatch)
	}
	events := batch.GetEvents()
	if len(events) == 0 || len(events) > FlowAttributionMaxRows {
		return fmt.Errorf(
			"%w: events count %d outside [1, %d]",
			ErrFlowAttributionBatch, len(events), FlowAttributionMaxRows,
		)
	}
	start := batch.GetBatchStartUnixNano()
	end := batch.GetBatchEndUnixNano()
	if start < 0 || end < 0 {
		return fmt.Errorf(
			"%w: negative batch window [%d, %d]",
			ErrFlowAttributionBatch, start, end,
		)
	}
	if start != 0 && end != 0 && start > end {
		return fmt.Errorf(
			"%w: batch_start_unix_nano %d > batch_end_unix_nano %d",
			ErrFlowAttributionBatch, start, end,
		)
	}
	for i, ev := range events {
		if ev == nil {
			return fmt.Errorf("%w: events[%d]: nil event", ErrFlowAttributionBatch, i)
		}
	}
	return nil
}
