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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	{[4]byte{192, 0, 2, 8}, "host01.example.com"},
	{[4]byte{192, 0, 2, 9}, "host02.example.com"},
	{[4]byte{192, 0, 2, 10}, "host03.example.com"},
	{[4]byte{192, 0, 2, 11}, "host04.example.com"},
}

// FixtureRecord is one committed, self-consistent EdgeRecordV1 (wrapping a
// SweepObservationBatchV1 payload) plus every independently-computed value a
// caller needs to assert against CNPG after ingestion, without re-deriving
// digests/keys through the same code path that built the record (task 0.12
// groups A/B/C require an INDEPENDENT observation, not a value re-derived by
// calling back into this helper).
//
// The harness also checks ordinary sweep results, execution progress, discovered
// devices and device availability against Batch's independently chosen host values.
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

// BuildSweepFixture constructs a complete four-host ICMP/TCP window in one
// synthetic /30 range. The composed harness replaces its initial synthetic
// capabilities with core-issued authority over durable assignments and slots
// before delivery; offline selfchecks exercise the fixture's wire contract.
//
// originPrincipalID MUST equal the exact bytes the gateway will record as
// edge_delivery_slots.authenticated_agent_id for the RPC session that sends
// this fixture -- ServiceRadar.EventWriter.Processors.EdgeRecord.ingest/3's
// check_slot_matches_record/2 (elixir/serviceradar_core/lib/serviceradar/event_writer/processors/edge_record.ex)
// rejects the WHOLE transaction with :agent_mismatch when
// producer_context.origin_principal_id disagrees with the transport-header
// slot's authenticated_agent_id, and edge_record_ingest_server.ex's
// publish_frame/5 sets that header field to state.identity.component_id --
// the UTF-8 bytes of ComponentIdentityResolver.resolve_edge_identity/3's parsed
// CN component-id label, i.e. exactly CertSet.AgentComponentID's bytes for
// the real agent client certificate this harness generates (certs.go). The
// caller MUST pass []byte(certSet.AgentComponentID), not a placeholder --
// except vertical_slice_test.go's Group G, which passes another principal to
// observe the gateway refuse the record before publication.
func BuildSweepFixture(originPrincipalID []byte) (*FixtureRecord, error) {
	return buildFixture(primaryFixtureVariant, originPrincipalID)
}

// BuildSweepFixtureInScope is BuildSweepFixture with the record bound to
// networkScopeID instead of a fresh scope. A fixture appended to a spool that
// already holds records must use this: one agent spool carries exactly one
// network scope (ingestion-routing), and the gateway ends a stream whose
// records name a second one.
func BuildSweepFixtureInScope(networkScopeID, originPrincipalID []byte) (*FixtureRecord, error) {
	fx, err := buildFixture(1, originPrincipalID)
	if err != nil {
		return nil, err
	}
	fx.NetworkScopeID = networkScopeID
	rebindNetworkScope(fx)
	return fx, nil
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
	fx, err := buildFixture(conflictingFixtureVariant, originPrincipalID)
	if err != nil {
		return nil, err
	}
	fx.NetworkScopeID = networkScopeID
	rebindNetworkScope(fx)
	return fx, nil
}

// Fixtures share one synthetic network scope. The composed harness obtains
// fresh producer assignments and execution slots from core for each record.
const (
	primaryFixtureVariant     = 1
	conflictingFixtureVariant = 2
	fixtureAuthorityEpoch     = 1
)

func fixtureNetworkScopeID() []byte { return fixtureUUID(0x5c) }

func fixtureProducerAssignmentID() []byte { return fixtureUUID(0xa5) }

// fixtureUUID returns a deterministic canonical (version 7) UUID.
func fixtureUUID(seed byte) []byte {
	id := fixtureDigest(seed)[:16]
	id[6] = 0x70 | id[6]&0x0f
	id[8] = 0x80 | id[8]&0x3f
	return id
}

// variant selects deterministic-but-distinct content so BuildSweepFixture
// and BuildConflictingSweepFixture never accidentally collide.
func buildFixture(variant int, originPrincipalID []byte) (*FixtureRecord, error) {
	eventID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: event id: %w", err)
	}
	networkScopeID := fixtureNetworkScopeID()
	executionID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("fixture: execution id: %w", err)
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
	batch := sweepBatch(variant, executionID, targetRangeID, scopeID)
	if err := edgerecord.ValidateSweepObservationBatch(batch); err != nil {
		return nil, fmt.Errorf("fixture: built sweep batch failed local validation: %w", err)
	}

	payload, err := proto.Marshal(batch)
	if err != nil {
		return nil, fmt.Errorf("fixture: marshal sweep batch: %w", err)
	}
	payloadSum := sha256.Sum256(payload)

	// The contract reference is the SAME for every variant: the gateway admits records against one
	// installation-static registry entry (FixtureContractRegistryJSON), and Group C's conflict frame
	// must differ from the accepted fixture only in record content, not in the bundle it names.
	contract := &edgev1.EdgeOutputContractRef{
		ContractId:             fixtureContractID,
		ContractVersion:        fixtureContractVersion,
		ContractBundleSha256:   fixtureDigest(fixtureBundleSeed),
		RegistryEpoch:          fixtureRegistryEpoch,
		RegistrySnapshotSha256: fixtureDigest(fixtureSnapshotSeed),
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
			ProducerAssignmentId: fixtureProducerAssignmentID(),
			RunId:                runID,
			RunShard:             uint32(variant),
			AuthorityEpoch:       proto.Uint64(fixtureAuthorityEpoch),
			ScopeId:              scopeID,
			ScopeSha256:          fixtureDigest(0x06 + byte(variant)),
			PackageId:            "serviceradar.core.sweep",
			PackageSha256:        fixtureDigest(0x05 + byte(variant)),
		},
		RouteProfile:        edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:        edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		NetworkScopeId:      networkScopeID,
		ProjectedRowCount:   uint32(projection.SweepRows(batch)),
		ProjectedWriteBytes: uint64(projection.SweepRows(batch)) * 2048,
		CostModelVersion:    fixtureCostModel,
		Payload:             payload,
	}
	record.ProductionCapability = fixtureCapability(record)
	record.SourceAuthorization = fixtureSourceAuthorization(record, batch)
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
	record.SourceAuthorization = fixtureSourceAuthorization(&record, fx.Batch)
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
// productionCap, and signs it with Ed25519 under fixtureIssuerKey, the
// synthetic fixture issuer. The gateway verifies that signature against its
// live trust snapshot, whose public key core derives from the same synthetic seed.
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

	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte(fixtureIssuerID),
		IssuerKeyId:       fixtureIssuerKeyID(),
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
	}
	capability.Signature = ed25519.Sign(fixtureIssuerKey(), edgerecord.CapabilitySigningBytes(capability))

	return capability
}

// The private seed is invented solely for this harness and supplied to core's
// normal issuer-key file loader. The key id follows IssuerKey.key_id/1's wire identity.
const fixtureIssuerID = "serviceradar-core"

func fixtureIssuerSeed() []byte {
	seed := sha256.Sum256([]byte("serviceradar vertical slice synthetic capability issuer v1"))
	return seed[:]
}

func fixtureIssuerKey() ed25519.PrivateKey { return ed25519.NewKeyFromSeed(fixtureIssuerSeed()) }

func fixtureIssuerKeyID() []byte {
	sum := sha256.Sum256(append([]byte("serviceradar.edge.issuer_key.v1"), FixtureIssuerPublicKey()...))
	return sum[:16]
}

func FixtureIssuerPublicKey() ed25519.PublicKey {
	return fixtureIssuerKey().Public().(ed25519.PublicKey)
}

func fixtureSourceAuthorization(r *edgev1.EdgeRecordV1, batch *edgev1.SweepObservationBatchV1) *edgev1.EdgeSourceAuthorizationV1 {
	p := r.GetProducerContext()
	production := r.GetProductionCapability()
	kind := edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
	claims := &edgev1.EdgeSourceClaimsV1{
		Kind: kind, ContextId: batch.GetExecutionId(), ScopeId: batch.GetTargetRangeId(),
		ScopeSha256: batch.GetTargetRangeSha256(), NetworkScopeId: r.GetNetworkScopeId(),
		CollectionNotBeforeUnixNano: production.GetNotBeforeUnixNano(), CollectionExpiresUnixNano: production.GetExpiresAtUnixNano(),
		OriginPrincipalId: p.GetOriginPrincipalId(), ProducerInstanceId: p.GetProducerInstanceId(),
		ProducerAssignmentId: p.GetProducerAssignmentId(), RunId: p.GetRunId(), RunShard: p.GetRunShard(),
		AuthorityEpoch: p.GetAuthorityEpoch(), TrafficClass: r.GetTrafficClass(), RouteProfile: r.GetRouteProfile(),
		ExecutionPlanSha256: batch.GetExecutionPlanSha256(), TargetRangeSha256: batch.GetTargetRangeSha256(),
		OriginKind: p.GetOriginKind(),
	}
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte(fixtureIssuerID), IssuerKeyId: fixtureIssuerKeyID(), Algorithm: "ed25519",
		NotBeforeUnixNano: production.GetNotBeforeUnixNano(), ExpiresAtUnixNano: production.GetExpiresAtUnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: claims},
	}
	capability.Signature = ed25519.Sign(fixtureIssuerKey(), edgerecord.CapabilitySigningBytes(capability))
	return &edgev1.EdgeSourceAuthorizationV1{Kind: kind, Capability: capability, ContextId: claims.ContextId,
		ScopeId: claims.ScopeId, ScopeSha256: claims.ScopeSha256}
}

// Every host completes both configured checks. One /30 range lets core issue
// one real source authorization covering the entire terminal window.
func sweepBatch(variant int, executionID, targetRangeID, groupID []byte) *edgev1.SweepObservationBatchV1 {
	checks := []*edgev1.SweepTestV1{
		{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
	}
	modeBits := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
	hosts := make([]*edgev1.SweepHostObservationV1, 0, len(fixtureHosts))
	for i, h := range fixtureHosts {
		addr := h.addr
		addr[3] += byte(4 * (variant - 1))
		hosts = append(hosts, &edgev1.SweepHostObservationV1{
			Address: addr[:], Hostname: h.hostname, ObservedAtDeltaNano: int64(-1000 - i),
			ModeRevision: 1, ResultModeBits: modeBits,
			Icmp: &edgev1.SweepIcmpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
				TargetReached: true, RoundTripMicro: proto.Uint64(uint64(900 + i)), PacketLossPct: proto.Float64(0), Sent: 3, Received: 3},
			Tcp:       &edgev1.SweepTcpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS, TestedCount: 1, OpenCount: 1},
			OpenPorts: []*edgev1.SweepOpenPortV1{{TestedCheckIndex: 1, ResponseTimeNano: proto.Uint64(4200), Service: "https"}},
		})
	}
	return &edgev1.SweepObservationBatchV1{
		ExecutionId: executionID, SweepGroupId: groupID, ExecutionShard: uint32(variant), AssignmentEpoch: 1,
		BatchSequence: uint64(variant), ObservedAtUnixNano: time.Now().UnixNano(), ExecutionPlanId: executionID,
		ExecutionPlanSha256: fixtureDigest(0x10 + byte(variant)), TargetRangeId: targetRangeID,
		TargetRangeSha256: fixtureDigest(0x20 + byte(variant)), TestedChecks: checks, ConfiguredModeBits: modeBits,
		AvailabilityPolicyId: []byte("any-success-v1"), Source: edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		Hosts: hosts,
	}
}

// The single output contract every fixture record names, and the registry snapshot it belongs to.
const (
	fixtureContractID      = "serviceradar.sweep.observation"
	fixtureContractVersion = 1
	fixtureRegistryEpoch   = 1
	fixtureBundleSeed      = 0x03
	fixtureSnapshotSeed    = 0x04
	fixtureCostModel       = 1
)

// FixtureContractRegistryJSON is the installation-static contract registry snapshot the gateway
// release boots with (AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY, parsed by
// ServiceRadarAgentGateway.EdgeContractRegistry.Static): exactly the one contract every fixture
// record names, active on the durable bulk route. The gateway admits a record only when its
// output contract matches this entry, so the two are built from the same constants.
func FixtureContractRegistryJSON() (string, error) {
	type contract struct {
		ContractID           string `json:"contract_id"`
		ContractVersion      uint32 `json:"contract_version"`
		ContractBundleSHA256 string `json:"contract_bundle_sha256"`
		State                string `json:"state"`
		RouteProfile         string `json:"route_profile"`
		TrafficClass         string `json:"traffic_class"`
		PartitionRule        string `json:"partition_rule"`
		CostModelVersion     uint32 `json:"cost_model_version"`
	}
	type snapshot struct {
		RegistryEpoch          uint64     `json:"registry_epoch"`
		RegistrySnapshotSHA256 string     `json:"registry_snapshot_sha256"`
		Contracts              []contract `json:"contracts"`
	}

	out, err := json.Marshal(snapshot{
		RegistryEpoch:          fixtureRegistryEpoch,
		RegistrySnapshotSHA256: hex.EncodeToString(fixtureDigest(fixtureSnapshotSeed)),
		Contracts: []contract{{
			ContractID:           fixtureContractID,
			ContractVersion:      fixtureContractVersion,
			ContractBundleSHA256: hex.EncodeToString(fixtureDigest(fixtureBundleSeed)),
			State:                "active",
			RouteProfile:         edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1.String(),
			TrafficClass:         edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK.String(),
			PartitionRule:        "network_scope_v1",
			CostModelVersion:     fixtureCostModel,
		}},
	})
	if err != nil {
		return "", fmt.Errorf("fixture: marshal contract registry: %w", err)
	}
	return string(out), nil
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
