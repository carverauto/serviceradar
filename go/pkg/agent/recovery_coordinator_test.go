// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	gproto "google.golang.org/protobuf/proto"
)

type recoveryGatewayFixture struct {
	proto.AgentGatewayServiceClient
	t            *testing.T
	registered   *proto.EdgeRecoveryRegistration
	queries      int
	copyExpired  bool
	copyRequests []*proto.EdgeRecoveryCopyGrantRequest
}

func (f *recoveryGatewayFixture) RegisterEdgeRecovery(_ context.Context, r *proto.EdgeRecoveryRegistration, _ ...grpc.CallOption) (*proto.EdgeRecoveryStatus, error) {
	tomb := new(edgev1.SpoolLossTombstoneV1)
	require.NoError(f.t, gproto.Unmarshal(r.Tombstone, tomb))
	require.NoError(f.t, edgerecord.ValidateManifestChainFromRaw(r.ManifestPages, tomb.ManifestRootSha256))
	if f.registered != nil {
		require.True(f.t, gproto.Equal(f.registered, r), "restart changed immutable registration")
	}
	f.registered = gproto.Clone(r).(*proto.EdgeRecoveryRegistration)
	return &proto.EdgeRecoveryStatus{State: proto.EdgeRecoveryState_EDGE_RECOVERY_STATE_PENDING}, nil
}
func recoveryFixtureSource(t *testing.T, production *edgev1.EdgeSignedCapabilityV1, id, digest []byte) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	p := production.GetProduction()
	cap := gproto.Clone(production).(*edgev1.EdgeSignedCapabilityV1)
	cap.Claims = &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{
		Kind: edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL, ContextId: id, ScopeId: id, ScopeSha256: digest,
		NetworkScopeId: p.NetworkScopeId, CollectionNotBeforeUnixNano: cap.NotBeforeUnixNano, CollectionExpiresUnixNano: cap.ExpiresAtUnixNano,
		OriginKind: p.OriginKind, OriginPrincipalId: p.OriginPrincipalId, ProducerInstanceId: p.ProducerInstanceId, ProducerAssignmentId: p.ProducerAssignmentId,
		RunId: p.RunId, RunShard: p.RunShard, AuthorityEpoch: p.AuthorityEpoch, RouteProfile: p.RouteProfile, TrafficClass: p.TrafficClass,
	}}
	edgerecord.SignCapability(cap, testIssuerPrivateKey())
	return cap
}
func (f *recoveryGatewayFixture) AuthorizeEdgeRecovery(_ context.Context, r *proto.EdgeRecoveryAuthorizationRequest, _ ...grpc.CallOption) (*proto.EdgeRecoveryAuthorizationResponse, error) {
	require.NotNil(f.t, f.registered)
	payload := new(edgev1.EdgeRecoveryControlPayloadV1)
	require.NoError(f.t, gproto.Unmarshal(r.ControlPayload, payload))
	var id, digest []byte
	if page := payload.GetManifestPage(); page != nil {
		id = page.RecoveryId
		digest = edgerecord.ManifestPageScopeDigest(page)
	} else {
		tomb := payload.GetTombstone()
		id = tomb.GetRecoveryId()
		digest = edgerecord.TombstoneScopeDigest(tomb)
	}
	require.Equal(f.t, f.registered.RecoveryId, id)
	capability := recoveryFixtureSource(f.t, r.ProductionCapability, id, digest)
	return &proto.EdgeRecoveryAuthorizationResponse{SourceAuthorization: &edgev1.EdgeSourceAuthorizationV1{Kind: edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL, ContextId: id, ScopeId: id, ScopeSha256: digest, Capability: capability}}, nil
}
func (f *recoveryGatewayFixture) GetEdgeRecovery(_ context.Context, q *proto.EdgeRecoveryQuery, _ ...grpc.CallOption) (*proto.EdgeRecoveryStatus, error) {
	f.queries++
	require.Equal(f.t, f.registered.RecoveryId, q.RecoveryId)
	tomb := new(edgev1.SpoolLossTombstoneV1)
	require.NoError(f.t, gproto.Unmarshal(f.registered.Tombstone, tomb))
	body := &edgev1.RecoveryResolvedV1{RecoveryId: q.RecoveryId, ManifestRootSha256: tomb.ManifestRootSha256, AppliedThroughSequence: f.registered.ThroughSequence, ResolvedAtUnixNano: time.Now().UnixNano()}
	entry := recoveryFixtureGrant(f.t)
	production := new(edgev1.EdgeSignedCapabilityV1)
	require.NoError(f.t, gproto.Unmarshal(entry.ProductionCapability, production))
	capability := recoveryFixtureSource(f.t, production, body.RecoveryId, edgerecord.ResolvedScopeDigest(body))
	return &proto.EdgeRecoveryStatus{State: proto.EdgeRecoveryState_EDGE_RECOVERY_STATE_RESOLVED, Resolved: body, ResolutionCapability: capability}, nil
}
func recoveryFixtureGrant(t *testing.T) *proto.EdgeOutputGrant {
	t.Helper()
	entry := currentMetricsGrant(t)
	cap := new(edgev1.EdgeSignedCapabilityV1)
	require.NoError(t, gproto.Unmarshal(entry.ProductionCapability, cap))
	p := cap.GetProduction()
	p.ContractId = "serviceradar.edge.recovery_control"
	p.PackageId = "serviceradar.agent.recovery"
	p.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	p.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK
	p.MaxProjectedRowCount = 8192
	p.MaxProjectedWriteBytes = (1 << 20) + 32768*1024
	edgerecord.SignCapability(cap, testIssuerPrivateKey())
	raw, err := gproto.Marshal(cap)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{ContractId: p.ContractId, ContractVersion: 1, ProductionCapability: raw}
}
func recoveryFixturePolicy(t *testing.T, store *RecordSpool) *PushLoop {
	t.Helper()
	loop, _ := sysmonEdgeLoop(t, store)
	require.Empty(t, installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t), recoveryFixtureGrant(t)}, time.Now()))
	store.SetRecoveryGrantProvider(loop.EdgeRecoveryProductionCapability)
	store.SetRecoveryPeerProvider(func() uint32 { return 1 })
	return loop
}
func recoveryFixtureDeliverControl(t *testing.T, c *RecoveryCoordinator, g *spool.Generation, kind edgev1.EdgeRecordDispositionKind) ([]*edgev1.EdgeDeliveryFrameV1, error) {
	t.Helper()
	delivery, err := c.Delivery(g)
	require.NoError(t, err)
	require.NotNil(t, delivery)
	require.False(t, delivery.RequiresCopyGrant())
	stream := &recoveryIngestFixture{disposition: kind}
	id := g.Identity()
	runner, err := sender.New(g, stream, sender.Config{SpoolID: id.SpoolID, RouteProfile: id.Lane.RouteProfile, TrafficClass: id.Lane.TrafficClass, RequestedByteCredits: 1 << 20, RequestedFrameCredits: 16, PersistAcknowledgements: true, BeforeResolve: delivery.BeforeResolve})
	require.NoError(t, err)
	_, err = runner.RunOnce(context.Background())
	return stream.frames, err
}
func driveRecoveryTo(t *testing.T, c *RecoveryCoordinator, phase string) {
	t.Helper()
	for range 64 {
		got, err := c.Step(context.Background())
		if got == phase {
			require.NoError(t, err)
			return
		}
		require.NoError(t, err, "phase %s", got)
	}
	t.Fatalf("recovery did not reach %s", phase)
}
func TestRecoveryCoordinatorReopensCoverageAndCompletesAllGapSource(t *testing.T) {
	for _, copies := range []int{0, 1} {
		t.Run(map[int]string{0: "all_gap", 1: "retained_copy_restart"}[copies], func(t *testing.T) {
			store, coordinator, gateway, originalID, stops := recoveryGapFixture(t, copies)
			root := store.root
			defer func() { require.NoError(t, store.Close()) }()
			if copies == 0 {
				store.SetRecoveryPeerProvider(func() uint32 { return 0 })
				_, err := coordinator.Step(context.Background())
				require.ErrorIs(t, err, ErrRecoveryPending)
				require.Zero(t, store.allocator.Usage().ActiveRecoveries)
				require.False(t, soleTestGeneration(t, store).Closed())
				store.SetRecoveryPeerProvider(func() uint32 { return 1 })
			}
			driveRecoveryTo(t, coordinator, "publish")
			require.Equal(t, 1, *stops)
			run := coordinator.operation()
			require.NotNil(t, run)
			require.Len(t, run.plan.Slots, copies+1)
			require.Equal(t, originalID.SpoolID, run.plan.Source.SpoolID)
			require.Len(t, run.handles.Controls, 1)
			_, deliveryErr := recoveryFixtureDeliverControl(t, coordinator, run.handles.Controls[0], edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
			require.NoError(t, deliveryErr)
			if copies == 0 {
				require.NoError(t, store.Close())
				var reopenErr error
				store, reopenErr = openTestRecordSpool(t, root)
				require.NoError(t, reopenErr)
				recoveryFixturePolicy(t, store)
				coordinator = NewRecoveryCoordinator(store, gateway, func(context.Context, *spool.Generation) (func(), error) {
					t.Fatal("acknowledged frozen source was recaptured")
					return nil, nil
				})
				driveRecoveryTo(t, coordinator, "register")
				run = coordinator.operation()
			}
			driveRecoveryTo(t, coordinator, "coverage")
			driveRecoveryTo(t, coordinator, "source_reclaim")
			health, err := run.handles.Source.Health(time.Now())
			require.NoError(t, err)
			require.Zero(t, health.GapCount)
			if copies > 0 {
				phase, err := coordinator.Step(context.Background())
				require.Equal(t, "cleanup", phase)
				require.ErrorIs(t, err, spool.ErrRecoveryCleanupPending)
				queries := gateway.queries
				require.NoError(t, store.Close())
				store, err = openTestRecordSpool(t, root)
				require.NoError(t, err)
				store.SetRecoveryPeerProvider(func() uint32 { return 1 })
				coordinator = NewRecoveryCoordinator(store, gateway, func(context.Context, *spool.Generation) (func(), error) {
					t.Fatal("recovered source was refrozen")
					return nil, nil
				})
				for range 16 {
					if coordinator.Ready() {
						break
					}
					_, err = coordinator.Step(context.Background())
					require.NoError(t, err)
				}
				require.True(t, coordinator.Ready())
				require.False(t, store.Ready())
				driveRecoveryTo(t, coordinator, "register")
				phase, err = coordinator.Step(context.Background())
				require.Equal(t, "receipt_trust", phase)
				require.ErrorIs(t, err, edgerecord.ErrTrustMissing)
				require.Equal(t, queries, gateway.queries, "stored receipt queried/reissued instead of revalidated")
				recoveryFixturePolicy(t, store)
				// Registration is idempotently replayed after restart before sender policy is available.
				if !coordinator.operation().registered {
					driveRecoveryTo(t, coordinator, "register")
				}
				recoveryFixtureSendCopy(t, coordinator, gateway)
			}
			driveRecoveryTo(t, coordinator, "completed")
			require.Nil(t, coordinator.operation())
			require.Zero(t, store.allocator.Usage().ActiveRecoveries)
			fresh, collector := sysmonEdgeLoop(t, store)
			require.Empty(t, installTestEdgeGrants(t, fresh, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now()))
			collector.queued = syntheticSysmonSamples(1)
			require.True(t, fresh.pushSysmonMetrics())
			var cursor RecordSpoolCursor
			delivered := 0
			for item, ok := store.NextSource(&cursor); ok; item, ok = store.NextSource(&cursor) {
				h, err := item.Source.Health(time.Now())
				require.NoError(t, err)
				require.Zero(t, h.GapCount)
				stream := &recoveryIngestFixture{}
				id := item.Identity
				runner, err := sender.New(item.Source, stream, sender.Config{SpoolID: id.SpoolID, RouteProfile: id.Lane.RouteProfile, TrafficClass: id.Lane.TrafficClass, RequestedByteCredits: 1 << 20, RequestedFrameCredits: 16, PersistAcknowledgements: true})
				require.NoError(t, err)
				_, err = runner.RunOnce(context.Background())
				if !errors.Is(err, sender.ErrNoUnresolvedRecords) {
					require.NoError(t, err)
				}
				delivered += len(stream.frames)
			}
			require.Equal(t, 1, delivered, "new ordinary producer could not append and deliver after cleanup")
		})
	}
}

func TestRecoveryCoordinatorRetainsOrphanInventoryAndBlocksAdmission(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "recoveries", "synthetic-orphan", "retained")
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0700))
	data := []byte("synthetic unassociated recovery bytes")
	require.NoError(t, os.WriteFile(path, data, 0600))
	store, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	defer func() { _ = store.Close() }()
	recoveryFixturePolicy(t, store)
	before := store.allocator.Usage()
	c := NewRecoveryCoordinator(store, &recoveryGatewayFixture{t: t}, nil)
	phase, err := c.Step(context.Background())
	require.Equal(t, "inventory", phase)
	require.ErrorIs(t, err, ErrRecoveryPending)
	require.False(t, c.Ready())
	available, detail := store.RecoveryStatus()
	require.False(t, available)
	require.Contains(t, detail, "unassociated retained recovery files")
	require.False(t, store.Ready())
	require.Equal(t, before, store.allocator.Usage())
	retained, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, data, retained)
	_, err = store.PrepareRecord(nil)
	require.ErrorIs(t, err, spool.ErrAdmissionPaused)
}

func (f *recoveryGatewayFixture) RenewEdgeRecoveryCopies(_ context.Context, request *proto.EdgeRecoveryCopyGrantRequest, _ ...grpc.CallOption) (*proto.EdgeDeliveryGrantResponse, error) {
	f.copyRequests = append(f.copyRequests, gproto.Clone(request).(*proto.EdgeRecoveryCopyGrantRequest))
	require.Equal(f.t, f.registered.RecoveryId, request.GetRecovery().GetRecoveryId())
	response := &proto.EdgeDeliveryGrantResponse{}
	for _, item := range request.Records {
		require.Equal(f.t, uint64(1), item.PriorSequence)
		require.Equal(f.t, uint64(1), item.NewSequence)
		record, err := edgerecord.DecodeRecord(item.RecordBytes)
		require.NoError(f.t, err)
		digest := sha256.Sum256(item.RecordBytes)
		require.Equal(f.t, f.registered.Copies[0].RecordSha256, digest[:])
		start := time.Now().Add(-time.Minute)
		if f.copyExpired {
			start = time.Now().Add(-16 * time.Minute)
		}
		cap := &edgev1.EdgeSignedCapabilityV1{CapabilityVersion: 1, IssuerId: []byte("test-issuer"), IssuerKeyId: []byte("test-issuer-key-1"), Algorithm: "ed25519", NotBeforeUnixNano: start.UnixNano(), ExpiresAtUnixNano: start.Add(15 * time.Minute).UnixNano(), Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{EventId: record.EventId, RecordSha256: digest[:], SpoolId: f.registered.NewSpoolId, Sequence: item.NewSequence, Transition: &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{RecoveryId: f.registered.RecoveryId, PriorSpoolId: f.registered.PriorSpoolId, PriorSequence: item.PriorSequence}}}}}
		edgerecord.SignCapability(cap, testIssuerPrivateKey())
		response.Results = append(response.Results, &proto.EdgeDeliveryGrantResult{Sequence: item.NewSequence, DeliveryCapability: cap})
	}
	return response, nil
}

// This is the authenticated transport boundary; sender admission, grant renewal,
// session validation, terminal durability and coordinator cleanup remain real.
type recoveryIngestFixture struct {
	frames      []*edgev1.EdgeDeliveryFrameV1
	disposition edgev1.EdgeRecordDispositionKind
}
type recoveryIngestStream struct {
	grpc.ClientStream
	fixture *recoveryIngestFixture
	ctx     context.Context
	open    *edgev1.EdgeRecordLaneOpen
	pending []*edgev1.EdgeRecordServerMessage
	frames  []*edgev1.EdgeDeliveryFrameV1
}

func (f *recoveryIngestFixture) Stream(ctx context.Context, _ ...grpc.CallOption) (grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage], error) {
	return &recoveryIngestStream{fixture: f, ctx: ctx}, nil
}
func (s *recoveryIngestStream) Context() context.Context { return s.ctx }
func (s *recoveryIngestStream) Send(message *edgev1.EdgeRecordClientMessage) error {
	if open := message.GetLaneOpen(); open != nil {
		s.open = open
		s.pending = append(s.pending, &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: &edgev1.EdgeRecordLaneOpenAck{SpoolId: open.SpoolId, SessionNonce: open.SessionNonce, RouteProfile: open.RouteProfile, TrafficClass: open.TrafficClass, GrantedByteCredits: open.RequestedByteCredits, GrantedFrameCredits: open.RequestedFrameCredits}}})
	} else {
		frame := message.GetDeliveryFrame()
		s.frames = append(s.frames, frame)
		s.fixture.frames = append(s.fixture.frames, frame)
	}
	return nil
}
func (s *recoveryIngestStream) CloseSend() error {
	if len(s.frames) == 0 {
		return nil
	}
	kind := s.fixture.disposition
	if kind == edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED {
		kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
	}
	ack := &edgev1.EdgeDeliveryAckV1{SpoolId: s.open.SpoolId, SessionNonce: s.open.SessionNonce, ResolvedThroughSequence: s.frames[len(s.frames)-1].Sequence}
	for _, frame := range s.frames {
		record, err := edgerecord.DecodeRecord(frame.RecordBytes)
		if err != nil {
			return err
		}
		ack.Dispositions = append(ack.Dispositions, &edgev1.EdgeRecordDisposition{Sequence: frame.Sequence, EventId: record.EventId, Kind: kind})
	}
	s.pending = append(s.pending, &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: ack}})
	return nil
}
func (s *recoveryIngestStream) Recv() (*edgev1.EdgeRecordServerMessage, error) {
	if len(s.pending) == 0 {
		return nil, io.EOF
	}
	message := s.pending[0]
	s.pending = s.pending[1:]
	return message, nil
}
func recoveryFixtureSendCopy(t *testing.T, c *RecoveryCoordinator, gateway *recoveryGatewayFixture) {
	t.Helper()
	g := c.operation().handles.Destination
	delivery, err := c.Delivery(g)
	require.NoError(t, err)
	require.True(t, delivery.RequiresCopyGrant())
	stream := &recoveryIngestFixture{}
	id := g.Identity()
	runner, err := sender.New(g, stream, sender.Config{SpoolID: id.SpoolID, RouteProfile: id.Lane.RouteProfile, TrafficClass: id.Lane.TrafficClass, RequestedByteCredits: 1 << 20, RequestedFrameCredits: 16, PersistAcknowledgements: true, Grants: delivery, RequireDeliveryGrant: true, BeforeResolve: delivery.BeforeResolve})
	require.NoError(t, err)
	gateway.copyExpired = true
	_, err = runner.RunOnce(context.Background())
	require.ErrorIs(t, err, sender.ErrDeliveryGrantRequired)
	require.Empty(t, stream.frames)
	require.Zero(t, g.Resolved())
	gateway.copyExpired = false
	result, err := runner.RunOnce(context.Background())
	require.NoError(t, err)
	require.Equal(t, []uint64{1}, result.Sent)
	require.Len(t, gateway.copyRequests, 2)
	require.True(t, gproto.Equal(gateway.copyRequests[0], gateway.copyRequests[1]))
	require.Len(t, stream.frames, 1)
	require.Equal(t, gateway.copyRequests[1].Records[0].RecordBytes, stream.frames[0].RecordBytes)
	require.NotNil(t, stream.frames[0].DeliveryCapability.GetDelivery().GetRollover())
	require.Equal(t, uint64(1), g.Resolved())
}

func recoveryGapFixture(t *testing.T, copies int) (*RecordSpool, *RecoveryCoordinator, *recoveryGatewayFixture, spool.GenerationIdentity, *int) {
	t.Helper()
	root := t.TempDir()
	store, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	loop, collector := sysmonEdgeLoop(t, store)
	require.Empty(t, installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t), recoveryFixtureGrant(t)}, time.Now()))
	for range copies + 1 {
		collector.queued = syntheticSysmonSamples(1)
		require.True(t, loop.pushSysmonMetrics())
	}
	source := soleTestGeneration(t, store)
	originalID := source.Identity()
	var records []spool.Record
	require.NoError(t, source.ScanFrom(0, func(r spool.Record) bool { records = append(records, r); return true }))
	keep := int64(0)
	if copies > 0 {
		keep = int64(42 + len(records[0].Body))
	}
	directory := source.Directory()
	require.NoError(t, store.Close())
	require.NoError(t, os.Truncate(filepath.Join(directory, "lane.seg"), keep))
	store, err = openTestRecordSpool(t, root)
	require.NoError(t, err)
	recoveryFixturePolicy(t, store)
	gateway := &recoveryGatewayFixture{t: t}
	stops := 0
	coordinator := NewRecoveryCoordinator(store, gateway, func(context.Context, *spool.Generation) (func(), error) { stops++; return func() {}, nil })
	return store, coordinator, gateway, originalID, &stops
}

func TestRecoveryCoordinatorReauthorizesImmutablePagesWithinAttemptBound(t *testing.T) {
	store, c, gateway, _, _ := recoveryGapFixture(t, 0)
	defer func() { _ = store.Close() }()
	driveRecoveryTo(t, c, "publish")
	run := c.operation()
	first, err := run.op.PublicationProgress()
	require.NoError(t, err)
	require.Len(t, first.Bundles[0], 2)
	_, err = recoveryFixtureDeliverControl(t, c, run.handles.Controls[0], edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY)
	require.NoError(t, err)
	pending, err := run.op.PublicationProgress()
	require.NoError(t, err)
	require.Equal(t, []bool{false, false}, pending.Acknowledged, "audit-only acceptance counted as applied control coverage")
	loop := recoveryFixturePolicy(t, store)
	for epoch := uint64(2); epoch <= 3; epoch++ {
		grant := recoveryFixtureGrant(t)
		cap := new(edgev1.EdgeSignedCapabilityV1)
		require.NoError(t, gproto.Unmarshal(grant.ProductionCapability, cap))
		cap.GetProduction().AuthorityEpoch = epoch
		grant.ProductionCapability, err = gproto.Marshal(cap)
		require.NoError(t, err)
		require.Empty(t, installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, time.Now()))
		before := store.allocator.Usage()
		phase, stepErr := c.Step(context.Background())
		require.Equal(t, "publish", phase)
		if epoch == 3 {
			require.ErrorIs(t, stepErr, spool.ErrRecoverySplitRequired)
			require.Equal(t, before, store.allocator.Usage(), "third attempt consumed reserve before refusal")
			require.Len(t, store.Lanes().Generations(c.controlLane()), 2)
			break
		}
		require.NoError(t, stepErr)
		second, err := run.op.PublicationProgress()
		require.NoError(t, err)
		require.Len(t, second.Bundles[1], 2)
		for index, record := range second.Bundles[1] {
			require.Equal(t, first.Bundles[0][index].Payload, record.Payload)
			require.NotEqual(t, first.Bundles[0][index].EventId, record.EventId)
			require.Equal(t, epoch, record.ProducerContext.GetAuthorityEpoch())
		}
		require.False(t, allRecoveryPublicationsAccepted(second.Acknowledged))
	}
	require.NotNil(t, gateway.registered)
}

func TestRecoveryCoordinatorReplaysExactControlBundleAfterInterruptedAttempt(t *testing.T) {
	store, c, gateway, _, _ := recoveryGapFixture(t, 0)
	defer func() { require.NoError(t, store.Close()) }()
	driveRecoveryTo(t, c, "publish")
	run := c.operation()
	original, err := run.op.PublicationProgress()
	require.NoError(t, err)
	path := filepath.Join(run.handles.Controls[0].Directory(), "lane.seg")
	root := store.root
	require.NoError(t, store.Close())
	require.NoError(t, os.Truncate(path, 0))
	store, err = openTestRecordSpool(t, root)
	require.NoError(t, err)
	recoveryFixturePolicy(t, store)
	c = NewRecoveryCoordinator(store, gateway, func(context.Context, *spool.Generation) (func(), error) {
		t.Fatal("frozen source recaptured")
		return nil, nil
	})
	driveRecoveryTo(t, c, "publish")
	recovered, err := c.operation().op.PublicationProgress()
	require.NoError(t, err)
	require.Len(t, recovered.Bundles[1], len(original.Bundles[0]))
	for i, record := range recovered.Bundles[1] {
		require.True(t, gproto.Equal(original.Bundles[0][i], record), "interrupted replay changed exact authorized transport")
	}
	_, err = recoveryFixtureDeliverControl(t, c, c.operation().handles.Controls[1], edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	require.NoError(t, err)
	driveRecoveryTo(t, c, "coverage")
}

func TestRecoveryCoordinatorRetainsControlUntilReceiptBarrierRecovers(t *testing.T) {
	store, c, gateway, _, _ := recoveryGapFixture(t, 0)
	defer func() { require.NoError(t, store.Close()) }()
	driveRecoveryTo(t, c, "publish")
	run := c.operation()
	control := run.handles.Controls[0]
	// Obstruct the second immutable receipt copy after the first can land.
	obstacle := filepath.Join(run.dir, "phase-ack-000-b.tmp")
	require.NoError(t, os.Mkdir(obstacle, 0700))
	frames, err := recoveryFixtureDeliverControl(t, c, control, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	require.Error(t, err)
	require.Len(t, frames, 2)
	require.Zero(t, control.Resolved(), "ordinary ACK persisted before the receipt pair")
	health, err := run.handles.Source.Health(time.Now())
	require.NoError(t, err)
	require.Equal(t, uint64(1), health.GapCount)
	require.Equal(t, 1, store.allocator.Usage().ActiveRecoveries)
	require.NoError(t, os.Remove(obstacle))
	retainedBytes := func() uint64 {
		var total uint64
		for _, dir := range []string{run.dir, run.handles.Destination.Directory(), control.Directory()} {
			require.NoError(t, filepath.WalkDir(dir, func(_ string, entry fs.DirEntry, walkErr error) error {
				if walkErr != nil {
					return walkErr
				}
				info, statErr := entry.Info()
				if statErr != nil {
					return statErr
				}
				if info.Mode().IsRegular() {
					total += uint64(info.Size())
				}
				return nil
			}))
		}
		return total
	}
	physical := retainedBytes()
	before := store.allocator.Usage()
	require.GreaterOrEqual(t, before.RecoveryUsed, physical)
	root := store.root
	require.NoError(t, store.Close())
	store, err = openTestRecordSpool(t, root)
	require.NoError(t, err)
	recoveryFixturePolicy(t, store)
	c = NewRecoveryCoordinator(store, gateway, nil)
	for range 16 {
		if c.Ready() {
			break
		}
		_, err = c.Step(context.Background())
		require.NoError(t, err)
	}
	require.True(t, c.Ready())
	restored := store.allocator.Usage()
	require.Equal(t, before.RecoveryReserve, restored.RecoveryReserve)
	require.Equal(t, before.Floor, restored.Floor)
	require.Equal(t, 1, restored.ActiveRecoveries)
	require.Equal(t, physical, retainedBytes(), "inventory changed retained evidence before replay")
	require.GreaterOrEqual(t, restored.RecoveryUsed, physical, "restored grant omitted retained recovery bytes")
	require.Zero(t, store.recoveryInventoryBytes, "temporary inventory ownership was not transferred")
	driveRecoveryTo(t, c, "register")
	control = c.operation().handles.Controls[0]
	replayed, err := recoveryFixtureDeliverControl(t, c, control, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	require.NoError(t, err)
	require.Len(t, replayed, len(frames))
	for i := range frames {
		require.Equal(t, frames[i].RecordBytes, replayed[i].RecordBytes)
	}
	require.Equal(t, uint64(2), control.Resolved())
	driveRecoveryTo(t, c, "coverage")
}
