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

// Package verticalslice builds the fixtures and process harness for
// //integration_tests/edge_record:vertical_slice_test (task 0.12,
// openspec/changes/unify-sweep-results-proto). This file owns fixture
// construction only.
package verticalslice

import (
	"crypto/sha256"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/projection"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Synthetic, CLAUDE.md/AGENTS.md-safe values only: TEST-NET-1 (RFC 5737
// 192.0.2.0/24) addresses and *.example.com hostnames. Never real network
// data, never an org's own RFC1918 addressing scheme.
var fixtureHosts = []struct {
	addr     [4]byte
	hostname string
}{
	{[4]byte{192, 0, 2, 10}, "host01.example.com"},
	{[4]byte{192, 0, 2, 11}, "host02.example.com"},
	{[4]byte{192, 0, 2, 12}, "host03.example.com"},
}

// FixtureRecord is one committed, self-consistent EdgeRecordV1 (wrapping a
// SweepObservationBatchV1 payload) plus every independently-computed value a
// caller needs to assert against CNPG after ingestion, without re-deriving
// digests/keys through the same code path that built the record (task 0.12
// groups A/B/C require an INDEPENDENT observation, not a value re-derived by
// calling back into this helper).
//
// Only four tables persist anything for this milestone
// (elixir/serviceradar_core/priv/repo/migrations/20260910120000_create_edge_record_ledger.exs,
// prefix "platform"): event_ledger, edge_delivery_slots,
// edge_sweep_batch_slots, edge_sweep_projected_rows. None of them carry sweep
// domain field values (host/ip/port) yet -- that is explicitly out of scope
// for 0.12 per the migration's own moduledoc ("NOT the full OCSF sweep
// domain schema... that belongs to task 5.1's decoder"). So "the queried
// Sweep domain row" a caller can assert against today is these ledger/slot/
// projected-row columns, keyed by the values below -- not host/IP content.
type FixtureRecord struct {
	// EventID is a UUIDv7 (16 bytes). Use it as BOTH the spool.Append
	// eventID and it is embedded as EdgeRecordV1.event_id. Matches
	// event_ledger.event_id, edge_delivery_slots.event_id,
	// edge_sweep_batch_slots.event_id, edge_sweep_projected_rows.event_id
	// (all :uuid columns -- exactly 16 bytes).
	EventID []byte

	// RecordBytes is the exact encoded EdgeRecordV1 -- hand this directly to
	// spool.Append(EventID, RecordBytes) as the entry body. It is also what
	// the sender embeds verbatim as EdgeDeliveryFrameV1.record_bytes
	// (go/pkg/edge/sender/sender.go's buildFrame), so re-reading it back
	// through the spool's public read path (group B) and re-reading the
	// stored JetStream message (group B) must both equal this slice
	// byte-for-byte.
	RecordBytes []byte

	// RecordSHA256 is sha256(RecordBytes), computed here independently of
	// sender.go's own buildFrame (which recomputes it a second time when it
	// builds the wire frame) -- an independent witness for group B/C
	// assertions, not a value borrowed from the sender.
	RecordSHA256 []byte

	// SemanticEnvelopeSHA256 is the record's semantic_envelope_sha256 field
	// (edgerecord.SemanticEnvelopeDigest), the semantic_digest event_ledger,
	// edge_delivery_slots, and edge_sweep_batch_slots all store, and the
	// input to projection.RowKey/2 for every row in RowKeys below.
	SemanticEnvelopeSHA256 []byte

	// NetworkScopeID is a UUID (16 bytes): EdgeRecordV1.network_scope_id,
	// and the leading key column of every one of the four ledger/slot
	// tables above.
	NetworkScopeID []byte

	// ExecutionID, ExecutionShard, AssignmentEpoch, BatchSequence together
	// are the SweepObservationBatchV1 batch coordinate embedded in the
	// payload, and (with NetworkScopeID) the primary key of
	// edge_sweep_batch_slots.
	ExecutionID     []byte
	ExecutionShard  uint32
	AssignmentEpoch uint64
	BatchSequence   uint64

	// ProjectedRowCount is len(projection.SweepProjectionRows(batch)),
	// computed independently here (not by asking the processor). It is the
	// expected edge_sweep_batch_slots.projected_row_count AND
	// edge_sweep_batch_slots.committed_row_count value on first commit, and
	// the expected row count of edge_sweep_projected_rows rows keyed by
	// NetworkScopeID after ingestion.
	ProjectedRowCount int

	// RowKeys are projection.RowKey(SemanticEnvelopeSHA256, ordinal) for
	// ordinal in [0, ProjectedRowCount), in ProjectionRows.sweep/1's
	// enumeration order (reachability, then open_port/port_error/mtr_summary
	// per host, host order). Each is expected to appear exactly once as
	// edge_sweep_projected_rows.row_key for this NetworkScopeID.
	RowKeys [][]byte

	// Batch is the exact decoded SweepObservationBatchV1 this record's
	// payload carries, kept for callers that want to log/compare it (e.g.
	// group B debugging) without re-decoding RecordBytes.
	Batch *edgev1.SweepObservationBatchV1
}

// BuildSweepFixture constructs one deterministic, structurally-valid
// SweepObservationBatchV1 (3 hosts: a reachability-only host, a host with an
// open port and a port error, and a host with an MTR summary -- 5 projected
// rows total) wrapped in an EdgeRecordV1, uncompressed (NONE), with a
// self-issued production_capability.
//
// production_capability's signature is the literal placeholder
// []byte("signature"), matching this repo's own established test-fixture
// convention (go/pkg/edge/edgerecord/validate_test.go's productionCap) --
// ValidateRecord (and every check the gateway's Stream RPC actually performs
// today, per edge_record_ingest_server.ex's moduledoc lines 12-34) verifies
// the capability's STRUCTURE and its binding to this record's own fields,
// never a real cryptographic signature or a registry trust chain. Building a
// real ed25519-signed, registry-trusted capability would be modeling task
// 3.2 grant/contract verification, which the gateway explicitly does not
// implement yet -- out of scope for this fixture.
// originPrincipalID MUST equal the exact bytes the gateway will record as
// edge_delivery_slots.authenticated_agent_id for the RPC session that sends
// this fixture -- ServiceRadar.EventWriter.Processors.EdgeRecord.ingest/3's
// check_slot_matches_record/2 (elixir/serviceradar_core/lib/serviceradar/event_writer/processors/edge_record.ex:147-159)
// rejects the WHOLE transaction with :agent_mismatch when
// producer_context.origin_principal_id disagrees with the transport-header
// slot's authenticated_agent_id, and edge_record_ingest_server.ex's
// publish_frame/5 sets that header field to state.identity.component_id --
// the UTF-8 bytes of ComponentIdentityResolver.resolve_from_cert/1's parsed
// CN component-id label, i.e. exactly CertSet.AgentComponentID's bytes for
// the real agent client certificate this harness generates (certs.go). The
// caller MUST pass []byte(certSet.AgentComponentID), not a placeholder.
func BuildSweepFixture(originPrincipalID []byte) (*FixtureRecord, error) {
	return buildFixture(1, originPrincipalID)
}

// BuildConflictingSweepFixture returns a SECOND, independently valid
// EdgeRecordV1 sharing networkScopeID and originPrincipalID but otherwise
// different in every content field (different event_id, different
// batch_sequence, different host set, hence a different RecordSHA256 and
// SemanticEnvelopeSHA256) -- task 0.12 Group C's delivery-slot conflict
// probe: "a validly signed, digest-consistent second frame that differs
// from the accepted fixture only in record content and its corresponding
// record_sha256, while reusing the same delivery slot." The caller builds
// an EdgeDeliveryFrameV1 with the SAME (spool_id, sequence) as the first
// accepted frame but this record's RecordBytes/RecordSHA256, to reuse the
// same edge_delivery_slots primary key with different bytes. originPrincipalID
// must be the SAME value passed to BuildSweepFixture (see that function's
// doc comment) -- the conflict probe reuses the same authenticated agent
// session, only the record content differs.
func BuildConflictingSweepFixture(networkScopeID, originPrincipalID []byte) (*FixtureRecord, error) {
	fx, err := buildFixture(2, originPrincipalID)
	if err != nil {
		return nil, err
	}
	fx.NetworkScopeID = networkScopeID
	rebindNetworkScope(fx)
	return fx, nil
}

// variant selects deterministic-but-distinct content so BuildSweepFixture
// and BuildConflictingSweepFixture never accidentally collide.
func buildFixture(variant int, originPrincipalID []byte) (*FixtureRecord, error) {
	eventID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: event id: %w", err)
	}
	networkScopeID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: network scope id: %w", err)
	}
	executionID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: execution id: %w", err)
	}
	producerAssignmentID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: producer assignment id: %w", err)
	}
	runID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: run id: %w", err)
	}
	scopeID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: scope id: %w", err)
	}
	targetRangeID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: target range id: %w", err)
	}
	sourceRunID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: source run id: %w", err)
	}

	batch := sweepBatch(variant, executionID, targetRangeID, sourceRunID)
	if err := edgerecord.ValidateSweepObservationBatch(batch); err != nil {
		return nil, fmt.Errorf("fixture: built sweep batch failed local validation: %w", err)
	}

	payload, err := proto.Marshal(batch)
	if err != nil {
		return nil, fmt.Errorf("fixture: marshal sweep batch: %w", err)
	}
	payloadSum := sha256.Sum256(payload)

	contract := &edgev1.EdgeOutputContractRef{
		ContractId:             "serviceradar.sweep.observation",
		ContractVersion:        1,
		ContractBundleSha256:   fixtureDigest(0x02 + byte(variant)),
		RegistryEpoch:          1,
		RegistrySnapshotSha256: fixtureDigest(0x03 + byte(variant)),
		EffectiveGrantSha256:   fixtureDigest(0x04 + byte(variant)),
	}

	record := &edgev1.EdgeRecordV1{
		EventId:          eventID,
		PayloadFamily:    edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		Compression:      edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE,
		EncodedSize:      uint32(len(payload)),
		UncompressedSize: uint32(len(payload)),
		PayloadSha256:    payloadSum[:],
		OutputContract:   contract,
		ProducerContext: &edgev1.EdgeProducerContext{
			OriginKind:           edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:    originPrincipalID,
			ProducerInstanceId:   []byte("vertical-slice-instance"),
			ProducerAssignmentId: producerAssignmentID,
			RunId:                runID,
			RunShard:             uint32(variant),
			AuthorityEpoch:       proto.Uint64(1),
			ScopeId:              scopeID,
			ScopeSha256:          fixtureDigest(0x06 + byte(variant)),
			PackageId:            "serviceradar.core.sweep",
			PackageSha256:        fixtureDigest(0x05 + byte(variant)),
		},
		RouteProfile:        edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:        edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		NetworkScopeId:      networkScopeID,
		ProjectedRowCount:   uint32(projection.SweepRows(batch)),
		ProjectedWriteBytes: uint64(len(payload)) * 4,
		CostModelVersion:    1,
		Payload:             payload,
	}
	record.ProductionCapability = fixtureCapability(record)
	record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(record)

	if err := edgerecord.ValidateRecord(record); err != nil {
		return nil, fmt.Errorf("fixture: built record failed local validation: %w", err)
	}

	recordBytes, err := proto.Marshal(record)
	if err != nil {
		return nil, fmt.Errorf("fixture: marshal record: %w", err)
	}
	recordSum := sha256.Sum256(recordBytes)

	rowCount := projection.SweepRows(batch)
	rowKeys := make([][]byte, rowCount)
	for i := 0; i < rowCount; i++ {
		rowKeys[i] = projection.RowKey(record.SemanticEnvelopeSha256, i)
	}

	return &FixtureRecord{
		EventID:                eventID,
		RecordBytes:            recordBytes,
		RecordSHA256:           recordSum[:],
		SemanticEnvelopeSHA256: record.SemanticEnvelopeSha256,
		NetworkScopeID:         networkScopeID,
		ExecutionID:            executionID,
		ExecutionShard:         batch.GetExecutionShard(),
		AssignmentEpoch:        batch.GetAssignmentEpoch(),
		BatchSequence:          batch.GetBatchSequence(),
		ProjectedRowCount:      rowCount,
		RowKeys:                rowKeys,
		Batch:                  batch,
	}, nil
}

// rebindNetworkScope re-signs and re-digests fx's record after the caller
// overwrites NetworkScopeID post-construction, so the returned RecordBytes/
// RecordSHA256/SemanticEnvelopeSHA256/RowKeys stay internally consistent
// with the new scope id. Group C needs the CONFLICTING fixture to share the
// primary fixture's NetworkScopeID (part of the reused delivery slot and the
// event_ledger/batch_slot keys) while differing in every other field.
func rebindNetworkScope(fx *FixtureRecord) {
	var record edgev1.EdgeRecordV1
	if err := proto.Unmarshal(fx.RecordBytes, &record); err != nil {
		// buildFixture just produced these bytes; a re-decode failure here
		// would be a bug in this file, not a runtime condition callers can
		// act on.
		panic(fmt.Sprintf("verticalslice: rebindNetworkScope: re-decode: %v", err))
	}
	record.NetworkScopeId = fx.NetworkScopeID
	record.GetProducerContext().ScopeId = fx.NetworkScopeID
	record.ProductionCapability = fixtureCapability(&record)
	record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(&record)

	if err := edgerecord.ValidateRecord(&record); err != nil {
		panic(fmt.Sprintf("verticalslice: rebindNetworkScope: rebound record failed validation: %v", err))
	}

	recordBytes, err := proto.Marshal(&record)
	if err != nil {
		panic(fmt.Sprintf("verticalslice: rebindNetworkScope: marshal: %v", err))
	}
	recordSum := sha256.Sum256(recordBytes)

	rowCount := len(fx.RowKeys)
	rowKeys := make([][]byte, rowCount)
	for i := 0; i < rowCount; i++ {
		rowKeys[i] = projection.RowKey(record.SemanticEnvelopeSha256, i)
	}

	fx.RecordBytes = recordBytes
	fx.RecordSHA256 = recordSum[:]
	fx.SemanticEnvelopeSHA256 = record.SemanticEnvelopeSha256
	fx.RowKeys = rowKeys
}

// fixtureCapability builds a structurally-complete production grant bound to
// r's own fields, mirroring go/pkg/edge/edgerecord/validate_test.go's
// productionCap (including its placeholder, non-cryptographic Signature) --
// the gateway's Stream RPC does not verify a real signature or registry
// trust chain today (see BuildSweepFixture's doc comment).
func fixtureCapability(r *edgev1.EdgeRecordV1) *edgev1.EdgeSignedCapabilityV1 {
	p := r.GetProducerContext()
	c := r.GetOutputContract()
	// A wide-open validity window centered on the current wall clock: this
	// fixture only needs to satisfy ValidateRecord's structural/binding
	// checks, not a real time-boxed grant, but validateIdentityTime (see
	// go/pkg/edge/edgerecord/validate.go) requires the event_id's own
	// embedded UUIDv7 timestamp -- which is "now" at fixture build time --
	// to fall inside [NotBeforeUnixNano, ExpiresAtUnixNano]. An epoch-0
	// window (previously used here) is centuries in the past and always
	// fails that check.
	const day = int64(24 * 60 * 60 * 1_000_000_000)
	now := time.Now().UnixNano()
	notBefore := now - 365*day
	expires := now + 365*day

	return &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("vertical-slice-issuer"),
		IssuerKeyId:       []byte("vertical-slice-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: notBefore,
		ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{
			Production: &edgev1.EdgeProductionClaimsV1{
				ContractId:             c.GetContractId(),
				ContractVersion:        c.GetContractVersion(),
				ContractBundleSha256:   c.GetContractBundleSha256(),
				RegistryEpoch:          c.GetRegistryEpoch(),
				NetworkScopeId:         r.GetNetworkScopeId(),
				ProducerAssignmentId:   p.GetProducerAssignmentId(),
				TrafficClass:           r.GetTrafficClass(),
				RouteProfile:           r.GetRouteProfile(),
				OriginKind:             p.GetOriginKind(),
				OriginPrincipalId:      p.GetOriginPrincipalId(),
				ProducerInstanceId:     p.GetProducerInstanceId(),
				RunId:                  p.GetRunId(),
				RunShard:               p.GetRunShard(),
				AuthorityEpoch:         p.GetAuthorityEpoch(),
				ScopeId:                p.GetScopeId(),
				ScopeSha256:            p.GetScopeSha256(),
				PackageSha256:          p.GetPackageSha256(),
				RegistrySnapshotSha256: c.GetRegistrySnapshotSha256(),
				EffectiveGrantSha256:   c.GetEffectiveGrantSha256(),
				MaxProjectedRowCount:   r.GetProjectedRowCount(),
				MaxProjectedWriteBytes: r.GetProjectedWriteBytes(),
				CostModelVersion:       r.GetCostModelVersion(),
				PackageId:              p.GetPackageId(),
			},
		},
		Signature: []byte("signature"),
	}
}

// sweepBatch builds a 3-host batch: host 0 is reachability-only (ICMP), host
// 1 adds one open port and one port error, host 2 adds an MTR summary -- 6
// projected rows total (host0: 1 reachability; host1: 1 reachability + 1
// open_port + 1 port_error; host2: 1 reachability + 1 mtr_summary; see
// go/pkg/edge/projection/projection.go's SweepProjectionRows, which always
// emits one "reachability" row per host regardless of mode). variant
// perturbs batch_sequence/hostnames/addresses so the primary and conflicting
// fixtures never collide in content.
func sweepBatch(variant int, executionID, targetRangeID, sourceRunID []byte) *edgev1.SweepObservationBatchV1 {
	checks := []*edgev1.SweepTestV1{
		{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_SYN, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
		{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 8443},
		{Mode: edgev1.SweepMode_SWEEP_MODE_MTR, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
	}
	modeBits := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) |
		uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN) |
		uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT) |
		uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)

	hosts := make([]*edgev1.SweepHostObservationV1, 0, len(fixtureHosts))
	for i, h := range fixtureHosts {
		addr := h.addr
		addr[3] += byte(variant - 1) // perturb the low octet per variant, stays in 192.0.2.0/24
		host := &edgev1.SweepHostObservationV1{
			Address:             []byte{addr[0], addr[1], addr[2], addr[3]},
			Hostname:            h.hostname,
			ObservedAtDeltaNano: int64(-1000 - i),
			ModeRevision:        1,
		}

		switch i {
		case 0:
			host.ResultModeBits = uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
			host.Icmp = &edgev1.SweepIcmpSummaryV1{
				Outcome:        edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
				TargetReached:  true,
				RoundTripMicro: proto.Uint64(uint64(900 + i)),
				PacketLossPct:  proto.Float64(0),
				Sent:           3,
				Received:       3,
			}
		case 1:
			host.ResultModeBits = uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN) |
				uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
			host.Tcp = &edgev1.SweepTcpSummaryV1{
				Outcome:     edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
				TestedCount: 2,
				OpenCount:   1,
			}
			host.OpenPorts = []*edgev1.SweepOpenPortV1{
				{TestedCheckIndex: 1, ResponseTimeNano: proto.Uint64(4200), Service: "https"},
			}
			host.PortErrors = []*edgev1.SweepPortErrorV1{
				{TestedCheckIndex: 2, ErrorCode: "timeout"},
			}
		default:
			traceID, err := edgerecord.NewUUIDv7()
			if err != nil {
				// sweepBatch has no error return; a UUID generation
				// failure here means the process's randomness source is
				// broken, which every other NewUUIDv7 call in this file
				// would also already have failed on.
				panic(fmt.Sprintf("verticalslice: sweepBatch: trace id: %v", err))
			}
			host.ResultModeBits = uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)
			host.Mtr = &edgev1.SweepMtrSummaryV1{
				TraceId:       traceID,
				Outcome:       edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
				TargetReached: true,
				FinalRttMicro: proto.Uint64(1500),
				PacketLossPct: proto.Float64(0),
				TotalHops:     4,
			}
		}

		hosts = append(hosts, host)
	}

	return &edgev1.SweepObservationBatchV1{
		ExecutionId:          executionID,
		ExecutionShard:       1,
		AssignmentEpoch:      1,
		BatchSequence:        uint64(variant),
		ObservedAtUnixNano:   1_800_000_000_000_000_000,
		ExecutionPlanId:      executionID,
		ExecutionPlanSha256:  fixtureDigest(0x10 + byte(variant)),
		TargetRangeId:        targetRangeID,
		TargetRangeSha256:    fixtureDigest(0x20 + byte(variant)),
		TestedChecks:         checks,
		ConfiguredModeBits:   modeBits,
		AvailabilityPolicyId: []byte("vertical-slice-policy"),
		Source:               edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		SourceRunId:          sourceRunID,
		Hosts:                hosts,
	}
}

// fixtureDigest returns a deterministic 32-byte filler digest for fields
// that must be exactly 32 bytes but whose real provenance (contract bundle
// hashes, registry snapshot hashes) is out of this fixture's scope.
func fixtureDigest(seed byte) []byte {
	b := make([]byte, 32)
	for i := range b {
		b[i] = seed + byte(i)
	}
	return b
}
