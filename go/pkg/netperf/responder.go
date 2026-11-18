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
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/time/rate"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"

	"github.com/carverauto/serviceradar/go/pkg/certpolicy"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

// ResponderConfig configures a Hub Responder instance.
type ResponderConfig struct {
	AgentID               string
	PartitionID           string
	ListenAddress         string
	ListenPort            uint32
	AllowEphemeralPort    bool
	UDPEnabled            bool
	MaxConcurrentSessions uint32
	MaxTotalBandwidthBps  uint64
	MinAuthorityEpoch     uint64
	Security              *models.SecurityConfig
	MTLSProvider          *srgrpc.MTLSProvider
	PeerPolicy            *certpolicy.Store
	KeyResolver           PermitKeyResolver
	Logger                logger.Logger
	Now                   func() time.Time
}

// Responder hosts the opt-in 5199/TCP mTLS NetworkPerfPeerService and optional
// single-port 5199/UDP HMAC-authenticated probe socket.
type Responder struct {
	netperfpb.UnimplementedNetworkPerfPeerServiceServer

	cfg           ResponderConfig
	log           logger.Logger
	nowFn         func() time.Time
	minEpoch      atomic.Uint64
	admission     *admissionController
	ownedProvider *srgrpc.MTLSProvider

	tcpListener net.Listener
	udpConn     *net.UDPConn
	udpPort     uint32
	grpcServer  *grpc.Server

	sessionsMu  sync.Mutex
	sessions    map[[UDPSessionSize]byte]*responderSession
	udpSessions map[[UDPSessionSize]byte]*responderSession

	stopCh    chan struct{}
	closeOnce sync.Once
	wg        sync.WaitGroup
}

type responderSession struct {
	id            [UDPSessionSize]byte
	senderAgentID string
	partitionID   string
	protocol      netperfpb.NetperfProtocol
	direction     netperfpb.NetperfDirection
	bandwidthBps  uint64
	duration      time.Duration
	omitDuration  time.Duration
	parallel      uint32
	packetLength  uint32
	deadline      time.Time

	ctx    context.Context
	cancel context.CancelFunc

	uploadPhase   tcpPhaseStats
	downloadPhase tcpPhaseStats

	downloadOnce    sync.Once
	downloadLimiter *rate.Limiter
	downloadStart   time.Time
	downloadOmitEnd time.Time
	downloadEnd     time.Time

	// UDP state
	udpKey          []byte
	udpTracker      *RFC3550Tracker
	udpMu           sync.Mutex
	hasLockedPeer   bool
	lockedPeerAddr  netip.AddrPort
	helloReady      chan struct{}
	helloOnce       sync.Once
	udpUploadStart  time.Time
	udpUploadEnd    time.Time
	udpUploadOnce   sync.Once
	udpEndCh        chan struct{}
	udpEndOnce      sync.Once
	udpDownloadSent atomic.Uint64
	udpDownloadByte atomic.Uint64
	udpDownStartNs  atomic.Int64
	udpDownEndNs    atomic.Int64
}

type tcpPhaseStats struct {
	mu          sync.Mutex
	started     bool
	startTime   time.Time
	omitEnd     time.Time
	firstSteady time.Time
	lastSteady  time.Time
	steadyBytes uint64
}

func (s *tcpPhaseStats) record(n int, omitDur time.Duration, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.started {
		s.started = true
		s.startTime = now
		s.omitEnd = now.Add(omitDur)
	}
	if n > 0 && !now.Before(s.omitEnd) {
		if s.firstSteady.IsZero() {
			s.firstSteady = now
		}
		s.lastSteady = now
		s.steadyBytes += uint64(n)
	}
}

func (s *tcpPhaseStats) summary(isSender bool, plannedSteady time.Duration) *netperfpb.TestSummary {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.started {
		return nil
	}
	dur := s.lastSteady.Sub(s.firstSteady)
	if s.steadyBytes > 0 && dur <= 0 {
		if plannedSteady > 0 {
			dur = plannedSteady
		} else {
			dur = time.Millisecond
		}
	}
	var bps float64
	if dur > 0 {
		bps = (float64(s.steadyBytes) * 8.0) / dur.Seconds()
	}
	out := &netperfpb.TestSummary{
		DurationSeconds: dur.Seconds(),
		DurationNs:      uint64(max(int64(0), dur.Nanoseconds())),
		BitsPerSecond:   bps,
	}
	if isSender {
		out.BytesSent = s.steadyBytes
	} else {
		out.BytesReceived = s.steadyBytes
	}
	return out
}

// NewResponder validates cfg and constructs a Responder ready to Start.
func NewResponder(cfg ResponderConfig) (*Responder, error) {
	if cfg.AgentID == "" || cfg.PartitionID == "" {
		return nil, fmt.Errorf("%w: agent_id and partition_id are required", ErrInvalidConfig)
	}
	if cfg.KeyResolver == nil {
		return nil, fmt.Errorf("%w: KeyResolver is required", ErrInvalidConfig)
	}
	if cfg.ListenPort == 0 && !cfg.AllowEphemeralPort {
		cfg.ListenPort = DefaultPort
	}
	if cfg.ListenPort > 65535 {
		return nil, fmt.Errorf("%w: invalid listen port %d", ErrInvalidConfig, cfg.ListenPort)
	}
	if cfg.MinAuthorityEpoch == 0 {
		cfg.MinAuthorityEpoch = 1
	}

	log := cfg.Logger
	if log == nil {
		log = logger.NewTestLogger()
	}
	nowFn := cfg.Now
	if nowFn == nil {
		nowFn = time.Now
	}

	r := &Responder{
		cfg:         cfg,
		log:         log,
		nowFn:       nowFn,
		admission:   newAdmissionController(cfg.MaxConcurrentSessions, cfg.MaxTotalBandwidthBps),
		sessions:    make(map[[UDPSessionSize]byte]*responderSession),
		udpSessions: make(map[[UDPSessionSize]byte]*responderSession),
		stopCh:      make(chan struct{}),
	}
	r.minEpoch.Store(cfg.MinAuthorityEpoch)
	return r, nil
}

// Start binds the mTLS TCP listener and optional single-port UDP socket and
// starts serving NetworkPerfPeerService.
func (r *Responder) Start(ctx context.Context) error {
	creds, owned, err := buildServerTransportCredentials(r.cfg.Security, r.cfg.MTLSProvider, r.cfg.PeerPolicy, r.log)
	if err != nil {
		return err
	}

	tcpAddr := net.JoinHostPort(r.cfg.ListenAddress, strconv.FormatUint(uint64(r.cfg.ListenPort), 10))
	lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", tcpAddr)
	if err != nil {
		if owned != nil {
			_ = owned.Close()
		}
		return fmt.Errorf("netperf listen tcp %s: %w", tcpAddr, err)
	}

	var udpConn *net.UDPConn
	var udpPort uint32
	if r.cfg.UDPEnabled {
		udpIP := net.ParseIP(r.cfg.ListenAddress)
		bindPort := int(r.cfg.ListenPort)
		if r.cfg.AllowEphemeralPort && r.cfg.ListenPort == 0 {
			bindPort = 0
		}
		udpAddr := &net.UDPAddr{IP: udpIP, Port: bindPort}
		conn, udpErr := net.ListenUDP("udp", udpAddr)
		if udpErr != nil {
			_ = lis.Close()
			if owned != nil {
				_ = owned.Close()
			}
			return fmt.Errorf("netperf listen udp %v: %w", udpAddr, udpErr)
		}
		udpConn = conn
		if localUDP, ok := conn.LocalAddr().(*net.UDPAddr); ok {
			udpPort = uint32(localUDP.Port)
		}
	}

	srv := grpc.NewServer(
		grpc.Creds(creds),
		grpc.MaxRecvMsgSize(MaxGRPCMessageBytes),
		grpc.MaxSendMsgSize(MaxGRPCMessageBytes),
	)
	netperfpb.RegisterNetworkPerfPeerServiceServer(srv, r)

	r.ownedProvider = owned
	r.tcpListener = lis
	r.udpConn = udpConn
	r.udpPort = udpPort
	r.grpcServer = srv

	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		if serveErr := srv.Serve(lis); serveErr != nil && !errors.Is(serveErr, grpc.ErrServerStopped) {
			r.log.Warn().Err(serveErr).Msg("Netperf gRPC responder exited with error")
		}
	}()

	if udpConn != nil {
		r.wg.Add(1)
		go r.serveUDP()
	}

	r.wg.Add(1)
	go r.reapLoop()

	r.log.Info().
		Str("tcp_addr", lis.Addr().String()).
		Uint32("udp_port", udpPort).
		Bool("udp_enabled", r.cfg.UDPEnabled).
		Uint64("min_authority_epoch", r.minEpoch.Load()).
		Msg("Started netperf Hub Responder")
	return nil
}

// UpdateConfig atomically updates admission limits and min_authority_epoch in place.
func (r *Responder) UpdateConfig(maxSessions uint32, maxTotalBandwidthBps uint64, minAuthorityEpoch uint64) {
	if r == nil {
		return
	}
	r.admission.updateLimits(maxSessions, maxTotalBandwidthBps)
	if minAuthorityEpoch == 0 {
		minAuthorityEpoch = 1
	}
	r.minEpoch.Store(minAuthorityEpoch)
}

// ListenAddr returns the bound TCP address, or empty if not started.
func (r *Responder) ListenAddr() string {
	if r == nil || r.tcpListener == nil {
		return ""
	}
	return r.tcpListener.Addr().String()
}

// UDPPort returns the bound UDP port, or 0 if UDP is disabled or not started.
func (r *Responder) UDPPort() uint32 {
	if r == nil {
		return 0
	}
	return r.udpPort
}

// SnapshotMetrics returns current Responder utilization counters and gauges.
func (r *Responder) SnapshotMetrics() ResponderSnapshot {
	if r == nil || r.admission == nil {
		return ResponderSnapshot{}
	}
	return r.admission.snapshot()
}

// Close gracefully stops the Responder, closing TCP/UDP sockets and releasing all sessions.
func (r *Responder) Close() error {
	if r == nil {
		return nil
	}
	r.closeOnce.Do(func() {
		close(r.stopCh)
		if r.udpConn != nil {
			_ = r.udpConn.Close()
		}
		if r.grpcServer != nil {
			done := make(chan struct{})
			go func() {
				r.grpcServer.GracefulStop()
				close(done)
			}()
			timer := time.NewTimer(2 * time.Second)
			select {
			case <-done:
				timer.Stop()
			case <-timer.C:
				r.grpcServer.Stop()
			}
		}
		if r.tcpListener != nil {
			_ = r.tcpListener.Close()
		}

		r.sessionsMu.Lock()
		for id, sess := range r.sessions {
			sess.cancel()
			r.admission.release(sess.bandwidthBps)
			delete(r.sessions, id)
			delete(r.udpSessions, id)
		}
		r.sessionsMu.Unlock()

		r.wg.Wait()
		if r.ownedProvider != nil {
			_ = r.ownedProvider.Close()
		}
	})
	return nil
}

// OpenSession verifies peer mTLS identity, NetperfPermitV1 signature/epoch/ceilings,
// and admission capacity before allocating a test session.
func (r *Responder) OpenSession(
	ctx context.Context,
	req *netperfpb.OpenSessionRequest,
) (*netperfpb.OpenSessionResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, ErrInvalidRequest.Error())
	}

	peerID, err := ExtractPeerIdentity(ctx)
	if err != nil {
		return nil, status.Error(codes.Unauthenticated, err.Error())
	}

	pktLen, err := ValidateRequestBounds(req)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}

	if req.GetProtocol() == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP && (!r.cfg.UDPEnabled || r.udpConn == nil) {
		return nil, status.Error(codes.FailedPrecondition, ErrUDPDisabled.Error())
	}

	err = VerifyPermit(
		req.GetPermit(),
		req,
		peerID,
		r.cfg.AgentID,
		r.cfg.PartitionID,
		r.minEpoch.Load(),
		r.nowFn(),
		r.cfg.KeyResolver,
	)
	if err != nil {
		return nil, status.Error(permitErrorCode(err), err.Error())
	}

	accepted, retryAfterMs, rejectReason := r.admission.tryAcquire(req.GetBandwidthBps())
	if !accepted {
		st := status.New(codes.ResourceExhausted, rejectReason)
		if detailed, detErr := st.WithDetails(&errdetails.RetryInfo{
			RetryDelay: durationpb.New(time.Duration(retryAfterMs) * time.Millisecond),
		}); detErr == nil {
			st = detailed
		}
		return &netperfpb.OpenSessionResponse{
			Accepted:     false,
			RetryAfterMs: retryAfterMs,
			RejectReason: rejectReason,
		}, st.Err()
	}

	var sessionID [UDPSessionSize]byte
	if _, err := rand.Read(sessionID[:]); err != nil {
		r.admission.release(req.GetBandwidthBps())
		return nil, status.Error(codes.Internal, "failed to allocate session id")
	}

	var udpKey []byte
	var udpPort uint32
	if req.GetProtocol() == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP {
		udpKey = make([]byte, UDPKeySize)
		if _, err := rand.Read(udpKey); err != nil {
			r.admission.release(req.GetBandwidthBps())
			return nil, status.Error(codes.Internal, "failed to allocate UDP session key")
		}
		udpPort = r.udpPort
	}

	duration := time.Duration(req.GetDurationSec()) * time.Second
	omitDuration := time.Duration(req.GetOmitSec()) * time.Second
	phaseMultiplier := time.Duration(1)
	if req.GetDirection() == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		phaseMultiplier = 2
	}
	deadline := r.nowFn().Add(duration*phaseMultiplier + omitDuration + 20*time.Second)

	sessCtx, sessCancel := context.WithDeadline(context.Background(), deadline)
	sess := &responderSession{
		id:            sessionID,
		senderAgentID: peerID.AgentID,
		partitionID:   peerID.PartitionID,
		protocol:      req.GetProtocol(),
		direction:     req.GetDirection(),
		bandwidthBps:  req.GetBandwidthBps(),
		duration:      duration,
		omitDuration:  omitDuration,
		parallel:      req.GetParallel(),
		packetLength:  pktLen,
		deadline:      deadline,
		ctx:           sessCtx,
		cancel:        sessCancel,
		udpKey:        udpKey,
		udpTracker:    &RFC3550Tracker{},
		helloReady:    make(chan struct{}),
		udpEndCh:      make(chan struct{}),
	}

	r.sessionsMu.Lock()
	r.sessions[sessionID] = sess
	if req.GetProtocol() == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP {
		r.udpSessions[sessionID] = sess
	}
	r.sessionsMu.Unlock()

	return &netperfpb.OpenSessionResponse{
		Accepted:      true,
		SessionId:     append([]byte(nil), sessionID[:]...),
		UdpSessionKey: udpKey,
		UdpPort:       udpPort,
	}, nil
}

// StreamTest handles one TCP upload/download worker stream or UDP download kickoff.
func (r *Responder) StreamTest(stream netperfpb.NetworkPerfPeerService_StreamTestServer) error {
	peerID, err := ExtractPeerIdentity(stream.Context())
	if err != nil {
		return status.Error(codes.Unauthenticated, err.Error())
	}

	firstChunk, err := stream.Recv()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return status.Error(codes.InvalidArgument, ErrInvalidStreamChunk.Error())
		}
		return err
	}

	sess, err := r.lookupAuthorizedSession(firstChunk.GetSessionId(), peerID)
	if err != nil {
		return err
	}

	switch firstChunk.GetPhase() {
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
		return r.handleStreamUpload(stream, sess, firstChunk)
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
		return r.handleStreamDownload(stream, sess, firstChunk)
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL,
		netperfpb.NetperfDirection_NETPERF_DIRECTION_UNSPECIFIED:
		return status.Error(codes.InvalidArgument, "unsupported stream phase")
	default:
		return status.Error(codes.InvalidArgument, "unsupported stream phase")
	}
}

func (r *Responder) handleStreamUpload(
	stream netperfpb.NetworkPerfPeerService_StreamTestServer,
	sess *responderSession,
	firstChunk *netperfpb.TestStreamChunk,
) error {
	if sess.protocol != netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP {
		return status.Error(codes.InvalidArgument, "StreamTest upload is only valid for TCP sessions")
	}
	if sess.direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD &&
		sess.direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		return status.Error(codes.PermissionDenied, "upload phase not permitted for session")
	}
	streamIdx := firstChunk.GetStreamIndex()
	if streamIdx >= sess.parallel {
		return status.Error(codes.InvalidArgument, "stream_index exceeds session parallel")
	}

	var lastSeq uint64
	processChunk := func(chunk *netperfpb.TestStreamChunk) (bool, error) {
		if len(chunk.GetSessionId()) != UDPSessionSize || !bytesEqualSession(chunk.GetSessionId(), sess.id) {
			return false, status.Error(codes.InvalidArgument, "mismatched session_id")
		}
		if chunk.GetStreamIndex() != streamIdx ||
			chunk.GetPhase() != netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD {
			return false, status.Error(codes.InvalidArgument, "mismatched stream_index or phase")
		}
		if n := len(chunk.GetData()); n > 0 {
			if chunk.GetSequence() != 0 && chunk.GetSequence() <= lastSeq {
				return false, status.Error(codes.InvalidArgument, "non-monotonic stream sequence")
			}
			if chunk.GetSequence() > 0 {
				lastSeq = chunk.GetSequence()
			}
			r.admission.addBytes(uint64(n))
			sess.uploadPhase.record(n, sess.omitDuration, r.nowFn())
		} else if firstChunk == chunk {
			sess.uploadPhase.record(0, sess.omitDuration, r.nowFn())
		}
		return chunk.GetEndOfPhase(), nil
	}

	done, err := processChunk(firstChunk)
	if err != nil {
		return err
	}
	if done {
		return nil
	}

	for {
		if err := sess.ctx.Err(); err != nil {
			return status.Error(codes.DeadlineExceeded, err.Error())
		}
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		done, err := processChunk(chunk)
		if err != nil {
			return err
		}
		if done {
			return nil
		}
	}
}

func (r *Responder) handleStreamDownload(
	stream netperfpb.NetworkPerfPeerService_StreamTestServer,
	sess *responderSession,
	firstChunk *netperfpb.TestStreamChunk,
) error {
	if sess.direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD &&
		sess.direction != netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		return status.Error(codes.PermissionDenied, "download phase not permitted for session")
	}

	if sess.protocol == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP {
		if err := r.runUDPDownload(stream.Context(), sess); err != nil {
			return err
		}
		return stream.Send(&netperfpb.TestStreamChunk{
			SessionId:   append([]byte(nil), sess.id[:]...),
			StreamIndex: firstChunk.GetStreamIndex(),
			Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
			EndOfPhase:  true,
		})
	}

	streamIdx := firstChunk.GetStreamIndex()
	if streamIdx >= sess.parallel {
		return status.Error(codes.InvalidArgument, "stream_index exceeds session parallel")
	}

	sess.downloadOnce.Do(func() {
		bytesPerSec := float64(sess.bandwidthBps) / 8.0
		chunkSize := tcpChunkSizeForBandwidth(sess.bandwidthBps)
		burst := max(chunkSize, int(bytesPerSec/20.0))
		sess.downloadLimiter = rate.NewLimiter(rate.Limit(bytesPerSec), burst)
		start := r.nowFn()
		sess.downloadStart = start
		sess.downloadOmitEnd = start.Add(sess.omitDuration)
		sess.downloadEnd = start.Add(sess.duration)
	})

	streamCtx, cancel := context.WithDeadline(stream.Context(), sess.downloadEnd)
	defer cancel()

	// Ensure sess cancellation also interrupts WaitN.
	stopWatch := context.AfterFunc(sess.ctx, cancel)
	defer stopWatch()

	buf := make([]byte, tcpChunkSizeForBandwidth(sess.bandwidthBps))
	var seq uint64
	for r.nowFn().Before(sess.downloadEnd) {
		if err := sess.downloadLimiter.WaitN(streamCtx, len(buf)); err != nil {
			if isRateDeadlineError(streamCtx, err) || !r.nowFn().Before(sess.downloadEnd) {
				break
			}
			return status.Error(codes.Canceled, err.Error())
		}
		if !r.nowFn().Before(sess.downloadEnd) {
			break
		}
		seq++
		chunk := &netperfpb.TestStreamChunk{
			SessionId:   append([]byte(nil), sess.id[:]...),
			StreamIndex: streamIdx,
			Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
			Data:        buf,
			Sequence:    seq,
		}
		if err := stream.Send(chunk); err != nil {
			return err
		}
		r.admission.addBytes(uint64(len(buf)))
		sess.downloadPhase.record(len(buf), sess.omitDuration, r.nowFn())
	}

	return stream.Send(&netperfpb.TestStreamChunk{
		SessionId:   append([]byte(nil), sess.id[:]...),
		StreamIndex: streamIdx,
		Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
		EndOfPhase:  true,
	})
}

// CloseSession finalizes counters, releases admission capacity, and returns the
// Responder's authoritative measurement summary.
func (r *Responder) CloseSession(
	ctx context.Context,
	req *netperfpb.CloseSessionRequest,
) (*netperfpb.CloseSessionResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, ErrInvalidRequest.Error())
	}
	peerID, err := ExtractPeerIdentity(ctx)
	if err != nil {
		return nil, status.Error(codes.Unauthenticated, err.Error())
	}
	sess, err := r.lookupAuthorizedSession(req.GetSessionId(), peerID)
	if err != nil {
		return nil, err
	}

	// Allow brief grace for trailing in-flight UDP datagrams before closing session.
	if sess.protocol == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP &&
		(sess.direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD ||
			sess.direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL) {
		select {
		case <-sess.udpEndCh:
		case <-time.After(30 * time.Millisecond):
		case <-ctx.Done():
		}
	}

	r.removeSession(sess)

	plannedSteady := sess.duration - sess.omitDuration
	var uploadSummary, downloadSummary, primary *netperfpb.TestSummary

	if sess.protocol == netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP {
		uploadSummary = sess.uploadPhase.summary(false, plannedSteady)
		downloadSummary = sess.downloadPhase.summary(true, plannedSteady)
	} else {
		if sess.direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD ||
			sess.direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
			authoritativeSent := req.GetSenderSummary().GetPacketsSent()
			stats := sess.udpTracker.Snapshot(authoritativeSent)
			dur := sess.udpUploadDuration(plannedSteady)
			var bps float64
			if dur > 0 {
				bps = (float64(stats.BytesReceived) * 8.0) / dur.Seconds()
			}
			uploadSummary = &netperfpb.TestSummary{
				DurationSeconds:   dur.Seconds(),
				DurationNs:        uint64(max(int64(0), dur.Nanoseconds())),
				BytesReceived:     stats.BytesReceived,
				BitsPerSecond:     bps,
				PacketsSent:       authoritativeSent,
				PacketsReceived:   stats.PacketsReceived,
				PacketsLost:       stats.PacketsLost,
				OutOfOrderPackets: stats.OutOfOrderPackets,
				LossPercent:       stats.LossPercent,
				JitterMs:          stats.JitterMs,
			}
		}
		if sess.direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD ||
			sess.direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
			sentPkts := sess.udpDownloadSent.Load()
			sentBytes := sess.udpDownloadByte.Load()
			dur := sess.udpDownloadDuration(plannedSteady)
			var bps float64
			if dur > 0 {
				bps = (float64(sentBytes) * 8.0) / dur.Seconds()
			}
			downloadSummary = &netperfpb.TestSummary{
				DurationSeconds: dur.Seconds(),
				DurationNs:      uint64(max(int64(0), dur.Nanoseconds())),
				BytesSent:       sentBytes,
				BitsPerSecond:   bps,
				PacketsSent:     sentPkts,
			}
		}
	}

	switch sess.direction {
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
		primary = uploadSummary
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
		primary = downloadSummary
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL:
		primary = combineBidirectionalSummaries(uploadSummary, downloadSummary)
	case netperfpb.NetperfDirection_NETPERF_DIRECTION_UNSPECIFIED:
	}
	if primary == nil {
		primary = &netperfpb.TestSummary{}
	}

	return &netperfpb.CloseSessionResponse{
		ResponderSummary: primary,
		UploadSummary:    uploadSummary,
		DownloadSummary:  downloadSummary,
	}, nil
}

func combineBidirectionalSummaries(up, down *netperfpb.TestSummary) *netperfpb.TestSummary {
	if up == nil && down == nil {
		return nil
	}
	if up == nil {
		return down
	}
	if down == nil {
		return up
	}
	totalNs := up.GetDurationNs() + down.GetDurationNs()
	totalSec := up.GetDurationSeconds() + down.GetDurationSeconds()
	bytesSent := up.GetBytesSent() + down.GetBytesSent()
	bytesRecv := up.GetBytesReceived() + down.GetBytesReceived()
	var bps float64
	if totalSec > 0 {
		bps = (float64(bytesSent+bytesRecv) * 8.0) / totalSec
	}
	return &netperfpb.TestSummary{
		DurationSeconds:   totalSec,
		DurationNs:        totalNs,
		BytesSent:         bytesSent,
		BytesReceived:     bytesRecv,
		BitsPerSecond:     bps,
		PacketsSent:       up.GetPacketsSent() + down.GetPacketsSent(),
		PacketsReceived:   up.GetPacketsReceived() + down.GetPacketsReceived(),
		PacketsLost:       up.GetPacketsLost() + down.GetPacketsLost(),
		OutOfOrderPackets: up.GetOutOfOrderPackets() + down.GetOutOfOrderPackets(),
		JitterMs:          max(up.GetJitterMs(), down.GetJitterMs()),
	}
}

func (r *Responder) lookupAuthorizedSession(rawID []byte, peer PeerIdentity) (*responderSession, error) {
	if len(rawID) != UDPSessionSize {
		return nil, status.Error(codes.InvalidArgument, ErrSessionNotFound.Error())
	}
	var id [UDPSessionSize]byte
	copy(id[:], rawID)

	r.sessionsMu.Lock()
	sess, ok := r.sessions[id]
	r.sessionsMu.Unlock()
	if !ok {
		return nil, status.Error(codes.NotFound, ErrSessionNotFound.Error())
	}
	if sess.senderAgentID != peer.AgentID || sess.partitionID != peer.PartitionID {
		return nil, status.Error(codes.PermissionDenied, ErrPermitScopeMismatch.Error())
	}
	return sess, nil
}

func (r *Responder) removeSession(sess *responderSession) {
	if sess == nil {
		return
	}
	sess.cancel()
	r.sessionsMu.Lock()
	_, exists := r.sessions[sess.id]
	if exists {
		delete(r.sessions, sess.id)
		delete(r.udpSessions, sess.id)
	}
	r.sessionsMu.Unlock()
	if exists {
		r.admission.release(sess.bandwidthBps)
	}
}

func (r *Responder) reapLoop() {
	defer r.wg.Done()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-r.stopCh:
			return
		case <-ticker.C:
			now := r.nowFn()
			var expired []*responderSession
			r.sessionsMu.Lock()
			for _, sess := range r.sessions {
				if now.After(sess.deadline) {
					expired = append(expired, sess)
				}
			}
			r.sessionsMu.Unlock()
			for _, sess := range expired {
				r.removeSession(sess)
			}
		}
	}
}

func permitErrorCode(err error) codes.Code {
	switch {
	case errors.Is(err, ErrInvalidRequest):
		return codes.InvalidArgument
	case errors.Is(err, ErrPermitRequired),
		errors.Is(err, ErrPermitInvalid),
		errors.Is(err, ErrPermitExpired),
		errors.Is(err, ErrPermitEpochFenced),
		errors.Is(err, ErrPermitScopeMismatch),
		errors.Is(err, ErrPermitCeilingExceeded),
		errors.Is(err, ErrPermitKeyUnavailable),
		errors.Is(err, ErrPermitKeyRevoked),
		errors.Is(err, ErrPermitKeyInvalid),
		errors.Is(err, ErrPermitSignatureInvalid):
		return codes.PermissionDenied
	default:
		return codes.PermissionDenied
	}
}

func bytesEqualSession(raw []byte, id [UDPSessionSize]byte) bool {
	if len(raw) != UDPSessionSize {
		return false
	}
	var other [UDPSessionSize]byte
	copy(other[:], raw)
	return other == id
}

func (s *responderSession) udpUploadDuration(plannedSteady time.Duration) time.Duration {
	s.udpMu.Lock()
	start := s.udpUploadStart
	end := s.udpUploadEnd
	s.udpMu.Unlock()
	if start.IsZero() {
		return 0
	}
	if end.IsZero() || !end.After(start) {
		return plannedSteady
	}
	return end.Sub(start)
}

func (s *responderSession) udpDownloadDuration(plannedSteady time.Duration) time.Duration {
	startNs := s.udpDownStartNs.Load()
	endNs := s.udpDownEndNs.Load()
	if startNs <= 0 {
		return 0
	}
	if endNs <= startNs {
		return plannedSteady
	}
	return time.Duration(endNs - startNs)
}
