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

// The agent-scheduled MTR trace output contract. Scheduled and unleased MTR
// checks an agent runs from its own config emit their full traces under a
// standing output grant, so their records carry no source authorization. One
// projected row per trace, at 2048 projected write bytes per row.
const (
	ScheduledMtrTraceContractID               = "serviceradar.mtr.scheduled_trace"
	ScheduledMtrTraceContractVersion   uint32 = 1
	ScheduledMtrTraceMaxRows                  = 1000
	ScheduledMtrTraceProjectedRowBytes uint64 = 2048
)

var (
	// ErrScheduledMtrBatch is returned for a scheduled MTR trace batch body that
	// breaks the contract's payload rules.
	ErrScheduledMtrBatch = errors.New("edgerecord: invalid scheduled MTR trace batch")
	// ErrScheduledMtrSourceAuthorization is returned when a scheduled MTR trace
	// record carries a source authorization, which a standing grant never issues.
	ErrScheduledMtrSourceAuthorization = errors.New("edgerecord: scheduled MTR trace record carries a source authorization")
)

func knownMtrTcpProbeMode(mode edgev1.MtrTcpProbeModeV1) bool {
	switch mode {
	case edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_UNSPECIFIED,
		edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_SYN,
		edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_CONNECT:
		return true
	default:
		return false
	}
}

// ValidateScheduledMtrTraceBatch enforces the payload rules on a decoded
// AgentScheduledMtrTraceBatchV1: 1..1000 traces, per-trace UUIDv7 identity,
// optional 16-byte sweep group / execution IDs, closed TCP probe mode, valid
// TCP port, and canonical MtrTraceEventV1 + MtrTraceHopV1 invariants.
func ValidateScheduledMtrTraceBatch(batch *edgev1.AgentScheduledMtrTraceBatchV1) error {
	if batch == nil {
		return ErrNilRecord
	}
	traces := batch.GetTraces()
	if len(traces) == 0 || len(traces) > ScheduledMtrTraceMaxRows {
		return fmt.Errorf("%w: %d traces", ErrScheduledMtrBatch, len(traces))
	}
	for i, entry := range traces {
		if err := validateScheduledMtrTraceEntry(i, entry); err != nil {
			return err
		}
	}
	return nil
}

func validateScheduledMtrTraceEntry(i int, entry *edgev1.AgentScheduledMtrTraceV1) error {
	if entry == nil || entry.GetTrace() == nil {
		return fmt.Errorf("%w: trace %d is nil", ErrScheduledMtrBatch, i)
	}
	if l := len(entry.GetSweepGroupId()); l != 0 && l != 16 {
		return fmt.Errorf("%w: trace %d sweep_group_id is %d bytes", ErrScheduledMtrBatch, i, l)
	}
	if l := len(entry.GetExecutionId()); l != 0 && l != 16 {
		return fmt.Errorf("%w: trace %d execution_id is %d bytes", ErrScheduledMtrBatch, i, l)
	}
	if !knownMtrTcpProbeMode(entry.GetTcpProbeMode()) {
		return fmt.Errorf("%w: trace %d tcp_probe_mode %d", ErrScheduledMtrBatch, i, entry.GetTcpProbeMode())
	}
	if entry.GetTcpPort() > 65535 {
		return fmt.Errorf("%w: trace %d tcp_port %d", ErrScheduledMtrBatch, i, entry.GetTcpPort())
	}
	return validateScheduledMtrTraceEvent(i, entry.GetTrace())
}

func validateScheduledMtrTraceEvent(i int, tr *edgev1.MtrTraceEventV1) error {
	if validateUUIDv7Field(tr.GetTraceId()) != nil || validateUUIDv7Field(tr.GetEventId()) != nil {
		return fmt.Errorf("%w: trace %d trace_id/event_id must be UUIDv7", ErrScheduledMtrBatch, i)
	}
	if l := len(tr.GetSweepHostAddress()); l != 0 && l != 4 && l != 16 {
		return fmt.Errorf("%w: trace %d sweep_host_address", ErrScheduledMtrBatch, i)
	}
	if len(tr.GetDeviceHint()) > MaxTraceStrBytes ||
		len(tr.GetErrorCode()) > MaxTraceStrBytes ||
		len(tr.GetTarget()) > MaxTraceStrBytes {
		return fmt.Errorf("%w: trace %d strings", ErrScheduledMtrBatch, i)
	}
	if tr.GetObservedAtUnixNano() <= 0 ||
		!mtrTerminalOutcome(tr.GetOutcome()) ||
		!knownTransportProtocol(tr.GetProtocol()) {
		return fmt.Errorf("%w: trace %d time/outcome/protocol", ErrScheduledMtrBatch, i)
	}
	if tr.GetIpVersion() != 4 && tr.GetIpVersion() != 6 {
		return fmt.Errorf("%w: trace %d ip_version", ErrScheduledMtrBatch, i)
	}
	if tr.GetTarget() == "" {
		return fmt.Errorf("%w: trace %d target", ErrScheduledMtrBatch, i)
	}
	if l := len(tr.GetResolvedAddress()); l != 0 && l != 4 && l != 16 {
		return fmt.Errorf("%w: trace %d resolved_address", ErrScheduledMtrBatch, i)
	}
	if len(tr.GetHops()) > MaxHopsPerTrace {
		return ErrMtrBounds
	}
	if tr.GetTargetReached() && (!tr.GetAttempted() || tr.GetTotalHops() == 0) {
		return fmt.Errorf("%w: trace %d reached without attempt/hops", ErrScheduledMtrBatch, i)
	}
	var maxHop uint32
	for j, hop := range tr.GetHops() {
		if err := validateMtrHop(hop); err != nil {
			return err
		}
		if j > 0 && hop.GetHopNumber() <= maxHop {
			return fmt.Errorf("%w: hops not strictly increasing", ErrMtrHop)
		}
		maxHop = hop.GetHopNumber()
	}
	if maxHop > tr.GetTotalHops() {
		return fmt.Errorf("%w: trace %d total_hops below highest recorded hop", ErrScheduledMtrBatch, i)
	}
	return nil
}

// ValidateScheduledMtrTraceRecord is the composed validator a producer runs
// before it spools a scheduled MTR trace record: the whole record
// (ValidateRecord), the exact contract, RECORD_BATCH_V1 framing, no source
// authorization, the decoded body, a projected row count equal to its trace
// count, and projected write bytes equal to projected_row_count * 2048.
// Signatures are verified by the gateway, which holds the trust snapshot.
func ValidateScheduledMtrTraceRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.AgentScheduledMtrTraceBatchV1
	if err := decodeStandingGrantRecord(r, contractRef{ScheduledMtrTraceContractID, ScheduledMtrTraceContractVersion},
		ErrScheduledMtrSourceAuthorization, &batch); err != nil {
		return err
	}
	if err := ValidateScheduledMtrTraceBatch(&batch); err != nil {
		return err
	}
	if uint64(r.GetProjectedRowCount()) != uint64(len(batch.GetTraces())) {
		return fmt.Errorf("%w: projected_row_count %d for %d traces",
			ErrScheduledMtrBatch, r.GetProjectedRowCount(), len(batch.GetTraces()))
	}
	if r.GetProjectedWriteBytes() != uint64(r.GetProjectedRowCount())*ScheduledMtrTraceProjectedRowBytes {
		return fmt.Errorf("%w: projected_write_bytes %d for %d rows",
			ErrScheduledMtrBatch, r.GetProjectedWriteBytes(), r.GetProjectedRowCount())
	}
	return nil
}
