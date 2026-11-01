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
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

// The metrics batch output contract: one contract for every agent producer that
// emits the canonical protobuf metric envelope (sysmon, SNMP, ICMP, MTR and sweep
// scalars, rperf), told apart by the batch's own ingest identity. Its records run
// under a standing output grant and carry no source authorization.
const (
	MetricsBatchContractID             = "serviceradar.metrics.batch"
	MetricsBatchContractVersion uint32 = 1
	MetricBatchSchemaVersion           = "serviceradar.metric.v1"
)

var (
	// ErrMetricBatch is returned for a metrics batch body that breaks the
	// contract's payload rules.
	ErrMetricBatch = errors.New("edgerecord: invalid metric batch")
	// ErrMetricBatchSourceAuthorization is returned when a metrics batch
	// record carries a source authorization, which a standing grant never issues.
	ErrMetricBatchSourceAuthorization = errors.New("edgerecord: metrics batch record carries a source authorization")
)

// ValidateMetricBatch enforces the metrics batch payload rules: the canonical
// metric envelope schema and at least one metric.
func ValidateMetricBatch(batch *metricpb.MetricBatch) error {
	if batch == nil {
		return fmt.Errorf("%w: empty batch", ErrMetricBatch)
	}
	if batch.GetSchemaVersion() != MetricBatchSchemaVersion {
		return fmt.Errorf("%w: schema_version %q", ErrMetricBatch, batch.GetSchemaVersion())
	}
	if len(batch.GetMetrics()) == 0 {
		return fmt.Errorf("%w: no metrics", ErrMetricBatch)
	}
	return nil
}

// ValidateMetricBatchRecord is the composed validator a producer runs before it
// spools a metrics batch record: the whole record (ValidateRecord), the exact
// metrics batch contract, RECORD_BATCH_V1 framing, no source authorization, the
// decoded body, and a projected row count equal to the body's metric count.
// Signatures are verified by the gateway, which holds the trust snapshot.
func ValidateMetricBatchRecord(r *edgev1.EdgeRecordV1) error {
	if err := ValidateRecord(r); err != nil {
		return err
	}
	contract := r.GetOutputContract()
	if contract.GetContractId() != MetricsBatchContractID ||
		contract.GetContractVersion() != MetricsBatchContractVersion {
		return fmt.Errorf("%w: %s v%d", ErrContractDispatch, contract.GetContractId(), contract.GetContractVersion())
	}
	if err := requireFramingFamily(r,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		ErrPayloadFraming); err != nil {
		return err
	}
	if r.GetSourceAuthorization() != nil {
		return ErrMetricBatchSourceAuthorization
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var batch metricpb.MetricBatch
	if err := unmarshalPayload(inner, &batch); err != nil {
		return err
	}
	if err := ValidateMetricBatch(&batch); err != nil {
		return err
	}
	if uint64(r.GetProjectedRowCount()) != uint64(len(batch.GetMetrics())) {
		return fmt.Errorf("%w: projected_row_count %d for %d metrics",
			ErrMetricBatch, r.GetProjectedRowCount(), len(batch.GetMetrics()))
	}
	return nil
}
