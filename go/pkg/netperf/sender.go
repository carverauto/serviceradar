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

package netperf

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"golang.org/x/time/rate"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/certpolicy"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

const (
	defaultDialTimeout    = 10 * time.Second
	defaultRPCTimeout     = 10 * time.Second
	defaultMaxBusyRetries = 3
)

// SenderConfig configures an outbound-only Spoke Sender client.
type SenderConfig struct {
	AgentID        string
	PartitionID    string
	Security       *models.SecurityConfig
	MTLSProvider   *srgrpc.MTLSProvider
	PeerPolicy     *certpolicy.Store
	DialTimeout    time.Duration
	RPCTimeout     time.Duration
	MaxBusyRetries int
	Logger         logger.Logger
	DialContext    func(ctx context.Context, target string) (net.Conn, error)
	Now            func() time.Time
}

// TestRequest describes one active network performance test against a Hub Responder.
type TestRequest struct {
	TargetAddress    string
	TargetPort       uint32
	ResponderAgentID string
	ResponderLabel   string
	PolicyID         string
	ProfileID        string
	Protocol         netperfpb.NetperfProtocol
	Direction        netperfpb.NetperfDirection
	BandwidthBps     uint64
	DurationSec      uint32
	OmitSec          uint32
	Parallel         uint32
	PacketLength     uint32
	ExecutionSource  netperfpb.NetperfExecutionSource
	Permit           *netperfpb.NetperfPermitV1
}

// PhaseResult captures measured counters for a single upload or download phase.
type PhaseResult struct {
	Direction         netperfpb.NetperfDirection
	DurationSeconds   float64
	DurationNs        uint64
	BytesSent         uint64
	BytesReceived     uint64
	BitsPerSecond     float64
	PacketsSent       uint64
	PacketsReceived   uint64
	PacketsLost       uint64
	OutOfOrderPackets uint64
	LossPercent       float64
	JitterMs          float64
}

// TestResult captures the outcome of RunTest, including authoritative Responder
// counters merged at CloseSession.
type TestResult struct {
	Available        bool
	Error            string
	SessionID        []byte
	Target           string
	ResponderAgentID string
	ResponderLabel   string
	PolicyID         string
	ProfileID        string
	Protocol         netperfpb.NetperfProtocol
	Direction        netperfpb.NetperfDirection
	Parallel         uint32
	ExecutionSource  netperfpb.NetperfExecutionSource
	Primary          PhaseResult
	Upload           *PhaseResult
	Download         *PhaseResult
	RetryAfterMs     uint32
	BusyExhausted    bool
}

// Sender runs outbound-only mTLS TCP and single-port HMAC UDP tests against Hub Responders.
type Sender struct {
	cfg   SenderConfig
	log   logger.Logger
	nowFn func() time.Time
}

// NewSender validates cfg and constructs a Sender.
func NewSender(cfg SenderConfig) (*Sender, error) {
	if cfg.AgentID == "" || cfg.PartitionID == "" {
		return nil, fmt.Errorf("%w: agent_id and partition_id are required", ErrInvalidConfig)
	}
	if cfg.DialTimeout <= 0 {
		cfg.DialTimeout = defaultDialTimeout
	}
	if cfg.RPCTimeout <= 0 {
		cfg.RPCTimeout = defaultRPCTimeout
	}
	if cfg.MaxBusyRetries == 0 {
		cfg.MaxBusyRetries = defaultMaxBusyRetries
	}
	log := cfg.Logger
	if log == nil {
		log = logger.NewTestLogger()
	}
	nowFn := cfg.Now
	if nowFn == nil {
		nowFn = time.Now
	}
	return &Sender{
		cfg:   cfg,
		log:   log,
		nowFn: nowFn,
	}, nil
}

// RunTest dials the target Hub Responder over mTLS, executes the permitted test,
// merges authoritative CloseSession counters, and returns a populated TestResult.
func (s *Sender) RunTest(ctx context.Context, req TestRequest) (*TestResult, error) {
	if req.TargetAddress == "" || req.ResponderAgentID == "" {
		return nil, fmt.Errorf("%w: target_address and responder_agent_id are required", ErrInvalidRequest)
	}
	if req.Permit == nil {
		return nil, ErrPermitRequired
	}
	if req.Permit.GetResponderAgentId() != req.ResponderAgentID || req.Permit.GetSenderAgentId() != s.cfg.AgentID {
		return nil, ErrPermitScopeMismatch
	}
	if req.Protocol != netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP &&
		req.Protocol != netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP {
		return nil, fmt.Errorf("%w: unsupported protocol %v", ErrInvalidRequest, req.Protocol)
	}
	if req.Direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD &&
		req.Direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD &&
		req.Direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		return nil, fmt.Errorf("%w: unsupported direction %v", ErrInvalidRequest, req.Direction)
	}

	bw, durSec, omitSec, parallel, pktLen := ClampRequestParams(
		req.BandwidthBps, req.DurationSec, req.OmitSec, req.Parallel, req.PacketLength,
	)
	port := req.TargetPort
	if port == 0 {
		port = DefaultPort
	}
	target := net.JoinHostPort(req.TargetAddress, strconv.FormatUint(uint64(port), 10))

	result := &TestResult{
		Available:        false,
		Target:           target,
		ResponderAgentID: req.ResponderAgentID,
		ResponderLabel:   req.ResponderLabel,
		PolicyID:         req.PolicyID,
		ProfileID:        req.ProfileID,
		Protocol:         req.Protocol,
		Direction:        req.Direction,
		Parallel:         parallel,
		ExecutionSource:  req.ExecutionSource,
	}

	creds, ownedProvider, err := buildClientTransportCredentials(
		s.cfg.Security, s.cfg.MTLSProvider, s.cfg.PeerPolicy,
		req.ResponderAgentID, s.cfg.PartitionID, s.log,
	)
	if err != nil {
		result.Error = err.Error()
		return result, err
	}
	if ownedProvider != nil {
		defer func() { _ = ownedProvider.Close() }()
	}

	dialTarget := target
	dialOpts := []grpc.DialOption{
		grpc.WithTransportCredentials(creds),
		grpc.WithDefaultCallOptions(
			grpc.MaxCallRecvMsgSize(MaxGRPCMessageBytes),
			grpc.MaxCallSendMsgSize(MaxGRPCMessageBytes),
		),
	}
	if s.cfg.DialContext != nil {
		dialTarget = "passthrough:///" + target
		dialOpts = append(dialOpts, grpc.WithContextDialer(s.cfg.DialContext))
	}

	conn, err := grpc.NewClient(dialTarget, dialOpts...)
	if err != nil {
		result.Error = err.Error()
		return result, err
	}
	defer func() { _ = conn.Close() }()

	client := netperfpb.NewNetworkPerfPeerServiceClient(conn)

	openReq := &netperfpb.OpenSessionRequest{
		Permit:          req.Permit,
		Protocol:        req.Protocol,
		Direction:       req.Direction,
		BandwidthBps:    bw,
		DurationSec:     durSec,
		OmitSec:         omitSec,
		Parallel:        parallel,
		PacketLength:    pktLen,
		ExecutionSource: req.ExecutionSource,
	}

	openResp, retryMs, busyExhausted, err := s.openSessionWithRetry(ctx, client, openReq)
	if err != nil {
		result.Error = err.Error()
		result.RetryAfterMs = retryMs
		result.BusyExhausted = busyExhausted
		return result, err
	}

	sidRaw := openResp.GetSessionId()
	if len(sidRaw) != UDPSessionSize {
		err = fmt.Errorf("%w: invalid session_id length %d", ErrSessionRejected, len(sidRaw))
		result.Error = err.Error()
		return result, err
	}
	var sessionID [UDPSessionSize]byte
	copy(sessionID[:], sidRaw)
	result.SessionID = append([]byte(nil), sidRaw...)

	if req.Protocol == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP && len(openResp.GetUdpSessionKey()) != UDPKeySize {
		err = fmt.Errorf("%w: invalid udp_session_key length %d", ErrSessionRejected, len(openResp.GetUdpSessionKey()))
		result.Error = err.Error()
		s.bestEffortClose(client, sessionID[:], nil)
		return result, err
	}

	duration := time.Duration(durSec) * time.Second
	omitDuration := time.Duration(omitSec) * time.Second
	var upPhase, downPhase *PhaseResult
	var execErr error

	if req.Protocol == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP {
		upPhase, downPhase, execErr = s.runTCPSession(
			ctx, client, sessionID, req.Direction, bw, duration, omitDuration, parallel,
		)
	} else {
		udpPort := openResp.GetUdpPort()
		if udpPort == 0 {
			udpPort = port
		}
		upPhase, downPhase, execErr = s.runUDPSession(
			ctx, client, sessionID, openResp.GetUdpSessionKey(), req.TargetAddress, udpPort,
			req.Direction, bw, duration, omitDuration, parallel, pktLen,
		)
	}

	var senderSummary *netperfpb.TestSummary
	switch {
	case upPhase != nil && req.Direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
		senderSummary = phaseToProtoSummary(upPhase)
	case downPhase != nil && req.Direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
		senderSummary = phaseToProtoSummary(downPhase)
	case upPhase != nil || downPhase != nil:
		senderSummary = combineBidirectionalSummaries(phaseToProtoSummary(upPhase), phaseToProtoSummary(downPhase))
	}

	closeCtx, closeCancel := context.WithTimeout(context.Background(), s.cfg.RPCTimeout)
	closeResp, closeErr := client.CloseSession(closeCtx, &netperfpb.CloseSessionRequest{
		SessionId:     sessionID[:],
		SenderSummary: senderSummary,
	})
	closeCancel()

	if execErr != nil {
		result.Error = execErr.Error()
		return result, execErr
	}
	if closeErr != nil {
		result.Error = closeErr.Error()
		return result, closeErr
	}

	mergeCloseSessionResult(result, req.Direction, upPhase, downPhase, closeResp)
	result.Available = true
	return result, nil
}

func (s *Sender) bestEffortClose(client netperfpb.NetworkPerfPeerServiceClient, sid []byte, summary *netperfpb.TestSummary) {
	closeCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _ = client.CloseSession(closeCtx, &netperfpb.CloseSessionRequest{
		SessionId:     sid,
		SenderSummary: summary,
	})
}

func (s *Sender) openSessionWithRetry(
	ctx context.Context,
	client netperfpb.NetworkPerfPeerServiceClient,
	req *netperfpb.OpenSessionRequest,
) (*netperfpb.OpenSessionResponse, uint32, bool, error) {
	maxRetries := max(0, s.cfg.MaxBusyRetries)
	for attempt := 0; ; attempt++ {
		rpcTimeout := s.cfg.DialTimeout + s.cfg.RPCTimeout
		rpcCtx, cancel := context.WithTimeout(ctx, rpcTimeout)
		resp, err := client.OpenSession(rpcCtx, req)
		cancel()

		if err == nil && resp.GetAccepted() {
			return resp, 0, false, nil
		}

		isBusy, retryDelay := classifyBusyResponse(resp, err, attempt)
		if !isBusy {
			if err != nil {
				return nil, 0, false, err
			}
			return nil, 0, false, fmt.Errorf("%w: %s", ErrSessionRejected, resp.GetRejectReason())
		}

		jittered := applyRetryJitter(retryDelay)
		retryMs := uint32(jittered.Milliseconds())
		if attempt >= maxRetries {
			return nil, retryMs, true, fmt.Errorf("%w: %s", ErrResponderBusy, busyMessage(resp, err))
		}
		if deadline, hasDeadline := ctx.Deadline(); hasDeadline && !s.nowFn().Add(jittered).Before(deadline) {
			return nil, retryMs, true, fmt.Errorf("%w: %s", ErrResponderBusy, busyMessage(resp, err))
		}

		timer := time.NewTimer(jittered)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, 0, false, ctx.Err()
		case <-timer.C:
		}
	}
}

func classifyBusyResponse(resp *netperfpb.OpenSessionResponse, err error, attempt int) (bool, time.Duration) {
	if err != nil {
		st, ok := status.FromError(err)
		if !ok || st.Code() != codes.ResourceExhausted {
			return false, 0
		}
		for _, detail := range st.Details() {
			if info, ok := detail.(*errdetails.RetryInfo); ok && info.GetRetryDelay() != nil {
				return true, info.GetRetryDelay().AsDuration()
			}
		}
		if resp != nil && resp.GetRetryAfterMs() > 0 {
			return true, time.Duration(resp.GetRetryAfterMs()) * time.Millisecond
		}
		return true, fallbackBusyDelay(attempt)
	}
	if resp != nil && !resp.GetAccepted() && resp.GetRetryAfterMs() > 0 {
		return true, time.Duration(resp.GetRetryAfterMs()) * time.Millisecond
	}
	return false, 0
}

func fallbackBusyDelay(attempt int) time.Duration {
	delay := time.Duration(MinRetryAfterMs) * time.Millisecond
	for range min(attempt, 4) {
		delay *= 2
	}
	maxDelay := time.Duration(MaxRetryAfterMs) * time.Millisecond
	return min(delay, maxDelay)
}

func applyRetryJitter(base time.Duration) time.Duration {
	if base < 500*time.Millisecond {
		base = 500 * time.Millisecond
	}
	maxDelay := time.Duration(MaxRetryAfterMs) * time.Millisecond
	if base > maxDelay {
		base = maxDelay
	}
	var raw [8]byte
	factor := 1.0
	if _, err := rand.Read(raw[:]); err == nil {
		// [0.8, 1.2]
		unit := float64(binary.BigEndian.Uint64(raw[:])%1000) / 1000.0
		factor = 0.8 + 0.4*unit
	}
	jittered := time.Duration(float64(base) * factor)
	if jittered < 500*time.Millisecond {
		return 500 * time.Millisecond
	}
	if jittered > maxDelay {
		return maxDelay
	}
	return jittered
}

func busyMessage(resp *netperfpb.OpenSessionResponse, err error) string {
	if resp != nil && resp.GetRejectReason() != "" {
		return resp.GetRejectReason()
	}
	if err != nil {
		return err.Error()
	}
	return "responder busy"
}

func (s *Sender) runTCPSession(
	ctx context.Context,
	client netperfpb.NetworkPerfPeerServiceClient,
	sessionID [UDPSessionSize]byte,
	direction netperfpb.NetperfDirection,
	bandwidthBps uint64,
	duration time.Duration,
	omitDuration time.Duration,
	parallel uint32,
) (*PhaseResult, *PhaseResult, error) {
	var upPhase, downPhase *PhaseResult
	if direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD ||
		direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		res, err := s.runTCPUpload(ctx, client, sessionID, bandwidthBps, duration, omitDuration, parallel)
		if err != nil {
			return nil, nil, err
		}
		upPhase = res
	}
	if direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD ||
		direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		res, err := s.runTCPDownload(ctx, client, sessionID, duration, omitDuration, parallel)
		if err != nil {
			return upPhase, nil, err
		}
		downPhase = res
	}
	return upPhase, downPhase, nil
}

func (s *Sender) runTCPUpload(
	ctx context.Context,
	client netperfpb.NetworkPerfPeerServiceClient,
	sessionID [UDPSessionSize]byte,
	bandwidthBps uint64,
	duration time.Duration,
	omitDuration time.Duration,
	parallel uint32,
) (*PhaseResult, error) {
	bytesPerSec := float64(bandwidthBps) / 8.0
	chunkSize := tcpChunkSizeForBandwidth(bandwidthBps)
	burst := max(chunkSize, int(bytesPerSec/20.0))
	limiter := rate.NewLimiter(rate.Limit(bytesPerSec), burst)

	start := s.nowFn()
	testEnd := start.Add(duration)
	phaseCtx, cancel := context.WithDeadline(ctx, testEnd.Add(s.cfg.RPCTimeout))
	defer cancel()

	stats := &tcpPhaseStats{
		started:   true,
		startTime: start,
		omitEnd:   start.Add(omitDuration),
	}

	var wg sync.WaitGroup
	var errMu sync.Mutex
	var firstErr error
	setErr := func(err error) {
		if err == nil {
			return
		}
		errMu.Lock()
		if firstErr == nil {
			firstErr = err
			cancel()
		}
		errMu.Unlock()
	}

	paceCtx, paceCancel := context.WithDeadline(phaseCtx, testEnd)
	defer paceCancel()

	for i := range parallel {
		wg.Add(1)
		go func(streamIdx uint32) {
			defer wg.Done()

			stream, err := client.StreamTest(phaseCtx)
			if err != nil {
				setErr(err)
				return
			}

			buf := make([]byte, chunkSize)
			var seq uint64
			for s.nowFn().Before(testEnd) {
				if err := limiter.WaitN(paceCtx, len(buf)); err != nil {
					if phaseDone, fatalErr := classifyRateWaitError(ctx, nil, paceCtx, testEnd, s.nowFn(), err); phaseDone {
						break
					} else {
						setErr(fatalErr)
						return
					}
				}
				if ctx.Err() != nil {
					setErr(ctx.Err())
					return
				}
				if !s.nowFn().Before(testEnd) {
					break
				}
				seq++
				err := stream.Send(&netperfpb.TestStreamChunk{
					SessionId:   sessionID[:],
					StreamIndex: streamIdx,
					Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
					Data:        buf,
					Sequence:    seq,
				})
				if err != nil {
					setErr(err)
					return
				}
				stats.record(len(buf), omitDuration, s.nowFn())
			}

			if ctx.Err() != nil {
				setErr(ctx.Err())
				return
			}

			if err := stream.Send(&netperfpb.TestStreamChunk{
				SessionId:   sessionID[:],
				StreamIndex: streamIdx,
				Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
				EndOfPhase:  true,
			}); err != nil {
				setErr(err)
				return
			}
			if err := stream.CloseSend(); err != nil {
				setErr(err)
				return
			}
			for {
				if _, recvErr := stream.Recv(); recvErr != nil {
					if errors.Is(recvErr, io.EOF) {
						break
					}
					setErr(recvErr)
					return
				}
			}
		}(i)
	}

	wg.Wait()
	if firstErr != nil {
		return nil, firstErr
	}

	summary := stats.summary(true, duration-omitDuration)
	return protoSummaryToPhase(netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD, summary), nil
}

func (s *Sender) runTCPDownload(
	ctx context.Context,
	client netperfpb.NetworkPerfPeerServiceClient,
	sessionID [UDPSessionSize]byte,
	duration time.Duration,
	omitDuration time.Duration,
	parallel uint32,
) (*PhaseResult, error) {
	phaseCtx, cancel := context.WithDeadline(ctx, s.nowFn().Add(duration+s.cfg.RPCTimeout))
	defer cancel()

	var stats tcpPhaseStats
	var wg sync.WaitGroup
	var errMu sync.Mutex
	var firstErr error
	setErr := func(err error) {
		if err == nil {
			return
		}
		errMu.Lock()
		if firstErr == nil {
			firstErr = err
			cancel()
		}
		errMu.Unlock()
	}

	for i := range parallel {
		wg.Add(1)
		go func(streamIdx uint32) {
			defer wg.Done()

			stream, err := client.StreamTest(phaseCtx)
			if err != nil {
				setErr(err)
				return
			}
			if err := stream.Send(&netperfpb.TestStreamChunk{
				SessionId:   sessionID[:],
				StreamIndex: streamIdx,
				Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
				EndOfPhase:  true,
			}); err != nil {
				setErr(err)
				return
			}
			if err := stream.CloseSend(); err != nil {
				setErr(err)
				return
			}
			for {
				chunk, recvErr := stream.Recv()
				if errors.Is(recvErr, io.EOF) {
					break
				}
				if recvErr != nil {
					setErr(recvErr)
					return
				}
				if n := len(chunk.GetData()); n > 0 {
					stats.record(n, omitDuration, s.nowFn())
				} else {
					stats.record(0, omitDuration, s.nowFn())
				}
				if chunk.GetEndOfPhase() {
					break
				}
			}
		}(i)
	}

	wg.Wait()
	if firstErr != nil {
		return nil, firstErr
	}

	summary := stats.summary(false, duration-omitDuration)
	return protoSummaryToPhase(netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD, summary), nil
}

func phaseToProtoSummary(p *PhaseResult) *netperfpb.TestSummary {
	if p == nil {
		return nil
	}
	return &netperfpb.TestSummary{
		DurationSeconds:   p.DurationSeconds,
		DurationNs:        p.DurationNs,
		BytesSent:         p.BytesSent,
		BytesReceived:     p.BytesReceived,
		BitsPerSecond:     p.BitsPerSecond,
		PacketsSent:       p.PacketsSent,
		PacketsReceived:   p.PacketsReceived,
		PacketsLost:       p.PacketsLost,
		OutOfOrderPackets: p.OutOfOrderPackets,
		LossPercent:       p.LossPercent,
		JitterMs:          p.JitterMs,
	}
}

func protoSummaryToPhase(dir netperfpb.NetperfDirection, sum *netperfpb.TestSummary) *PhaseResult {
	if sum == nil {
		return &PhaseResult{Direction: dir}
	}
	return &PhaseResult{
		Direction:         dir,
		DurationSeconds:   sum.GetDurationSeconds(),
		DurationNs:        sum.GetDurationNs(),
		BytesSent:         sum.GetBytesSent(),
		BytesReceived:     sum.GetBytesReceived(),
		BitsPerSecond:     sum.GetBitsPerSecond(),
		PacketsSent:       sum.GetPacketsSent(),
		PacketsReceived:   sum.GetPacketsReceived(),
		PacketsLost:       sum.GetPacketsLost(),
		OutOfOrderPackets: sum.GetOutOfOrderPackets(),
		LossPercent:       sum.GetLossPercent(),
		JitterMs:          sum.GetJitterMs(),
	}
}

func mergeCloseSessionResult(
	result *TestResult,
	dir netperfpb.NetperfDirection,
	localUp *PhaseResult,
	localDown *PhaseResult,
	closeResp *netperfpb.CloseSessionResponse,
) {
	if closeResp == nil {
		switch dir {
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
			if localUp != nil {
				result.Upload = localUp
				result.Primary = *localUp
			}
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
			if localDown != nil {
				result.Download = localDown
				result.Primary = *localDown
			}
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL:
			result.Upload = localUp
			result.Download = localDown
			if localUp != nil {
				result.Primary = *localUp
			}
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_UNSPECIFIED:
		}
		return
	}

	mergeUpload := func(local *PhaseResult, remote *netperfpb.TestSummary) *PhaseResult {
		merged := &PhaseResult{Direction: netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD}
		if local != nil {
			*merged = *local
		}
		if remote != nil {
			merged.BytesReceived = remote.GetBytesReceived()
			merged.PacketsReceived = remote.GetPacketsReceived()
			merged.PacketsLost = remote.GetPacketsLost()
			merged.OutOfOrderPackets = remote.GetOutOfOrderPackets()
			merged.LossPercent = remote.GetLossPercent()
			merged.JitterMs = remote.GetJitterMs()
			if remote.GetDurationSeconds() > 0 {
				merged.DurationSeconds = remote.GetDurationSeconds()
				merged.DurationNs = remote.GetDurationNs()
			}
			if remote.GetBitsPerSecond() > 0 || remote.GetBytesReceived() > 0 {
				merged.BitsPerSecond = remote.GetBitsPerSecond()
			}
		}
		return merged
	}

	mergeDownload := func(local *PhaseResult, remote *netperfpb.TestSummary) *PhaseResult {
		merged := &PhaseResult{Direction: netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD}
		if local != nil {
			*merged = *local
		}
		if remote != nil {
			if remote.GetBytesSent() > 0 {
				merged.BytesSent = remote.GetBytesSent()
			}
			if remote.GetPacketsSent() > 0 {
				merged.PacketsSent = remote.GetPacketsSent()
				if merged.PacketsReceived <= merged.PacketsSent {
					merged.PacketsLost = merged.PacketsSent - merged.PacketsReceived
					if merged.PacketsSent > 0 {
						merged.LossPercent = (float64(merged.PacketsLost) * 100.0) / float64(merged.PacketsSent)
					}
				}
			}
		}
		return merged
	}

	switch dir {
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
		rem := closeResp.GetUploadSummary()
		if rem == nil {
			rem = closeResp.GetResponderSummary()
		}
		result.Upload = mergeUpload(localUp, rem)
		result.Primary = *result.Upload
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
		rem := closeResp.GetDownloadSummary()
		if rem == nil {
			rem = closeResp.GetResponderSummary()
		}
		result.Download = mergeDownload(localDown, rem)
		result.Primary = *result.Download
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL:
		result.Upload = mergeUpload(localUp, closeResp.GetUploadSummary())
		result.Download = mergeDownload(localDown, closeResp.GetDownloadSummary())
		totalDur := result.Upload.DurationSeconds + result.Download.DurationSeconds
		var bps float64
		if totalDur > 0 {
			bps = (float64(result.Upload.BytesReceived+result.Download.BytesReceived) * 8.0) / totalDur
		}
		packetsSent := result.Upload.PacketsSent + result.Download.PacketsSent
		packetsLost := result.Upload.PacketsLost + result.Download.PacketsLost
		var lossPercent float64
		if packetsSent > 0 {
			lossPercent = (float64(packetsLost) * 100.0) / float64(packetsSent)
		}
		result.Primary = PhaseResult{
			Direction:         netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL,
			DurationSeconds:   totalDur,
			DurationNs:        result.Upload.DurationNs + result.Download.DurationNs,
			BytesSent:         result.Upload.BytesSent + result.Download.BytesSent,
			BytesReceived:     result.Upload.BytesReceived + result.Download.BytesReceived,
			BitsPerSecond:     bps,
			PacketsSent:       packetsSent,
			PacketsReceived:   result.Upload.PacketsReceived + result.Download.PacketsReceived,
			PacketsLost:       packetsLost,
			OutOfOrderPackets: result.Upload.OutOfOrderPackets + result.Download.OutOfOrderPackets,
			LossPercent:       lossPercent,
			JitterMs:          max(result.Upload.JitterMs, result.Download.JitterMs),
		}
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_UNSPECIFIED:
	}
}
