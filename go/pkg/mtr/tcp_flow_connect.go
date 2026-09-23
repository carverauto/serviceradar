//go:build linux || darwin

/*
 * Copyright 2025 Carver Automation Corporation.
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

package mtr

import (
	"errors"
	"fmt"
	"net"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// connectPollSlice bounds each poll so a closing flow is noticed promptly.
const connectPollSlice = 100 * time.Millisecond

// connectTCPFlow probes with kernel connect() attempts. It is the fallback for
// platforms (or processes) that cannot craft and receive raw TCP segments.
//
// Each probe binds its sequence number as the source port and connects to the
// flow's fixed destination port, so ICMP errors are matched by the quoted source
// port. Because the source port varies per probe, this flow gives no ECMP
// stability, and the kernel owns the SYN, so no handshake diagnostics are
// possible. It does detect the target answering: a completed connect is a
// SYN-ACK, a refused one is an RST.
type connectTCPFlow struct {
	ipv6    bool
	dst     net.IP
	dstPort int
	timeout time.Duration

	replies chan *TCPReply
	closed  chan struct{}
	once    sync.Once
	wg      sync.WaitGroup
}

func newConnectTCPFlow(dst net.IP, dstPort int, timeout time.Duration, ipv6 bool) *connectTCPFlow {
	if timeout <= 0 {
		timeout = DefaultTimeout
	}

	return &connectTCPFlow{
		ipv6:    ipv6,
		dst:     append(net.IP(nil), dst...),
		dstPort: dstPort,
		timeout: timeout,
		replies: make(chan *TCPReply, 64), //nolint:mnd
		closed:  make(chan struct{}),
	}
}

func (f *connectTCPFlow) Crafted() bool { return false }

func (f *connectTCPFlow) SendSYN(ttl, seq int) error {
	fd, err := f.openProbeSocket(ttl, seq)
	if err != nil {
		return err
	}

	err = syscall.Connect(fd, f.dstSockaddr())

	switch {
	case err == nil:
		f.emit(seq, true, false)
		closeAbortive(fd)
	case errors.Is(err, syscall.ECONNREFUSED):
		f.emit(seq, false, true)
		closeAbortive(fd)
	case errors.Is(err, syscall.EINPROGRESS), errors.Is(err, syscall.EINTR):
		f.wg.Add(1)

		go f.await(fd, seq)
	default:
		closeAbortive(fd)
		return fmt.Errorf("connect TCP probe: %w", err)
	}

	return nil
}

func (f *connectTCPFlow) openProbeSocket(ttl, seq int) (int, error) {
	family := syscall.AF_INET
	if f.ipv6 {
		family = syscall.AF_INET6
	}

	fd, err := syscall.Socket(family, syscall.SOCK_STREAM, syscall.IPPROTO_TCP)
	if err != nil {
		return -1, fmt.Errorf("create TCP socket: %w", err)
	}

	if err := f.configureProbeSocket(fd, ttl, seq); err != nil {
		_ = syscall.Close(fd)
		return -1, err
	}

	return fd, nil
}

func (f *connectTCPFlow) configureProbeSocket(fd, ttl, seq int) error {
	if f.ipv6 {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl); err != nil {
			return fmt.Errorf("set TCP hop limit: %w", err)
		}
	} else if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
		return fmt.Errorf("set TCP TTL: %w", err)
	}

	if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1); err != nil {
		return fmt.Errorf("set TCP reuseaddr: %w", err)
	}

	if err := syscall.SetNonblock(fd, true); err != nil {
		return fmt.Errorf("set TCP nonblock: %w", err)
	}

	var local syscall.Sockaddr = &syscall.SockaddrInet4{Port: seq}
	if f.ipv6 {
		local = &syscall.SockaddrInet6{Port: seq}
	}

	if err := syscall.Bind(fd, local); err != nil {
		return fmt.Errorf("bind TCP probe port %d: %w", seq, err)
	}

	return nil
}

func (f *connectTCPFlow) dstSockaddr() syscall.Sockaddr {
	if f.ipv6 {
		sa := &syscall.SockaddrInet6{Port: f.dstPort}
		copy(sa.Addr[:], f.dst.To16())

		return sa
	}

	sa := &syscall.SockaddrInet4{Port: f.dstPort}
	copy(sa.Addr[:], f.dst.To4())

	return sa
}

// await waits for a pending connect to resolve, then reports it and closes the
// socket abortively so the kernel neither retransmits nor lingers.
func (f *connectTCPFlow) await(fd, seq int) {
	defer f.wg.Done()
	defer closeAbortive(fd)

	deadline := time.Now().Add(f.timeout)

	for time.Now().Before(deadline) {
		select {
		case <-f.closed:
			return
		default:
		}

		wait := min(time.Until(deadline), connectPollSlice)
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLOUT}} //nolint:gosec

		n, err := unix.Poll(fds, int(wait.Milliseconds()))
		if err != nil && !errors.Is(err, unix.EINTR) {
			return
		}

		if n == 0 {
			continue
		}

		soErr, err := syscall.GetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_ERROR)
		if err != nil {
			return
		}

		// Any other error (host or network unreachable, timeout) produced an
		// ICMP error or nothing; the ICMP receiver accounts for it.
		if soErr == 0 {
			f.emit(seq, true, false)
		} else if syscall.Errno(soErr) == syscall.ECONNREFUSED { //nolint:gosec
			f.emit(seq, false, true)
		}

		return
	}
}

func (f *connectTCPFlow) emit(seq int, synAck, rst bool) {
	reply := &TCPReply{Seq: seq, SYNACK: synAck, RST: rst, RecvTime: time.Now()}

	select {
	case f.replies <- reply:
	case <-f.closed:
	}
}

func (f *connectTCPFlow) Receive(deadline time.Time) (*TCPReply, error) {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()

	select {
	case reply := <-f.replies:
		return reply, nil
	case <-timer.C:
		return nil, probeTimeoutError{}
	case <-f.closed:
		return nil, net.ErrClosed
	}
}

func (f *connectTCPFlow) MatchQuoted(resp *ICMPResponse) (int, bool) {
	if resp.InnerProto != ipProtoTCP || resp.InnerDstPort != f.dstPort {
		return 0, false
	}

	seq := resp.InnerSrcPort
	if seq < MinPort || seq > MaxPort {
		return 0, false
	}

	return seq, true
}

func (f *connectTCPFlow) Close() error {
	f.once.Do(func() { close(f.closed) })
	f.wg.Wait()

	return nil
}

// closeAbortive closes a probe socket with SO_LINGER 0, which discards any
// connection state (sending RST if the handshake completed) instead of leaving
// the port in TIME_WAIT for the next trace.
func closeAbortive(fd int) {
	_ = syscall.SetsockoptLinger(fd, syscall.SOL_SOCKET, syscall.SO_LINGER, &syscall.Linger{Onoff: 1, Linger: 0})
	_ = syscall.Close(fd)
}
