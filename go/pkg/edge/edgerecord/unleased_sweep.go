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

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The unleased sweep results output contract. Sweep groups an agent runs from its
// own config without a sweep lease emit their results under a standing output
// grant, so their records carry no source authorization. One projected row per
// host.
const (
	UnleasedSweepResultsContractID             = "serviceradar.sweep.unleased_results"
	UnleasedSweepResultsContractVersion uint32 = 1
)

var (
	// ErrUnleasedSweepBatch is returned for an unleased sweep results body that
	// breaks the contract's payload rules.
	ErrUnleasedSweepBatch = errors.New("edgerecord: invalid unleased sweep results batch")
	// ErrUnleasedSweepSourceAuthorization is returned when an unleased sweep
	// results record carries a source authorization, which a standing grant never
	// issues.
	ErrUnleasedSweepSourceAuthorization = errors.New("edgerecord: unleased sweep results record carries a source authorization")
)

// ValidateUnleasedSweepResultsBatch enforces the payload rules: a 16-byte
// execution id, one legacy host result per host, a 4- or 16-byte address per
// host, and tested-check indexes that name a check of the batch.
func ValidateUnleasedSweepResultsBatch(batch *edgev1.UnleasedSweepResultsBatchV1) error {
	if batch == nil {
		return fmt.Errorf("%w: empty batch", ErrUnleasedSweepBatch)
	}
	if len(batch.GetExecutionId()) != 16 {
		return fmt.Errorf("%w: execution_id is %d bytes", ErrUnleasedSweepBatch, len(batch.GetExecutionId()))
	}
	if id := batch.GetSweepGroupId(); len(id) != 0 && len(id) != 16 {
		return fmt.Errorf("%w: sweep_group_id is %d bytes", ErrUnleasedSweepBatch, len(id))
	}
	if len(batch.GetHostResults()) != len(batch.GetHosts()) {
		return fmt.Errorf("%w: %d host results for %d hosts",
			ErrUnleasedSweepBatch, len(batch.GetHostResults()), len(batch.GetHosts()))
	}
	checks := uint32(len(batch.GetTestedChecks()))
	for i, host := range batch.GetHosts() {
		if n := len(host.GetAddress()); n != 4 && n != 16 {
			return fmt.Errorf("%w: host %d address is %d bytes", ErrUnleasedSweepBatch, i, n)
		}
		for _, port := range host.GetOpenPorts() {
			if port.GetTestedCheckIndex() >= checks {
				return fmt.Errorf("%w: host %d open port names check %d of %d",
					ErrUnleasedSweepBatch, i, port.GetTestedCheckIndex(), checks)
			}
		}
		for _, perr := range host.GetPortErrors() {
			if perr.GetTestedCheckIndex() >= checks {
				return fmt.Errorf("%w: host %d port error names check %d of %d",
					ErrUnleasedSweepBatch, i, perr.GetTestedCheckIndex(), checks)
			}
		}
	}
	return nil
}

// ValidateUnleasedSweepResultsRecord is the composed validator a producer runs
// before it spools an unleased sweep results record: the whole record
// (ValidateRecord), the exact contract, RECORD_BATCH_V1 framing, no source
// authorization, the decoded body, and a projected row count equal to its host
// count. Signatures are verified by the gateway, which holds the trust snapshot.
func ValidateUnleasedSweepResultsRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.UnleasedSweepResultsBatchV1
	if err := decodeStandingGrantRecord(r, contractRef{UnleasedSweepResultsContractID, UnleasedSweepResultsContractVersion},
		ErrUnleasedSweepSourceAuthorization, &batch); err != nil {
		return err
	}
	if err := ValidateUnleasedSweepResultsBatch(&batch); err != nil {
		return err
	}
	if uint64(r.GetProjectedRowCount()) != uint64(len(batch.GetHosts())) {
		return fmt.Errorf("%w: projected_row_count %d for %d hosts",
			ErrUnleasedSweepBatch, r.GetProjectedRowCount(), len(batch.GetHosts()))
	}
	return nil
}
