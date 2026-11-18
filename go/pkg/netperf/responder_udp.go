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
	"net"
	"net/netip"

	"golang.org/x/time/rate"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (r *Responder) serveUDP() {
	defer r.wg.Done()
	if r.udpConn == nil {
		return
	}

	buf := make([]byte, 65536)
	for {
		n, addrPort, err := r.udpConn.ReadFromUDPAddrPort(buf)
		if err != nil {
			select {
			case <-r.stopCh:
				return
			default:
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		r.handleUDPPacket(buf[:n], addrPort)
	}
}

// handleUDPPacket verifies and demultiplexes one UDP datagram by 16-byte session_id.
// Invalid, unauthenticated, or unknown-session packets are dropped silently with
// zero response bytes to prevent amplification.
func (r *Responder) handleUDPPacket(pkt []byte, src netip.AddrPort) {
	flags, sessionID, seq, sentUnixNano, ok := ParseUDPHeader(pkt)
	if !ok {
		return
	}

	r.sessionsMu.Lock()
	sess := r.udpSessions[sessionID]
	r.sessionsMu.Unlock()
	if sess == nil {
		return
	}

	if !VerifyUDPMAC(pkt, sess.udpKey) {
		return
	}

	now := r.nowFn()
	if !sess.lockOrVerifyPeerAddr(src, flags) {
		return
	}

	if flags&UDPFlagHello != 0 {
		sess.helloOnce.Do(func() {
			close(sess.helloReady)
		})
		return
	}

	if flags&UDPFlagEnd != 0 {
		sess.udpMu.Lock()
		sess.udpUploadEnd = now
		sess.udpMu.Unlock()
		sess.udpEndOnce.Do(func() {
			close(sess.udpEndCh)
		})
		return
	}

	if flags&UDPFlagData != 0 {
		r.admission.addBytes(uint64(len(pkt)))
		if flags&UDPFlagOmit != 0 {
			return
		}
		sess.udpUploadOnce.Do(func() {
			sess.udpMu.Lock()
			sess.udpUploadStart = now
			sess.udpMu.Unlock()
		})
		sess.udpMu.Lock()
		start := sess.udpUploadStart
		sess.udpUploadEnd = now
		sess.udpMu.Unlock()

		arrivalMono := now.Sub(start).Nanoseconds()
		sess.udpTracker.Record(seq, sentUnixNano, arrivalMono, uint64(len(pkt)))
	}
}

func (s *responderSession) lockOrVerifyPeerAddr(src netip.AddrPort, flags uint8) bool {
	s.udpMu.Lock()
	defer s.udpMu.Unlock()

	if !s.hasLockedPeer {
		// Lock NAT tuple on authenticated HELLO, or first authenticated DATA for upload.
		if flags&(UDPFlagHello|UDPFlagData) == 0 {
			return false
		}
		s.lockedPeerAddr = src
		s.hasLockedPeer = true
		return true
	}
	return s.lockedPeerAddr == src
}

func (r *Responder) runUDPDownload(streamCtx context.Context, sess *responderSession) error {
	if r.udpConn == nil {
		return status.Error(codes.FailedPrecondition, ErrUDPDisabled.Error())
	}

	select {
	case <-sess.helloReady:
	case <-streamCtx.Done():
		return status.Error(codes.Canceled, streamCtx.Err().Error())
	case <-sess.ctx.Done():
		return status.Error(codes.DeadlineExceeded, sess.ctx.Err().Error())
	case <-r.stopCh:
		return status.Error(codes.Unavailable, "responder stopping")
	}

	sess.udpMu.Lock()
	targetAddr := sess.lockedPeerAddr
	sess.udpMu.Unlock()
	if !targetAddr.IsValid() {
		return status.Error(codes.FailedPrecondition, "missing locked NAT peer address")
	}

	pktLen := int(sess.packetLength)
	if pktLen < UDPHeaderSize {
		pktLen = int(DefaultPacketLength)
	}
	bytesPerSec := float64(sess.bandwidthBps) / 8.0
	burst := max(pktLen, int(bytesPerSec/20.0))
	limiter := rate.NewLimiter(rate.Limit(bytesPerSec), burst)

	start := r.nowFn()
	omitEnd := start.Add(sess.omitDuration)
	testEnd := start.Add(sess.duration)

	paceCtx, cancel := context.WithDeadline(streamCtx, testEnd)
	defer cancel()
	stopWatch := context.AfterFunc(sess.ctx, cancel)
	defer stopWatch()

	buf := make([]byte, pktLen)
	var steadySeq uint64
	var omitSeq uint64
	var steadyStarted bool

	for {
		now := r.nowFn()
		if !now.Before(testEnd) {
			break
		}
		if err := limiter.WaitN(paceCtx, pktLen); err != nil {
			if isRateDeadlineError(paceCtx, err) || !r.nowFn().Before(testEnd) {
				break
			}
			return status.Error(codes.Canceled, err.Error())
		}
		now = r.nowFn()
		if !now.Before(testEnd) {
			break
		}

		flags := UDPFlagData
		var seq uint64
		if now.Before(omitEnd) {
			flags |= UDPFlagOmit
			omitSeq++
			seq = omitSeq
		} else {
			if !steadyStarted {
				steadyStarted = true
				sess.udpDownStartNs.Store(now.UnixNano())
			}
			steadySeq++
			seq = steadySeq
			sess.udpDownEndNs.Store(now.UnixNano())
			sess.udpDownloadSent.Add(1)
			sess.udpDownloadByte.Add(uint64(pktLen))
		}

		if err := EncodeUDPDatagram(buf, sess.udpKey, flags, sess.id, seq, uint64(now.UnixNano())); err != nil {
			return status.Error(codes.Internal, err.Error())
		}
		if _, err := r.udpConn.WriteToUDPAddrPort(buf, targetAddr); err != nil {
			if errors.Is(err, net.ErrClosed) {
				return status.Error(codes.Unavailable, err.Error())
			}
		} else {
			r.admission.addBytes(uint64(pktLen))
		}
	}

	// Transmit 3 END markers so the Spoke receiver terminates promptly.
	endBuf := make([]byte, UDPHeaderSize)
	for range 3 {
		_ = EncodeUDPDatagram(endBuf, sess.udpKey, UDPFlagEnd, sess.id, steadySeq, uint64(r.nowFn().UnixNano()))
		_, _ = r.udpConn.WriteToUDPAddrPort(endBuf, targetAddr)
	}
	return nil
}
