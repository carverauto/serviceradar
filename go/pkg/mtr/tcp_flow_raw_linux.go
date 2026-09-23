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
	"math/rand/v2"
	"net"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// rawTCPFlow crafts SYN segments on a raw IPPROTO_TCP socket and reads the
// target's SYN-ACK/RST on the same socket.
//
// Every probe of the flow shares one 5-tuple: a source port reserved for the
// flow's lifetime and the configured destination port. Only the TTL and the TCP
// sequence number change, so ECMP hashes every TTL onto the same path. A probe
// is identified by its sequence number, which ICMP errors quote and which the
// target acknowledges (ack = seq + 1).
//
// The reservation socket is bound but never listens or connects. The kernel
// therefore has no socket for the flow's 4-tuple and answers every SYN-ACK with
// RST, tearing down the target's half-open connection.
type rawTCPFlow struct {
	ipv6    bool
	fd      int
	resvFD  int
	src     net.IP
	dst     net.IP
	srcPort int
	dstPort int
	isnBase uint32
	sendBuf []byte
	recvBuf []byte
}

var (
	errRawTCPPermission   = errors.New("raw TCP socket not permitted")
	errNoLocalAddress     = errors.New("no local address")
	errUnexpectedSockAddr = errors.New("unexpected address family")
)

func openRawTCPFlow(dst net.IP, dstPort int, ipv6 bool) (*rawTCPFlow, error) {
	src, err := routeSourceAddr(dst, dstPort, ipv6)
	if err != nil {
		return nil, err
	}

	family := syscall.AF_INET
	if ipv6 {
		family = syscall.AF_INET6
	}

	fd, err := syscall.Socket(family, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		if errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EACCES) {
			return nil, fmt.Errorf("%w: %w", errRawTCPPermission, err)
		}

		return nil, fmt.Errorf("create raw TCP socket: %w", err)
	}

	resvFD, srcPort, err := reserveTCPPort(family, src)
	if err != nil {
		_ = syscall.Close(fd)
		return nil, err
	}

	if err := attachFilter(fd, tcpDstPortFilter(srcPort, ipv6)); err != nil {
		_ = syscall.Close(fd)
		_ = syscall.Close(resvFD)

		return nil, fmt.Errorf("attach TCP flow filter: %w", err)
	}

	return &rawTCPFlow{
		ipv6:    ipv6,
		fd:      fd,
		resvFD:  resvFD,
		src:     src,
		dst:     append(net.IP(nil), dst...),
		srcPort: srcPort,
		dstPort: dstPort,
		isnBase: rand.Uint32(), //nolint:gosec // probe identity, not a security boundary
		recvBuf: make([]byte, recvBufSize),
	}, nil
}

// routeSourceAddr asks the kernel which local address it would use toward dst.
// Connecting a UDP socket sends nothing; it only resolves the route. It fails
// for destinations the host cannot route, such as an IPv6 link-local address
// without a zone.
func routeSourceAddr(dst net.IP, dstPort int, ipv6 bool) (net.IP, error) {
	network := "udp4"
	if ipv6 {
		network = "udp6"
	}

	conn, err := net.DialUDP(network, nil, &net.UDPAddr{IP: dst, Port: dstPort})
	if err != nil {
		return nil, fmt.Errorf("resolve source address toward %s: %w", dst, err)
	}
	defer func() { _ = conn.Close() }()

	local, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok || local.IP == nil {
		return nil, fmt.Errorf("resolve source address toward %s: %w", dst, errNoLocalAddress)
	}

	return append(net.IP(nil), local.IP...), nil
}

// reserveTCPPort binds an ephemeral TCP port on src and holds it for the flow.
func reserveTCPPort(family int, src net.IP) (int, int, error) {
	fd, err := syscall.Socket(family, syscall.SOCK_STREAM, syscall.IPPROTO_TCP)
	if err != nil {
		return -1, 0, fmt.Errorf("create TCP port reservation: %w", err)
	}

	var local syscall.Sockaddr

	if family == syscall.AF_INET6 {
		sa := &syscall.SockaddrInet6{}
		copy(sa.Addr[:], src.To16())
		local = sa
	} else {
		sa := &syscall.SockaddrInet4{}
		copy(sa.Addr[:], src.To4())
		local = sa
	}

	if err := syscall.Bind(fd, local); err != nil {
		_ = syscall.Close(fd)
		return -1, 0, fmt.Errorf("bind TCP port reservation: %w", err)
	}

	bound, err := syscall.Getsockname(fd)
	if err != nil {
		_ = syscall.Close(fd)
		return -1, 0, fmt.Errorf("read TCP port reservation: %w", err)
	}

	switch sa := bound.(type) {
	case *syscall.SockaddrInet4:
		return fd, sa.Port, nil
	case *syscall.SockaddrInet6:
		return fd, sa.Port, nil
	}

	_ = syscall.Close(fd)

	return -1, 0, fmt.Errorf("read TCP port reservation: %w", errUnexpectedSockAddr)
}

// tcpDstPortFilter is a classic BPF program that passes only TCP segments whose
// destination port is the flow's reserved port. A raw TCP socket otherwise
// receives a copy of every inbound TCP segment on the host.
//
// IPv4 raw sockets deliver the IP header, so the TCP header offset comes from
// the IHL nibble; IPv6 raw sockets deliver the transport header directly.
func tcpDstPortFilter(port int, ipv6 bool) []unix.SockFilter {
	const (
		ldxMSHByte = unix.BPF_LDX | unix.BPF_B | unix.BPF_MSH // X = 4*([k]&0xf)
		ldIndHalf  = unix.BPF_LD | unix.BPF_H | unix.BPF_IND  // A = [X+k]
		ldAbsHalf  = unix.BPF_LD | unix.BPF_H | unix.BPF_ABS  // A = [k]
		jeqK       = unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K
		retK       = unix.BPF_RET | unix.BPF_K
		acceptAll  = 0xFFFF
	)

	matchPort := uint32(port) //nolint:gosec // port comes from getsockname

	if ipv6 {
		return []unix.SockFilter{
			{Code: ldAbsHalf, K: 2},
			{Code: jeqK, Jt: 0, Jf: 1, K: matchPort},
			{Code: retK, K: acceptAll},
			{Code: retK, K: 0},
		}
	}

	return []unix.SockFilter{
		{Code: ldxMSHByte, K: 0},
		{Code: ldIndHalf, K: 2},
		{Code: jeqK, Jt: 0, Jf: 1, K: matchPort},
		{Code: retK, K: acceptAll},
		{Code: retK, K: 0},
	}
}

// attachFilter installs a classic BPF program on fd (SO_ATTACH_FILTER).
func attachFilter(fd int, prog []unix.SockFilter) error {
	fprog := unix.SockFprog{
		Len:    uint16(len(prog)), //nolint:gosec // a handful of instructions
		Filter: unsafe.SliceData(prog),
	}

	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &fprog)
}

func (f *rawTCPFlow) Crafted() bool { return true }

func (f *rawTCPFlow) SendSYN(ttl, seq int) error {
	if f.ipv6 {
		if err := syscall.SetsockoptInt(f.fd, syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl); err != nil {
			return fmt.Errorf("set TCP hop limit: %w", err)
		}
	} else if err := syscall.SetsockoptInt(f.fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
		return fmt.Errorf("set TCP TTL: %w", err)
	}

	f.sendBuf = buildTCPSyn(f.sendBuf, f.src, f.dst, f.srcPort, f.dstPort, f.isnBase+uint32(seq)) //nolint:gosec

	if f.ipv6 {
		sa := &syscall.SockaddrInet6{}
		copy(sa.Addr[:], f.dst.To16())

		return syscall.Sendto(f.fd, f.sendBuf, 0, sa)
	}

	sa := &syscall.SockaddrInet4{}
	copy(sa.Addr[:], f.dst.To4())

	return syscall.Sendto(f.fd, f.sendBuf, 0, sa)
}

func (f *rawTCPFlow) Receive(deadline time.Time) (*TCPReply, error) {
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, probeTimeoutError{}
		}

		tv := syscall.NsecToTimeval(max(remaining, time.Millisecond).Nanoseconds())
		if err := syscall.SetsockoptTimeval(f.fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
			return nil, fmt.Errorf("set TCP receive timeout: %w", err)
		}

		n, from, err := syscall.Recvfrom(f.fd, f.recvBuf, 0)
		if err != nil {
			if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
				continue
			}

			return nil, err
		}

		if reply, ok := f.parse(f.recvBuf[:n], from, time.Now()); ok {
			return reply, nil
		}
	}
}

// parse accepts only the target's answers on this flow. Everything else the
// filter let through (another trace's segments, our own looped-back SYNs) is
// dropped.
func (f *rawTCPFlow) parse(pkt []byte, from syscall.Sockaddr, recvTime time.Time) (*TCPReply, bool) {
	segBytes, srcAddr, ok := splitRawTCP(pkt, from, f.ipv6)
	if !ok || !srcAddr.Equal(f.dst) {
		return nil, false
	}

	seg, ok := parseTCPSegment(segBytes)
	if !ok || seg.srcPort != f.dstPort || seg.dstPort != f.srcPort || !seg.isProbeAnswer() {
		return nil, false
	}

	reply := &TCPReply{
		Seq:      f.seqFromAck(seg.ack),
		SYNACK:   seg.flags&tcpFlagSYN != 0,
		RST:      seg.flags&tcpFlagRST != 0,
		RecvTime: recvTime,
	}

	return reply, true
}

// splitRawTCP returns the TCP segment and its source address from a raw socket
// read. IPv4 reads include the IP header; IPv6 reads do not.
func splitRawTCP(pkt []byte, from syscall.Sockaddr, ipv6 bool) ([]byte, net.IP, bool) {
	if ipv6 {
		sa, ok := from.(*syscall.SockaddrInet6)
		if !ok {
			return nil, nil, false
		}

		return pkt, net.IP(sa.Addr[:]), true
	}

	if len(pkt) < ipv4HeaderMinLen {
		return nil, nil, false
	}

	ihl := int(pkt[0]&0x0f) * 4 //nolint:mnd
	if ihl < ipv4HeaderMinLen || len(pkt) < ihl {
		return nil, nil, false
	}

	return pkt[ihl:], net.IP(pkt[12:16]).To16(), true
}

// seqFromAck maps an acknowledgement number back to a probe sequence, or -1
// when it acknowledges nothing this flow sent.
func (f *rawTCPFlow) seqFromAck(ack uint32) int {
	seq := int(ack - 1 - f.isnBase)
	if seq < MinPort || seq > MaxPort {
		return -1
	}

	return seq
}

func (f *rawTCPFlow) MatchQuoted(resp *ICMPResponse) (int, bool) {
	if resp.InnerProto != ipProtoTCP || resp.InnerSrcPort != f.srcPort || resp.InnerDstPort != f.dstPort {
		return 0, false
	}

	seq := int(resp.InnerTCPSeq - f.isnBase)
	if seq < MinPort || seq > MaxPort {
		return 0, false
	}

	return seq, true
}

func (f *rawTCPFlow) Close() error {
	return errors.Join(syscall.Close(f.fd), syscall.Close(f.resvFD))
}
