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

package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	"github.com/carverauto/serviceradar/go/pkg/edge/admission"
	edgesender "github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/shirou/gopsutil/v3/disk"
)

// One bounded generation delivery session per lane is attempted each poll.
const (
	defaultEdgeRecordSenderPollInterval  = 30 * time.Second
	edgeRecordSenderRequestedByteCredits = 8 << 20 // 8 MiB
	edgeRecordSenderRequestedFrameCreds  = 256
	edgeRecordSenderSetupInitialBackoff  = time.Second
)

// Producer admission to the spool pauses once its ordinary bytes reach
// edgeSpoolHighWaterPercent of the allocator's ordinary ceiling and resumes once
// reclaim brings them down to edgeSpoolLowWaterPercent (M3.2). The gap above the
// high water keeps room below the hard ceiling for records already in flight.
const (
	edgeSpoolHighWaterPercent = 80
	edgeSpoolLowWaterPercent  = 50
)

// The spool budget the agent runs with until core delivers one in its config
// (AgentConfigResponse.edge_spool_max_bytes), equal to core's code default.
const defaultEdgeSpoolMaxBytes = 1 << 30

// runEdgeRecordSender drains the agent spool over a dedicated
// EdgeRecordIngestService.Stream mTLS connection: one concurrent worker per
// configured lane, for as long as ctx stays alive. It runs while the spool is
// open; a spool that did not open leaves nothing to send.
//
// The sender persists validated terminal dispositions before advancing its
// local resolved prefix, then reclaims a drained segment whose records are
// accepted or permanently rejected. Permanently rejected records are
// quarantined first, and each rejection code is logged once per run.
//
// A missing gateway address is a configuration error and stops the sender. Any
// other setup failure (security provider before its certificate files
// exist, client or sender construction) is retried with a doubling delay capped
// at the poll interval until setup succeeds or ctx ends.
func runEdgeRecordSender(ctx context.Context, cfg *agent.ServerConfig, sp *agent.RecordSpool, log logger.Logger) {
	if sp == nil {
		return
	}
	if sp.RetainedLegacyBytes() > 0 {
		log.Warn().Uint64("retained_legacy_bytes", sp.RetainedLegacyBytes()).Msg("Unsupported legacy edge storage retained; only bounded lanes are delivered")
	}
	var startup agent.RecordSpoolCursor
	for source, ok := sp.NextSource(&startup); ok; source, ok = sp.NextSource(&startup) {
		logEdgeSpoolRestart(source.Source.RestartResolution(), source.Identity, log)
	}
	esCfg := cfg.EdgeRecordSender
	if esCfg == nil {
		esCfg = &agent.EdgeRecordSenderConfig{}
	}

	addr := esCfg.GatewayAddr
	if addr == "" {
		addr = cfg.GatewayAddr
	}
	security := esCfg.Security
	if security == nil {
		security = cfg.GatewaySecurity
	}
	if addr == "" {
		log.Error().Msg("Edge record sender has no gateway address")
		return
	}
	spoolDir := cfg.EdgeRecordSpoolDir()

	interval := time.Duration(esCfg.PollInterval)
	if interval <= 0 {
		interval = defaultEdgeRecordSenderPollInterval
	}

	delay := min(edgeRecordSenderSetupInitialBackoff, interval)
	for {
		senders, closeSender, err := newEdgeRecordSenders(ctx, addr, security, sp, log)
		if err == nil {
			defer closeSender()
			log.Info().Str("addr", addr).Str("spool_dir", spoolDir).Dur("interval", interval).
				Msg("Edge record sender starting")
			pollEdgeRecordSenders(ctx, senders, interval, log)
			return
		}
		log.Warn().Err(err).Str("addr", addr).Dur("retry_in", delay).Msg("Edge record sender setup failed")
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay = min(2*delay, interval)
	}
}

// newEdgeRecordSenders builds finite lane workers over one shared connection. The returned
// close function releases the client and security provider.
func newEdgeRecordSenders(
	ctx context.Context,
	addr string,
	security *models.SecurityConfig,
	sp *agent.RecordSpool,
	log logger.Logger,
) ([]*edgeLaneSender, func(), error) {

	securityProvider, err := srgrpc.NewSecurityProvider(ctx, security, log)
	if err != nil {
		return nil, nil, fmt.Errorf("build edge record sender security provider: %w", err)
	}

	client, err := srgrpc.NewClient(ctx, srgrpc.ClientConfig{
		Address:          addr,
		SecurityProvider: securityProvider,
		Logger:           log,
	})
	if err != nil {
		_ = securityProvider.Close()
		return nil, nil, fmt.Errorf("dial edge record gateway: %w", err)
	}
	closeAll := func() {
		_ = client.Close()
		_ = securityProvider.Close()
	}

	var senders []*edgeLaneSender
	for _, key := range sp.DeliveryLanes() {
		senders = append(senders, &edgeLaneSender{store: sp, lane: key,
			client: edgev1.NewEdgeRecordIngestServiceClient(client.GetConnection()),
			grants: gatewayGrantRenewer{client: proto.NewAgentGatewayServiceClient(client.GetConnection())}})
	}
	return senders, closeAll, nil
}

// edgeLaneSender visits at most 64 generations of its lane per tick. Independent
// lane workers keep a stalled bulk stream from holding recovery delivery.
type edgeLaneSender struct {
	store   *agent.RecordSpool
	client  edgesender.StreamClient
	grants  gatewayGrantRenewer
	lane    spool.LaneKey
	ordinal uint64
}

func (s *edgeLaneSender) RunOnce(ctx context.Context) (edgesender.Result, error) {
	for visited := 0; visited < spool.MaxGenerationPage; visited++ {
		source, ok := s.store.NextLaneSource(s.lane, &s.ordinal)
		if !ok {
			s.ordinal = 0
			return edgesender.Result{}, edgesender.ErrNoUnresolvedRecords
		}
		result, err := s.runSource(ctx, source)
		if errors.Is(err, edgesender.ErrNoUnresolvedRecords) {
			continue
		}
		if err != nil {
			err = fmt.Errorf("generation %x lane %s/%s: %w", source.Identity.SpoolID,
				source.Identity.Lane.RouteProfile, source.Identity.Lane.TrafficClass, err)
		}
		return result, err
	}
	return edgesender.Result{}, edgesender.ErrNoUnresolvedRecords
}

func (s *edgeLaneSender) runSource(ctx context.Context, source agent.RecordSpoolSource) (edgesender.Result, error) {
	if generation, ok := source.Source.(*spool.Generation); ok {
		held, err := generation.RecoverySourceHeld()
		if err != nil {
			return edgesender.Result{}, err
		}
		if held {
			return edgesender.Result{}, edgesender.ErrNoUnresolvedRecords
		}
	}
	sender, err := edgesender.New(source.Source, s.client, edgesender.Config{
		SpoolID: source.Identity.SpoolID, RouteProfile: source.Identity.Lane.RouteProfile,
		TrafficClass:            source.Identity.Lane.TrafficClass,
		RequestedByteCredits:    edgeRecordSenderRequestedByteCredits,
		RequestedFrameCredits:   edgeRecordSenderRequestedFrameCreds,
		PersistAcknowledgements: true, Grants: s.grants,
	})
	if err != nil {
		return edgesender.Result{}, err
	}
	return sender.RunOnce(ctx)
}

type edgeRecordRunner interface {
	RunOnce(context.Context) (edgesender.Result, error)
}

// gatewayGrantRenewer asks the gateway the sender delivers to for delivery
// grants (RenewEdgeDeliveryGrants), over the same mTLS connection.
type gatewayGrantRenewer struct {
	client proto.AgentGatewayServiceClient
}

func (g gatewayGrantRenewer) RenewDeliveryGrants(
	ctx context.Context, spoolID []byte, records []spool.Record,
) (map[uint64]*edgev1.EdgeSignedCapabilityV1, error) {
	req := &proto.EdgeDeliveryGrantRequest{SpoolId: spoolID}
	for _, rec := range records {
		req.Records = append(req.Records, &proto.EdgeDeliveryGrantRecord{Sequence: rec.Sequence, RecordBytes: rec.Body})
	}
	resp, err := g.client.RenewEdgeDeliveryGrants(ctx, req, srgrpc.WithoutRetry())
	if err != nil {
		return nil, err
	}
	granted := make(map[uint64]*edgev1.EdgeSignedCapabilityV1, len(resp.GetResults()))
	for _, result := range resp.GetResults() {
		if capability := result.GetDeliveryCapability(); capability != nil {
			granted[result.GetSequence()] = capability
		}
	}
	return granted, nil
}

func pollEdgeRecordSenders(ctx context.Context, senders []*edgeLaneSender, interval time.Duration, log logger.Logger) {
	var workers sync.WaitGroup
	for _, sender := range senders {
		workers.Add(1)
		go func(s *edgeLaneSender) {
			defer workers.Done()
			pollEdgeRecordSender(ctx, s, interval, log)
		}(sender)
	}
	workers.Wait()
}

func pollEdgeRecordSender(ctx context.Context, s edgeRecordRunner, interval time.Duration, log logger.Logger) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runEdgeRecordSenderOnce(ctx, s, log)
		}
	}
}

func runEdgeRecordSenderOnce(ctx context.Context, s edgeRecordRunner, log logger.Logger) {
	runCtx, cancel := context.WithTimeout(ctx, defaultEdgeRecordSenderPollInterval)
	defer cancel()
	result, err := s.RunOnce(runCtx)
	if result.GrantRenewal != nil {
		log.Warn().Err(result.GrantRenewal).
			Msg("Edge record sender could not obtain delivery grants; records under lapsed authority stay unresolved")
	}
	if err != nil {
		if errors.Is(err, edgesender.ErrNoUnresolvedRecords) {
			return
		}
		var gap *edgesender.CoverageGapError
		if errors.As(err, &gap) {
			log.Error().Err(err).Uint64("gap_sequence", gap.Slot.Sequence).
				Uint64("resolved_through", gap.ResolvedThrough).
				Msg("Edge spool lane wedged; recovery coverage required; delivery cannot cross this generation gap")
		}
		// A failed run still reports the highest sequence it sent and how far
		// the gateway acknowledged: a run that never received a durability
		// ack must show a remote prefix below the entries it attempted.
		log.Warn().Err(err).
			Int("sent", len(result.Sent)).
			Uint64("highest_sent", highestSentSequence(result)).
			Uint64("remote_resolved_through", result.RemoteResolvedThrough).
			Msg("Edge record sender run failed")
		logPermanentRejections(result.Dispositions, log)
		return
	}

	log.Info().
		Int("sent", len(result.Sent)).
		Uint64("highest_sent", highestSentSequence(result)).
		Int("dispositions", len(result.Dispositions)).
		Uint64("remote_resolved_through", result.RemoteResolvedThrough).
		Msg("Edge record sender drained spool lane")
	logPermanentRejections(result.Dispositions, log)
}

// logPermanentRejections reports, once per gateway rejection code, the records
// a run saw rejected permanently. The spool quarantines them on reclaim; this
// is the operator's record of why.
func logPermanentRejections(dispositions []*edgev1.EdgeRecordDisposition, log logger.Logger) {
	counts := map[string]int{}
	var codes []string
	for _, d := range dispositions {
		if d.GetKind() != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT {
			continue
		}
		if counts[d.GetRejectionCode()] == 0 {
			codes = append(codes, d.GetRejectionCode())
		}
		counts[d.GetRejectionCode()]++
	}
	for _, code := range codes {
		log.Warn().
			Str("rejection_code", code).
			Int("records", counts[code]).
			Msg("Edge record gateway rejected records permanently; they move to local spool quarantine")
	}
}

// highestSentSequence is the last sequence a run sent, or 0 when it sent
// none. The sender appends sequences in spool order.
func highestSentSequence(result edgesender.Result) uint64 {
	if n := len(result.Sent); n > 0 {
		return result.Sent[n-1]
	}
	return 0
}

// attachEdgeSpoolMetrics publishes unresolved spool bytes, oldest record age,
// the quarantine of permanently rejected records and whether producer admission
// is paused through the agent's Prometheus exporter. The sampler only reads
// record headers and quarantine entry sizes, so a scrape of a large backlog never
// loads a body.
func attachEdgeSpoolMetrics(server *agent.Server, sp *agent.RecordSpool, gate *admission.Gate) {
	if server == nil || sp == nil {
		return
	}
	server.SetEdgeSpoolSampler(func(now time.Time) (agent.EdgeSpoolHealth, bool) {
		health, q, _, err := sampleRecordSpool(sp, now)
		if err != nil {
			return agent.EdgeSpoolHealth{}, false
		}
		return agent.EdgeSpoolHealth{
			UnresolvedBytes:     health.UnresolvedBytes,
			OldestUnresolvedAge: health.OldestUnresolvedAge,
			ReportAge:           health.ReportAge,
			QuarantinedRecords:  q.Records,
			QuarantinedBytes:    q.Bytes,
			PermanentRejections: q.Quarantined + q.Dropped,
			QuarantineEvicted:   q.Evicted,
			QuarantineDropped:   q.Dropped,
			AdmissionPaused:     gate.BulkPaused(),
		}, true
	})
}

// openEdgeRecordSpool is called once for the process; producer and sender share
// bounded lane owner, byte allocator and admission gate. Every ordinary
// producer emits bulk records, so the gate's bulk
// hysteresis governs sweeps and metrics alike, and between the marks the gate
// shares the room byte-fairly across the producers' admission flows: a refused
// append is a retryable admission refusal, which each producer defers.
//
// The spool lives in cfg.EdgeRecordSpoolDir() and starts on the default byte
// budget; the returned budget applies the one core delivers.
func openEdgeRecordSpool(cfg *agent.ServerConfig) (*agent.RecordSpool, *admission.Gate, *edgeSpoolBudget, error) {
	dir := cfg.EdgeRecordSpoolDir()
	footprint := spool.DefaultRecoveryFootprint()
	if err := footprint.ValidateCoordinator(); err != nil {
		return nil, nil, nil, err
	}
	allocator, err := spool.NewAllocator(spool.AllocatorConfig{
		Capacity: defaultEdgeSpoolMaxBytes, MinFree: 1 << 20, MaxConcurrentRecoveries: 1,
		Recovery: footprint,
		FreeBytes: func() (uint64, error) {
			usage, err := disk.Usage(dir)
			if err != nil {
				return 0, err
			}
			return usage.Free, nil
		},
	})
	if err != nil {
		return nil, nil, nil, fmt.Errorf("edge spool capacity: %w", err)
	}
	high, low := edgeSpoolWatermarks(allocator)
	gate, err := admission.NewGate(high, low, func() uint64 { return allocator.Usage().OrdinaryUsed })
	if err != nil {
		return nil, nil, nil, fmt.Errorf("edge spool admission gate: %w", err)
	}
	sp, err := agent.OpenRecordSpool(dir, allocator,
		spool.WithAdmissionGate(func(flow string, cost uint64) bool {
			return gate.AdmitFlow(flow, cost, time.Now()) == admission.Admit
		}))
	if err != nil {
		return nil, nil, nil, err
	}
	return sp, gate, &edgeSpoolBudget{allocator: allocator, gate: gate}, nil
}

// edgeSpoolWatermarks are the admission gate's pause and resume marks for the
// allocator's current ordinary ceiling.
func edgeSpoolWatermarks(allocator *spool.Allocator) (high, low uint64) {
	ceiling := allocator.Usage().OrdinaryCeiling
	return ceiling / 100 * edgeSpoolHighWaterPercent, ceiling / 100 * edgeSpoolLowWaterPercent
}

// edgeSpoolBudget applies core's spool byte budget at admission: the
// allocator's hard ceiling and the gate's marks move together. A budget below
// current usage only refuses new appends until reclaim drains the spool under
// it; nothing already spooled is dropped.
type edgeSpoolBudget struct {
	allocator *spool.Allocator
	gate      *admission.Gate
}

func (b *edgeSpoolBudget) Apply(maxBytes uint64) error {
	if err := b.allocator.SetCapacity(maxBytes); err != nil {
		return err
	}
	high, low := edgeSpoolWatermarks(b.allocator)
	return b.gate.SetWatermarks(high, low)
}

// Log a bounded sample and an explicit remainder; no coverage slot vanishes
// silently from diagnostics when an outage creates many gaps.
func logEdgeSpoolRestart(resolution spool.Resolution, identity spool.GenerationIdentity, log logger.Logger) {
	count := 0
	for _, slot := range resolution.Slots {
		if !slot.EntersCoverage() {
			continue
		}
		count++
		if count <= spool.MaxHealthGapSequences {
			log.Error().Hex("spool_generation_id", identity.SpoolID).
				Str("route_profile", identity.Lane.RouteProfile.String()).Str("traffic_class", identity.Lane.TrafficClass.String()).
				Uint64("sequence", slot.Sequence).Str("outcome", slot.Outcome.String()).
				Bool("attributed", slot.Coverage.Attributed).Str("coverage_reason", slot.Coverage.Reason.String()).
				Msg("Edge spool restart slot requires recovery coverage")
		}
	}
	if count > 0 {
		log.Error().Int("coverage_slots", count).Int("reported_slots", min(count, spool.MaxHealthGapSequences)).
			Int("additional_slots", max(count-spool.MaxHealthGapSequences, 0)).
			Msg("Edge spool restart found coverage gaps; lane delivery cannot resolve past them")
	}
}

func edgeSpoolStatusSampler(sp *agent.RecordSpool, budget *edgeSpoolBudget) func() *proto.EdgeRecordSpoolStatus {
	return func() *proto.EdgeRecordSpoolStatus {
		usage := budget.allocator.Usage()
		status := &proto.EdgeRecordSpoolStatus{Available: true,
			BytesUsed: usage.OrdinaryUsed + usage.RecoveryUsed, BudgetBytes: usage.Capacity,
			AdmissionPaused: budget.gate.BulkPaused(), RetainedLegacyBytes: sp.RetainedLegacyBytes()}
		health, _, gaps, err := sampleRecordSpool(sp, time.Now())
		if err != nil {
			status.HealthError = err.Error()
			return status
		}
		status.HealthAvailable = true
		status.UnresolvedCount = health.UnresolvedCount
		status.UnresolvedBytes = health.UnresolvedBytes
		status.OldestUnresolvedAgeSeconds = uint64(health.OldestUnresolvedAge / time.Second)
		status.OldestUnresolvedAgeKnown = health.ReportAge
		status.GapCount = health.GapCount
		status.GenerationGaps = gaps
		status.Wedged = health.GapCount > 0
		return status
	}
}

// Counts and byte totals compose across namespaces; sequence values never do.
func sampleRecordSpool(store *agent.RecordSpool, now time.Time) (spool.Health, spool.QuarantineHealth, []*proto.EdgeRecordSpoolGap, error) {
	health := spool.Health{ReportAge: true}
	var quarantine spool.QuarantineHealth
	var gaps []*proto.EdgeRecordSpoolGap
	var cursor agent.RecordSpoolCursor
	for source, ok := store.NextSource(&cursor); ok; source, ok = store.NextSource(&cursor) {
		h, err := source.Source.Health(now)
		if err != nil {
			return spool.Health{}, quarantine, nil, err
		}
		q, err := source.Source.QuarantineHealth()
		if err != nil {
			return spool.Health{}, quarantine, nil, err
		}
		health.UnresolvedCount += h.UnresolvedCount
		health.UnresolvedBytes += h.UnresolvedBytes
		health.OldestUnresolvedAge = max(health.OldestUnresolvedAge, h.OldestUnresolvedAge)
		health.ReportAge = health.ReportAge && h.ReportAge
		health.GapCount += h.GapCount
		for _, sequence := range h.GapSequences {
			if len(gaps) == spool.MaxHealthGapSequences {
				break
			}
			gaps = append(gaps, &proto.EdgeRecordSpoolGap{SpoolGenerationId: source.Identity.SpoolID,
				RouteProfile: source.Identity.Lane.RouteProfile, TrafficClass: source.Identity.Lane.TrafficClass, Sequence: sequence})
		}
		quarantine.Records += q.Records
		quarantine.Bytes += q.Bytes
		quarantine.Quarantined += q.Quarantined
		quarantine.Dropped += q.Dropped
		quarantine.Evicted += q.Evicted
	}
	return health, quarantine, gaps, nil
}
