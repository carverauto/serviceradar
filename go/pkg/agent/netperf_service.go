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
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/netperf"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	gproto "google.golang.org/protobuf/proto"
)

const (
	defaultNetperfOnDemandDeadline = 75 * time.Second
	maxNetperfOnDemandDeadline     = 120 * time.Second
	defaultNetperfResponderRetry   = 5 * time.Second
	maxPendingNetperfSamples       = 1024
	maxScheduledNetperfBusyRetries = 3
	netperfSchedYieldDelay         = 5 * time.Second
)

var (
	errNetperfInvalidPayload = errors.New("invalid netperf.run payload")
)

type netperfSampleKind int

const (
	netperfSampleTest netperfSampleKind = iota
	netperfSampleResponderStats
)

type netperfSample struct {
	Kind           netperfSampleKind
	Timestamp      int64
	Result         *netperf.TestResult
	PermitID       string
	TargetAddress  string
	ResponderStats netperf.ResponderSnapshot
}

type netperfRunPayload struct {
	PermitID         string `json:"permit_id"`
	ResponderAgentID string `json:"responder_agent_id"`
	TargetAddress    string `json:"target_address"`
	TargetPort       uint32 `json:"target_port"`
	Protocol         string `json:"protocol"`
	Direction        string `json:"direction"`
	BandwidthBps     uint64 `json:"bandwidth_bps"`
	DurationSec      uint32 `json:"duration_sec"`
	OmitSec          uint32 `json:"omit_sec"`
	Parallel         uint32 `json:"parallel"`
	PacketLength     uint32 `json:"packet_length"`
	ExecutionSource  string `json:"execution_source"`
	PermitB64        string `json:"permit_b64"`
}

// NetperfServiceConfig configures the agent's embedded Hub Responder and Spoke Sender.
type NetperfServiceConfig struct {
	AgentID        string
	PartitionID    string
	Logger         logger.Logger
	TrustSnapshot  func() *edgerecord.TrustSnapshot
	SecurityConfig func() *models.SecurityConfig
	MTLSProvider   func() *srgrpc.MTLSProvider
	Now            func() time.Time
	RunSender      func(ctx context.Context, req netperf.TestRequest) (*netperf.TestResult, error)
	StartResponder func(ctx context.Context, cfg netperf.ResponderConfig) (*netperf.Responder, error)
}

type activeNetperfResponderSpec struct {
	enabled               bool
	listenPort            uint32
	udpEnabled            bool
	maxConcurrentSessions uint32
	maxTotalBandwidthBps  uint64
	minAuthorityEpoch     uint64
}

type scheduledNetperfTarget struct {
	key         string
	assignment  *netperfpb.NetperfTargetAssignment
	interval    time.Duration
	nextRun     time.Time
	busyRetries int
}

type dueNetperfTarget struct {
	key        string
	req        netperf.TestRequest
	permitID   string
	targetAddr string
}

// NetperfService manages the opt-in Hub Responder listener, deterministic
// hash-spread scheduled Spoke tests, and preempting on-demand netperf.run tests.
type NetperfService struct {
	mu             sync.Mutex
	agentID        string
	partitionID    string
	logger         logger.Logger
	trustFn        func() *edgerecord.TrustSnapshot
	securityFn     func() *models.SecurityConfig
	mtlsFn         func() *srgrpc.MTLSProvider
	nowFn          func() time.Time
	runSenderFn    func(ctx context.Context, req netperf.TestRequest) (*netperf.TestResult, error)
	startRespFn    func(ctx context.Context, cfg netperf.ResponderConfig) (*netperf.Responder, error)
	responder      *netperf.Responder
	activeSpec     activeNetperfResponderSpec
	desiredResp    *netperfpb.NetperfResponderConfig
	respRetryAt    time.Time
	respRetryDelay time.Duration
	targets        []*scheduledNetperfTarget
	schedulerCtx   context.Context
	schedCancel    context.CancelFunc
	schedRunning   bool
	schedWake      chan struct{}
	schedDone      chan struct{}

	// Single-flight sender guard shared between scheduled and on-demand runs.
	senderMu           sync.Mutex
	onDemandActive     atomic.Bool
	activeSchedMu      sync.Mutex
	activeSchedCancel  context.CancelFunc
	activeSchedPreempt *atomic.Bool

	pendingMu      sync.Mutex
	pendingSamples []netperfSample
}

// NewNetperfService constructs a NetperfService ready for Start and ApplyConfig.
func NewNetperfService(cfg NetperfServiceConfig) *NetperfService {
	log := cfg.Logger
	if log == nil {
		log = logger.NewTestLogger()
	}
	nowFn := cfg.Now
	if nowFn == nil {
		nowFn = time.Now
	}
	svc := &NetperfService{
		agentID:        cfg.AgentID,
		partitionID:    cfg.PartitionID,
		logger:         log,
		trustFn:        cfg.TrustSnapshot,
		securityFn:     cfg.SecurityConfig,
		mtlsFn:         cfg.MTLSProvider,
		nowFn:          nowFn,
		runSenderFn:    cfg.RunSender,
		startRespFn:    cfg.StartResponder,
		respRetryDelay: defaultNetperfResponderRetry,
		schedWake:      make(chan struct{}, 1),
	}
	return svc
}

// Start launches the background scheduled-target executor loop.
func (s *NetperfService) Start(ctx context.Context) error {
	if s == nil {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}

	s.mu.Lock()
	if s.schedRunning {
		s.mu.Unlock()
		return nil
	}
	runCtx, cancel := context.WithCancel(ctx)
	s.schedulerCtx = runCtx
	s.schedCancel = cancel
	s.schedRunning = true
	s.schedDone = make(chan struct{})
	s.mu.Unlock()

	go s.runScheduler(runCtx, s.schedDone)
	return nil
}

// Stop cancels the scheduler loop and closes any active Hub Responder listener.
func (s *NetperfService) Stop(ctx context.Context) error {
	if s == nil {
		return nil
	}
	s.cancelActiveScheduled()

	s.mu.Lock()
	cancel := s.schedCancel
	done := s.schedDone
	running := s.schedRunning
	resp := s.responder
	s.responder = nil
	s.activeSpec = activeNetperfResponderSpec{}
	s.desiredResp = nil
	s.respRetryAt = time.Time{}
	s.targets = nil
	s.schedCancel = nil
	s.schedRunning = false
	s.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if resp != nil {
		if err := resp.Close(); err != nil {
			s.logger.Warn().Err(err).Msg("Failed to close netperf responder")
		}
	}
	if running && done != nil {
		if ctx == nil {
			ctx = context.Background()
		}
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// ApplyConfig dynamically reconciles the Hub Responder listener and scheduled
// outbound targets from AgentConfigResponse.NetperfConfig.
func (s *NetperfService) ApplyConfig(ctx context.Context, cfg *netperfpb.NetperfConfig) {
	if s == nil {
		return
	}
	if ctx == nil {
		ctx = context.Background()
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.desiredResp = gproto.CloneOf(cfg.GetResponder())
	s.reconcileResponderLocked(ctx, s.desiredResp)
	s.reconcileTargetsLocked(cfg.GetTargets())
	s.wakeScheduler()
}

// ReconcileResponder retries starting the Hub Responder when desired state is
// enabled and an earlier startup attempt failed transiently.
func (s *NetperfService) ReconcileResponder(ctx context.Context) {
	if s == nil {
		return
	}
	if ctx == nil {
		ctx = context.Background()
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.desiredResp == nil || !s.desiredResp.GetEnabled() {
		return
	}
	if s.responder != nil && s.activeSpec.enabled {
		return
	}
	s.reconcileResponderLocked(ctx, s.desiredResp)
}

func (s *NetperfService) reconcileResponderIfDue(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.desiredResp == nil || !s.desiredResp.GetEnabled() {
		return
	}
	if s.responder != nil && s.activeSpec.enabled {
		return
	}
	if !s.respRetryAt.IsZero() && s.nowFn().Before(s.respRetryAt) {
		return
	}
	s.reconcileResponderLocked(ctx, s.desiredResp)
}

func (s *NetperfService) effectiveResponderRetryDelay() time.Duration {
	if s.respRetryDelay > 0 {
		return s.respRetryDelay
	}
	return defaultNetperfResponderRetry
}

func (s *NetperfService) reconcileResponderLocked(ctx context.Context, cfg *netperfpb.NetperfResponderConfig) {
	if cfg == nil || !cfg.GetEnabled() {
		s.respRetryAt = time.Time{}
		if s.responder != nil {
			if err := s.responder.Close(); err != nil {
				s.logger.Warn().Err(err).Msg("Failed to stop netperf responder")
			}
			s.responder = nil
			s.activeSpec = activeNetperfResponderSpec{}
			s.logger.Info().Msg("Stopped netperf Hub Responder")
		}
		return
	}

	want := normalizeResponderSpec(cfg)
	if s.responder != nil &&
		s.activeSpec.enabled &&
		s.activeSpec.listenPort == want.listenPort &&
		s.activeSpec.udpEnabled == want.udpEnabled {
		s.respRetryAt = time.Time{}
		if s.activeSpec.maxConcurrentSessions != want.maxConcurrentSessions ||
			s.activeSpec.maxTotalBandwidthBps != want.maxTotalBandwidthBps ||
			s.activeSpec.minAuthorityEpoch != want.minAuthorityEpoch {
			s.responder.UpdateConfig(want.maxConcurrentSessions, want.maxTotalBandwidthBps, want.minAuthorityEpoch)
			s.activeSpec = want
			s.logger.Info().
				Uint32("listen_port", want.listenPort).
				Uint64("min_authority_epoch", want.minAuthorityEpoch).
				Uint32("max_concurrent_sessions", want.maxConcurrentSessions).
				Msg("Updated netperf Hub Responder limits in place")
		}
		return
	}

	if s.responder != nil {
		if err := s.responder.Close(); err != nil {
			s.logger.Warn().Err(err).Msg("Failed to close previous netperf responder")
		}
		s.responder = nil
		s.activeSpec = activeNetperfResponderSpec{}
	}

	var sec *models.SecurityConfig
	if s.securityFn != nil {
		sec = s.securityFn()
	}
	var provider *srgrpc.MTLSProvider
	if s.mtlsFn != nil {
		provider = s.mtlsFn()
	}

	respCfg := netperf.ResponderConfig{
		AgentID:               s.agentID,
		PartitionID:           defaultIfEmpty(s.partitionID, defaultPartition),
		ListenPort:            want.listenPort,
		UDPEnabled:            want.udpEnabled,
		MaxConcurrentSessions: want.maxConcurrentSessions,
		MaxTotalBandwidthBps:  want.maxTotalBandwidthBps,
		MinAuthorityEpoch:     want.minAuthorityEpoch,
		Security:              sec,
		MTLSProvider:          provider,
		KeyResolver:           netperf.TrustSnapshotKeyResolver{Snapshot: s.trustFn},
		Logger:                s.logger,
		Now:                   s.nowFn,
	}

	resp, err := s.startResponderInstance(ctx, respCfg)
	if err != nil {
		s.respRetryAt = s.nowFn().Add(s.effectiveResponderRetryDelay())
		s.logger.Error().
			Err(err).
			Uint32("listen_port", want.listenPort).
			Bool("udp_enabled", want.udpEnabled).
			Msg("Failed to start netperf Hub Responder")
		return
	}

	s.responder = resp
	s.activeSpec = want
	s.respRetryAt = time.Time{}
	s.logger.Info().
		Uint32("listen_port", want.listenPort).
		Bool("udp_enabled", want.udpEnabled).
		Uint64("min_authority_epoch", want.minAuthorityEpoch).
		Msg("Started netperf Hub Responder")
}

func (s *NetperfService) startResponderInstance(ctx context.Context, cfg netperf.ResponderConfig) (*netperf.Responder, error) {
	if s.startRespFn != nil {
		return s.startRespFn(ctx, cfg)
	}
	resp, err := netperf.NewResponder(cfg)
	if err != nil {
		return nil, err
	}
	if err := resp.Start(ctx); err != nil {
		_ = resp.Close()
		return nil, err
	}
	return resp, nil
}

func normalizeResponderSpec(cfg *netperfpb.NetperfResponderConfig) activeNetperfResponderSpec {
	port := cfg.GetListenPort()
	if port == 0 {
		port = netperf.DefaultPort
	}
	maxSess := cfg.GetMaxConcurrentSessions()
	if maxSess == 0 {
		maxSess = netperf.DefaultMaxConcurrentSessions
	}
	maxBw := cfg.GetMaxTotalBandwidthBps()
	if maxBw == 0 {
		maxBw = netperf.DefaultMaxTotalBandwidthBps
	}
	minEpoch := cfg.GetMinAuthorityEpoch()
	if minEpoch == 0 {
		minEpoch = 1
	}
	return activeNetperfResponderSpec{
		enabled:               true,
		listenPort:            port,
		udpEnabled:            cfg.GetUdpEnabled(),
		maxConcurrentSessions: maxSess,
		maxTotalBandwidthBps:  maxBw,
		minAuthorityEpoch:     minEpoch,
	}
}

func (s *NetperfService) reconcileTargetsLocked(rawTargets []*netperfpb.NetperfTargetAssignment) {
	existing := make(map[string]*scheduledNetperfTarget, len(s.targets))
	for _, t := range s.targets {
		existing[t.key] = t
	}

	now := s.nowFn()
	nextTargets := make([]*scheduledNetperfTarget, 0, len(rawTargets))
	for _, t := range rawTargets {
		if t == nil || t.GetPolicyId() == "" || t.GetResponderAgentId() == "" || t.GetTargetAddress() == "" || t.GetPermit() == nil {
			continue
		}
		intervalSec := t.GetIntervalSeconds()
		if intervalSec == 0 {
			intervalSec = netperf.DefaultIntervalSeconds
		} else if intervalSec < netperf.MinIntervalSeconds {
			intervalSec = netperf.MinIntervalSeconds
		}
		interval := time.Duration(intervalSec) * time.Second
		key := fmt.Sprintf("%s:%s:%s:%d:%s",
			t.GetPolicyId(), t.GetResponderAgentId(), t.GetProfileId(), intervalSec, t.GetPermit().GetPermitId())

		if prev, ok := existing[key]; ok {
			prev.assignment = t
			prev.interval = interval
			nextTargets = append(nextTargets, prev)
			continue
		}

		nextRun := nextAlignedNetperfSlot(now, t.GetPolicyId(), t.GetResponderAgentId(), s.agentID, intervalSec)
		nextTargets = append(nextTargets, &scheduledNetperfTarget{
			key:        key,
			assignment: t,
			interval:   interval,
			nextRun:    nextRun,
		})
	}
	s.targets = nextTargets
}

// netperfSlotOffset computes the deterministic SHA-256 hash-spread offset for
// a (policy_id, responder_agent_id, sender_agent_id) tuple within intervalSec.
func netperfSlotOffset(policyID, responderAgentID, senderAgentID string, intervalSec uint32) time.Duration {
	if intervalSec == 0 {
		return 0
	}
	sum := sha256.Sum256([]byte(policyID + ":" + responderAgentID + ":" + senderAgentID))
	val := binary.BigEndian.Uint64(sum[:8])
	return time.Duration(val%uint64(intervalSec)) * time.Second
}

func nextAlignedNetperfSlot(now time.Time, policyID, responderAgentID, senderAgentID string, intervalSec uint32) time.Time {
	if intervalSec < netperf.MinIntervalSeconds {
		intervalSec = netperf.MinIntervalSeconds
	}
	interval := time.Duration(intervalSec) * time.Second
	slot := netperfSlotOffset(policyID, responderAgentID, senderAgentID, intervalSec)
	windowStart := now.UTC().Truncate(interval).Add(slot)
	if !windowStart.After(now.UTC()) {
		return windowStart.Add(interval)
	}
	return windowStart
}

func (s *NetperfService) wakeScheduler() {
	select {
	case s.schedWake <- struct{}{}:
	default:
	}
}

func (s *NetperfService) runScheduler(ctx context.Context, done chan struct{}) {
	defer close(done)

	for {
		s.reconcileResponderIfDue(ctx)
		due, waitDur := s.nextDueTarget()
		if due == nil {
			var timer *time.Timer
			var timerCh <-chan time.Time
			if waitDur > 0 {
				timer = time.NewTimer(waitDur)
				timerCh = timer.C
			}
			select {
			case <-ctx.Done():
				if timer != nil {
					timer.Stop()
				}
				return
			case <-s.schedWake:
				if timer != nil {
					timer.Stop()
				}
			case <-timerCh:
			}
			continue
		}

		if s.onDemandActive.Load() {
			s.deferTarget(due.key, netperfSchedYieldDelay)
			continue
		}

		s.senderMu.Lock()
		budget := testExecutionBudget(due.req.Direction, due.req.DurationSec, due.req.OmitSec)
		schedCtx, schedCancel := context.WithTimeout(ctx, budget)
		preempted := &atomic.Bool{}
		s.setActiveSched(schedCancel, preempted)
		if s.onDemandActive.Load() {
			s.clearActiveSched(schedCancel)
			schedCancel()
			s.senderMu.Unlock()
			s.deferTarget(due.key, netperfSchedYieldDelay)
			continue
		}

		res, runErr := s.executeSender(schedCtx, due.req)

		wasPreempted := preempted.Load()
		schedCanceled := errors.Is(schedCtx.Err(), context.Canceled)
		s.clearActiveSched(schedCancel)
		schedCancel()
		s.senderMu.Unlock()

		// If preempted by an on-demand command or shutdown, yield without recording a false failure.
		if ctx.Err() != nil {
			return
		}
		if wasPreempted && runErr != nil && (errors.Is(runErr, context.Canceled) || status.Code(runErr) == codes.Canceled || schedCanceled) {
			s.deferTarget(due.key, netperfSchedYieldDelay)
			continue
		}

		if res != nil && res.BusyExhausted {
			s.handleScheduledBusy(due.key, res.RetryAfterMs)
			continue
		}

		s.advanceTargetNextSlot(due.key)
		s.enqueueSample(netperfSample{
			Kind:          netperfSampleTest,
			Timestamp:     s.nowFn().UnixNano(),
			Result:        res,
			PermitID:      due.permitID,
			TargetAddress: due.targetAddr,
		})
	}
}

func (s *NetperfService) nextDueTarget() (*dueNetperfTarget, time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.nowFn()
	var respWait time.Duration
	if s.desiredResp != nil && s.desiredResp.GetEnabled() && (s.responder == nil || !s.activeSpec.enabled) {
		if !s.respRetryAt.IsZero() && s.respRetryAt.After(now) {
			respWait = s.respRetryAt.Sub(now)
		}
	}

	if len(s.targets) == 0 {
		return nil, respWait
	}
	var earliest *scheduledNetperfTarget
	for _, t := range s.targets {
		if earliest == nil || t.nextRun.Before(earliest.nextRun) {
			earliest = t
		}
	}
	if earliest == nil {
		return nil, respWait
	}
	if !earliest.nextRun.After(now) {
		req, permitID, targetAddr := assignmentToTestRequest(earliest.assignment)
		return &dueNetperfTarget{
			key:        earliest.key,
			req:        req,
			permitID:   permitID,
			targetAddr: targetAddr,
		}, 0
	}
	waitDur := earliest.nextRun.Sub(now)
	if respWait > 0 && respWait < waitDur {
		waitDur = respWait
	}
	return nil, waitDur
}

func (s *NetperfService) deferTarget(key string, delay time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.nowFn()
	for _, t := range s.targets {
		if t.key == key {
			t.nextRun = now.Add(delay)
			return
		}
	}
}

func (s *NetperfService) handleScheduledBusy(key string, retryAfterMs uint32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.nowFn()
	for _, t := range s.targets {
		if t.key != key {
			continue
		}
		if t.busyRetries < maxScheduledNetperfBusyRetries {
			t.busyRetries++
			delay := time.Duration(retryAfterMs) * time.Millisecond
			if delay < time.Duration(netperf.MinRetryAfterMs)*time.Millisecond {
				delay = time.Duration(netperf.MinRetryAfterMs) * time.Millisecond
			}
			t.nextRun = now.Add(delay)
			return
		}
		t.busyRetries = 0
		t.nextRun = now.Add(t.interval)
		return
	}
}

func (s *NetperfService) advanceTargetNextSlot(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.nowFn()
	for _, t := range s.targets {
		if t.key != key {
			continue
		}
		t.busyRetries = 0
		next := t.nextRun.Add(t.interval)
		for !next.After(now) {
			next = next.Add(t.interval)
		}
		t.nextRun = next
		return
	}
}

func (s *NetperfService) setActiveSched(cancel context.CancelFunc, preempted *atomic.Bool) {
	s.activeSchedMu.Lock()
	s.activeSchedCancel = cancel
	s.activeSchedPreempt = preempted
	s.activeSchedMu.Unlock()
}

func (s *NetperfService) clearActiveSched(_ context.CancelFunc) {
	s.activeSchedMu.Lock()
	s.activeSchedCancel = nil
	s.activeSchedPreempt = nil
	s.activeSchedMu.Unlock()
}

func (s *NetperfService) cancelActiveScheduled() {
	s.activeSchedMu.Lock()
	cancel := s.activeSchedCancel
	preempted := s.activeSchedPreempt
	s.activeSchedMu.Unlock()
	if preempted != nil {
		preempted.Store(true)
	}
	if cancel != nil {
		cancel()
	}
}

// TryAcquireOnDemand claims the exclusive on-demand netperf.run slot.
func (s *NetperfService) TryAcquireOnDemand() bool {
	return s.onDemandActive.CompareAndSwap(false, true)
}

// ReleaseOnDemand releases the exclusive on-demand netperf.run slot.
func (s *NetperfService) ReleaseOnDemand() {
	s.onDemandActive.Store(false)
	s.wakeScheduler()
}

// RunOnDemand preempts any active scheduled test and runs a single interactive
// netperf.run test under the single-flight sender guard.
func (s *NetperfService) RunOnDemand(
	ctx context.Context,
	payload netperfRunPayload,
	permit *netperfpb.NetperfPermitV1,
) (netperfSample, map[string]any, error) {
	s.cancelActiveScheduled()
	s.senderMu.Lock()
	defer s.senderMu.Unlock()

	protoEnum, dirEnum, err := parseNetperfProtocolAndDirection(payload.Protocol, payload.Direction)
	if err != nil {
		return netperfSample{}, nil, err
	}
	port := payload.TargetPort
	if port == 0 {
		port = netperf.DefaultPort
	}
	bw, durSec, omitSec, parallel, pktLen := netperf.ClampRequestParams(
		payload.BandwidthBps, payload.DurationSec, payload.OmitSec, payload.Parallel, payload.PacketLength,
	)

	req := netperf.TestRequest{
		TargetAddress:    payload.TargetAddress,
		TargetPort:       port,
		ResponderAgentID: payload.ResponderAgentID,
		PolicyID:         permit.GetPolicyId(),
		Protocol:         protoEnum,
		Direction:        dirEnum,
		BandwidthBps:     bw,
		DurationSec:      durSec,
		OmitSec:          omitSec,
		Parallel:         parallel,
		PacketLength:     pktLen,
		ExecutionSource:  netperfpb.NetperfExecutionSource_NETPERF_EXECUTION_SOURCE_ON_DEMAND,
		Permit:           permit,
	}

	budget := testExecutionBudget(req.Direction, req.DurationSec, req.OmitSec)
	runCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()

	res, runErr := s.executeSender(runCtx, req)
	nowNs := s.nowFn().UnixNano()
	sample := netperfSample{
		Kind:          netperfSampleTest,
		Timestamp:     nowNs,
		Result:        res,
		PermitID:      permit.GetPermitId(),
		TargetAddress: payload.TargetAddress,
	}
	summary := buildOnDemandNetperfSummary(payload, req, res)
	return sample, summary, runErr
}

func (s *NetperfService) executeSender(ctx context.Context, req netperf.TestRequest) (*netperf.TestResult, error) {
	if s.runSenderFn != nil {
		return s.runSenderFn(ctx, req)
	}
	var sec *models.SecurityConfig
	if s.securityFn != nil {
		sec = s.securityFn()
	}
	var provider *srgrpc.MTLSProvider
	if s.mtlsFn != nil {
		provider = s.mtlsFn()
	}
	sender, err := netperf.NewSender(netperf.SenderConfig{
		AgentID:      s.agentID,
		PartitionID:  defaultIfEmpty(s.partitionID, defaultPartition),
		Security:     sec,
		MTLSProvider: provider,
		Logger:       s.logger,
		Now:          s.nowFn,
	})
	if err != nil {
		return &netperf.TestResult{
			Available:        false,
			Error:            err.Error(),
			Target:           req.TargetAddress,
			ResponderAgentID: req.ResponderAgentID,
			ResponderLabel:   req.ResponderLabel,
			PolicyID:         req.PolicyID,
			ProfileID:        req.ProfileID,
			Protocol:         req.Protocol,
			Direction:        req.Direction,
			Parallel:         req.Parallel,
			ExecutionSource:  req.ExecutionSource,
		}, err
	}
	return sender.RunTest(ctx, req)
}

func (s *NetperfService) enqueueSample(sample netperfSample) {
	if sample.Kind == netperfSampleTest && sample.Result == nil {
		return
	}
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()

	s.pendingSamples = append(s.pendingSamples, sample)
	if over := len(s.pendingSamples) - maxPendingNetperfSamples; over > 0 {
		s.pendingSamples = append([]netperfSample(nil), s.pendingSamples[over:]...)
	}
}

// DrainSamples returns all queued completed test samples plus a current
// responder utilization snapshot when the Hub Responder is enabled.
func (s *NetperfService) DrainSamples() []netperfSample {
	if s == nil {
		return nil
	}

	s.pendingMu.Lock()
	out := slices.Clone(s.pendingSamples)
	s.pendingSamples = nil
	s.pendingMu.Unlock()

	s.mu.Lock()
	resp := s.responder
	enabled := s.activeSpec.enabled
	s.mu.Unlock()

	if enabled && resp != nil {
		out = append(out, netperfSample{
			Kind:           netperfSampleResponderStats,
			Timestamp:      s.nowFn().UnixNano(),
			ResponderStats: resp.SnapshotMetrics(),
		})
	}
	return out
}

func assignmentToTestRequest(t *netperfpb.NetperfTargetAssignment) (netperf.TestRequest, string, string) {
	port := t.GetTargetPort()
	if port == 0 {
		port = netperf.DefaultPort
	}
	bw, durSec, omitSec, parallel, pktLen := netperf.ClampRequestParams(
		t.GetBandwidthBps(), t.GetDurationSec(), t.GetOmitSec(), t.GetParallel(), t.GetPacketLength(),
	)
	req := netperf.TestRequest{
		TargetAddress:    t.GetTargetAddress(),
		TargetPort:       port,
		ResponderAgentID: t.GetResponderAgentId(),
		ResponderLabel:   t.GetResponderLabel(),
		PolicyID:         t.GetPolicyId(),
		ProfileID:        t.GetProfileId(),
		Protocol:         t.GetProtocol(),
		Direction:        t.GetDirection(),
		BandwidthBps:     bw,
		DurationSec:      durSec,
		OmitSec:          omitSec,
		Parallel:         parallel,
		PacketLength:     pktLen,
		ExecutionSource:  netperfpb.NetperfExecutionSource_NETPERF_EXECUTION_SOURCE_SCHEDULED_POLICY,
		Permit:           gproto.CloneOf(t.GetPermit()),
	}
	return req, t.GetPermit().GetPermitId(), t.GetTargetAddress()
}

func testExecutionBudget(dir netperfpb.NetperfDirection, durationSec, omitSec uint32) time.Duration {
	dur := time.Duration(durationSec) * time.Second
	if dir == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		dur *= 2
	}
	return dur + time.Duration(omitSec)*time.Second + 30*time.Second
}

func parseNetperfProtocolAndDirection(protoStr, dirStr string) (netperfpb.NetperfProtocol, netperfpb.NetperfDirection, error) {
	var p netperfpb.NetperfProtocol
	switch strings.ToLower(strings.TrimSpace(protoStr)) {
	case mtrProtocolTCP:
		p = netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP
	case mtrProtocolUDP:
		p = netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP
	default:
		return 0, 0, fmt.Errorf("%w: unsupported protocol %q", errNetperfInvalidPayload, protoStr)
	}

	var d netperfpb.NetperfDirection
	switch strings.ToLower(strings.TrimSpace(dirStr)) {
	case "upload":
		d = netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD
	case "download":
		d = netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD
	case "bidirectional":
		d = netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL
	default:
		return 0, 0, fmt.Errorf("%w: unsupported direction %q", errNetperfInvalidPayload, dirStr)
	}
	return p, d, nil
}

func buildOnDemandNetperfSummary(payload netperfRunPayload, req netperf.TestRequest, res *netperf.TestResult) map[string]any {
	out := map[string]any{
		"permit_id":          firstMetricNonEmpty(payload.PermitID, req.Permit.GetPermitId()),
		"responder_agent_id": req.ResponderAgentID,
		"target_address":     req.TargetAddress,
		"target_port":        req.TargetPort,
		"protocol":           strings.ToLower(strings.TrimSpace(payload.Protocol)),
		"direction":          strings.ToLower(strings.TrimSpace(payload.Direction)),
		"parallel":           req.Parallel,
		"execution_source":   "on_demand",
		"available":          false,
	}
	if res == nil {
		return out
	}
	out["available"] = res.Available
	if res.Error != "" {
		out["error"] = res.Error
	}
	if res.BusyExhausted {
		out["busy_exhausted"] = true
		out["retry_after_ms"] = res.RetryAfterMs
	}
	out["duration_seconds"] = res.Primary.DurationSeconds
	out["bytes_sent"] = res.Primary.BytesSent
	out["bytes_received"] = res.Primary.BytesReceived
	out["bits_per_second"] = res.Primary.BitsPerSecond
	out["packets_sent"] = res.Primary.PacketsSent
	out["packets_received"] = res.Primary.PacketsReceived
	out["packets_lost"] = res.Primary.PacketsLost
	out["loss_percent"] = res.Primary.LossPercent
	out["jitter_ms"] = res.Primary.JitterMs
	return out
}

func defaultIfEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
