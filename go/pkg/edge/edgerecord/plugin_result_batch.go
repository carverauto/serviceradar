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
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The Wasm plugin results output contract. Plugin check executions emit their
// results under a standing output grant, so their records carry no source
// authorization. One projected row per result; the host stamps the batch
// provenance from its own assignment record, never from the guest payload.
const (
	PluginResultsContractID             = "serviceradar.plugin_results.batch"
	PluginResultsContractVersion uint32 = 1

	// PluginResultsProjectedWriteBytesPerRecord is the catalogued projected
	// write cost of one plugin result (status row plus handler fan-out). It
	// must match write_bytes_per_row for this contract in core's
	// ServiceRadar.Edge.ContractCatalog.
	PluginResultsProjectedWriteBytesPerRecord = 16_384
)

var (
	// ErrPluginResultBatch is returned for a plugin results body that breaks
	// the contract's payload rules.
	ErrPluginResultBatch = errors.New("edgerecord: invalid plugin result batch")
	// ErrPluginResultSourceAuthorization is returned when a plugin results
	// record carries a source authorization, which a standing grant never
	// issues.
	ErrPluginResultSourceAuthorization = errors.New("edgerecord: plugin results record carries a source authorization")
)

// ValidatePluginResultBatch enforces the payload rules: host-stamped
// provenance naming the assignment, at least one result, and per result a
// known status and a non-empty summary, matching what the legacy status path
// required before a result could be ingested.
func ValidatePluginResultBatch(batch *edgev1.WasmPluginResultBatchV1) error {
	if batch == nil {
		return fmt.Errorf("%w: empty batch", ErrPluginResultBatch)
	}
	provenance := batch.GetProvenance()
	if provenance == nil || strings.TrimSpace(provenance.GetAssignmentId()) == "" {
		return fmt.Errorf("%w: missing host-stamped assignment provenance", ErrPluginResultBatch)
	}
	if len(batch.GetResults()) == 0 {
		return fmt.Errorf("%w: no results", ErrPluginResultBatch)
	}
	for i, result := range batch.GetResults() {
		if result.GetStatus() == edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_UNSPECIFIED {
			return fmt.Errorf("%w: result %d has no status", ErrPluginResultBatch, i)
		}
		if strings.TrimSpace(result.GetSummary()) == "" {
			return fmt.Errorf("%w: result %d has no summary", ErrPluginResultBatch, i)
		}
	}
	return nil
}

// ValidatePluginResultRecord is the composed validator a producer runs before
// it spools a plugin results record: the whole record (ValidateRecord), the
// exact contract, RECORD_BATCH_V1 framing, no source authorization, the
// decoded body, and a projected row count equal to its result count.
// Signatures are verified by the gateway, which holds the trust snapshot.
func ValidatePluginResultRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.WasmPluginResultBatchV1
	if err := decodeStandingGrantRecord(r, contractRef{PluginResultsContractID, PluginResultsContractVersion},
		ErrPluginResultSourceAuthorization, &batch); err != nil {
		return err
	}
	if err := ValidatePluginResultBatch(&batch); err != nil {
		return err
	}
	if uint64(r.GetProjectedRowCount()) != uint64(len(batch.GetResults())) {
		return fmt.Errorf("%w: projected_row_count %d for %d results",
			ErrPluginResultBatch, r.GetProjectedRowCount(), len(batch.GetResults()))
	}
	return nil
}
