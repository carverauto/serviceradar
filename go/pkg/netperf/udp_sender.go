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
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/time/rate"

	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

func (s *Sender) runUDPSession(
	ctx context.Context,
	client netperfpb.NetworkPerfPeerServiceClient,
	sessionID [UDPSessionSize]byte,
	udpKey []byte,
	targetAddress string,
	udpPort uint32,
	direction netperfpb.NetperfDirection,
	bandwidthBps uint64,
	duration time.Duration,
	omitDuration time.Duration,
	parallel uint32,
	packetLength uint32,
) (*PhaseResult, *PhaseResult, error) {
	addrStr := net.JoinHostPort(targetAddress, strconv.FormatUint(uint64(udpPort), 10))
	udpAddr, err := net.ResolveUDPAddr("udp", addrStr)
	if err != nil {
		return nil, nil, err
	}
	conn, err := net.DialUDP("udp", nil, udpAddr)
	if err != nil {
		return nil, nil, err
	}
	defer func() { _ = conn.Close() }()

	if err := s.sendUDPHello(ctx, conn, sessionID, udpKey); err != nil {
		return nil, nil, err
	}

	var upPhase, downPhase *PhaseResult
	if direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD ||
		direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		res, err := s.runUDPUpload(ctx, conn, sessionID, udpKey, bandwidthBps, duration, omitDuration, parallel, packetLength)
		if err != nil {
			return nil, nil, err
		}
		upPhase = res
	}
	if direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD ||
		direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		// Re-send HELLO before download to refresh NAT mapping if upload phase ran first.
		if direction == netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
			if err := s.sendUDPHello(ctx, conn, sessionID, udpKey); err != nil {
				return upPhase, nil, err
			}
		}
		res, err := s.runUDPDownload(ctx, client, conn, sessionID, udpKey, duration, omitDuration)
		if err != nil {
			return upPhase, nil, err
		}
		downPhase = res
	}
	return upPhase, downPhase, nil
}

func (s *Sender) sendUDPHello(
	ctx context.Context,
	conn *net.UDPConn,
	sessionID [UDPSessionSize]byte,
	udpKey []byte,
) error {
	helloBuf := make([]byte, UDPHeaderSize)
	for i := range 3 {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := EncodeUDPDatagram(helloBuf, udpKey, UDPFlagHello, sessionID, 0, uint64(s.nowFn().UnixNano())); err != nil {
			return err
		}
		if _, err := conn.Write(helloBuf); err != nil {
			return err
		}
		if i < 2 {
			timer := time.NewTimer(10 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
	return nil
}

func (s *Sender) runUDPUpload(
	ctx context.Context,
	conn *net.UDPConn,
	sessionID [UDPSessionSize]byte,
	udpKey []byte,
	bandwidthBps uint64,
	duration time.Duration,
	omitDuration time.Duration,
	parallel uint32,
	packetLength uint32,
) (*PhaseResult, error) {
	pktLen := max(int(packetLength), UDPHeaderSize)
	bytesPerSec := float64(bandwidthBps) / 8.0
	burst := max(pktLen, int(bytesPerSec/20.0))
	limiter := rate.NewLimiter(rate.Limit(bytesPerSec), burst)

	start := s.nowFn()
	omitEnd := start.Add(omitDuration)
	testEnd := start.Add(duration)
	paceCtx, cancel := context.WithDeadline(ctx, testEnd)
	defer cancel()

	var steadySeq atomic.Uint64
	var omitSeq atomic.Uint64
	var steadySentPackets atomic.Uint64
	var steadySentBytes atomic.Uint64
	var firstSteadyNs atomic.Int64
	var lastSteadyNs atomic.Int64

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

	for range parallel {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, pktLen)
			for {
				now := s.nowFn()
				if !now.Before(testEnd) {
					return
				}
				if err := limiter.WaitN(paceCtx, pktLen); err != nil {
					if phaseDone, fatalErr := classifyRateWaitError(ctx, nil, paceCtx, testEnd, s.nowFn(), err); phaseDone {
						return
					} else {
						setErr(fatalErr)
						return
					}
				}
				if ctx.Err() != nil {
					setErr(ctx.Err())
					return
				}
				now = s.nowFn()
				if !now.Before(testEnd) {
					return
				}

				flags := UDPFlagData
				var seq uint64
				isSteady := !now.Before(omitEnd)
				if !isSteady {
					flags |= UDPFlagOmit
					seq = omitSeq.Add(1)
				} else {
					seq = steadySeq.Add(1)
				}

				if err := EncodeUDPDatagram(buf, udpKey, flags, sessionID, seq, uint64(now.UnixNano())); err != nil {
					setErr(err)
					return
				}
				if _, err := conn.Write(buf); err != nil {
					setErr(err)
					return
				}
				if isSteady {
					nowNs := now.UnixNano()
					firstSteadyNs.CompareAndSwap(0, nowNs)
					lastSteadyNs.Store(nowNs)
					steadySentPackets.Add(1)
					steadySentBytes.Add(uint64(pktLen))
				}
			}
		}()
	}

	wg.Wait()
	if firstErr != nil {
		return nil, firstErr
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	endBuf := make([]byte, UDPHeaderSize)
	finalSeq := steadySeq.Load()
	for range 3 {
		_ = EncodeUDPDatagram(endBuf, udpKey, UDPFlagEnd, sessionID, finalSeq, uint64(s.nowFn().UnixNano()))
		_, _ = conn.Write(endBuf)
	}

	dur := duration - omitDuration
	if fNs, lNs := firstSteadyNs.Load(), lastSteadyNs.Load(); fNs > 0 && lNs > fNs {
		dur = time.Duration(lNs - fNs)
	}
	bytesSent := steadySentBytes.Load()
	var bps float64
	if dur > 0 {
		bps = (float64(bytesSent) * 8.0) / dur.Seconds()
	}

	return &PhaseResult{
		Direction:       netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		DurationSeconds: dur.Seconds(),
		DurationNs:      uint64(max(int64(0), dur.Nanoseconds())),
		BytesSent:       bytesSent,
		BitsPerSecond:   bps,
		PacketsSent:     steadySentPackets.Load(),
	}, nil
}

func (s *Sender) runUDPDownload(
	ctx context.Context,
	client netperfpb.NetworkPerfPeerServiceClient,
	conn *net.UDPConn,
	sessionID [UDPSessionSize]byte,
	udpKey []byte,
	duration time.Duration,
	omitDuration time.Duration,
) (*PhaseResult, error) {
	phaseCtx, cancel := context.WithDeadline(ctx, s.nowFn().Add(duration+s.cfg.RPCTimeout))
	defer cancel()

	stream, err := client.StreamTest(phaseCtx)
	if err != nil {
		return nil, err
	}
	if err := stream.Send(&netperfpb.TestStreamChunk{
		SessionId:   sessionID[:],
		StreamIndex: 0,
		Phase:       netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
		EndOfPhase:  true,
	}); err != nil {
		return nil, err
	}
	if err := stream.CloseSend(); err != nil {
		return nil, err
	}

	readDeadline := s.nowFn().Add(duration + 750*time.Millisecond)
	_ = conn.SetReadDeadline(readDeadline)

	var (
		streamMu  sync.Mutex
		streamErr error
	)
	streamDone := make(chan struct{})
	go func() {
		defer close(streamDone)
		for {
			chunk, recvErr := stream.Recv()
			if errors.Is(recvErr, io.EOF) {
				streamMu.Lock()
				streamErr = io.ErrUnexpectedEOF
				streamMu.Unlock()
				_ = conn.SetReadDeadline(time.Now())
				return
			}
			if recvErr != nil {
				streamMu.Lock()
				streamErr = recvErr
				streamMu.Unlock()
				_ = conn.SetReadDeadline(time.Now())
				return
			}
			if chunk.GetEndOfPhase() {
				_ = conn.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
				return
			}
		}
	}()
	defer func() {
		cancel()
		<-streamDone
	}()

	stopRead := context.AfterFunc(ctx, func() {
		_ = conn.SetReadDeadline(time.Now())
	})
	defer stopRead()

	var tracker RFC3550Tracker
	var firstSteady, lastSteady time.Time

	buf := make([]byte, 65536)
	for ctx.Err() == nil {
		n, err := conn.Read(buf)
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				break
			}
			if errors.Is(err, net.ErrClosed) {
				break
			}
			break
		}
		pkt := buf[:n]
		flags, sid, seq, sentUnixNano, ok := ParseUDPHeader(pkt)
		if !ok || sid != sessionID || !VerifyUDPMAC(pkt, udpKey) {
			continue
		}
		if flags&UDPFlagEnd != 0 {
			break
		}
		if flags&UDPFlagData == 0 || flags&UDPFlagOmit != 0 {
			continue
		}
		now := s.nowFn()
		if firstSteady.IsZero() {
			firstSteady = now
		}
		lastSteady = now
		tracker.Record(seq, sentUnixNano, now.Sub(firstSteady).Nanoseconds(), uint64(n))
	}
	_ = conn.SetReadDeadline(time.Time{})

	streamCompleted := false
	select {
	case <-streamDone:
		streamCompleted = true
	case <-time.After(500 * time.Millisecond):
	case <-ctx.Done():
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if !streamCompleted {
		return nil, fmt.Errorf("netperf: UDP download stream did not complete (HELLO or END missing): %w", context.DeadlineExceeded)
	}
	streamMu.Lock()
	sErr := streamErr
	streamMu.Unlock()
	if sErr != nil {
		return nil, sErr
	}

	stats := tracker.Snapshot(0)
	dur := duration - omitDuration
	if !firstSteady.IsZero() && lastSteady.After(firstSteady) {
		dur = lastSteady.Sub(firstSteady)
	}
	var bps float64
	if dur > 0 {
		bps = (float64(stats.BytesReceived) * 8.0) / dur.Seconds()
	}
	return &PhaseResult{
		Direction:         netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
		DurationSeconds:   dur.Seconds(),
		DurationNs:        uint64(max(int64(0), dur.Nanoseconds())),
		BytesReceived:     stats.BytesReceived,
		BitsPerSecond:     bps,
		PacketsReceived:   stats.PacketsReceived,
		PacketsLost:       stats.PacketsLost,
		OutOfOrderPackets: stats.OutOfOrderPackets,
		LossPercent:       stats.LossPercent,
		JitterMs:          stats.JitterMs,
	}, nil
}
