//go:build linux

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
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"syscall"
	"time"

	"golang.org/x/net/icmp"
)

const (
	icmpv4EchoReply    = 0
	icmpv4TimeExceeded = 11
	icmpv4DstUnreach   = 3

	icmpv6EchoReply    = 129
	icmpv6TimeExceeded = 3
	icmpv6DstUnreach   = 1

	ipv4HeaderMinLen = 20
	icmpHeaderLen    = 8
	recvBufSize      = 1500
)

var (
	errUDPProbeRequiresRawSocket = errors.New("UDP probes require raw socket (CAP_NET_RAW)")
	errShortICMPHeader           = errors.New("packet too short for ICMP header")
	errShortICMPv6Header         = errors.New("packet too short for ICMPv6 header")
)

// linuxRawSocket implements RawSocket using Linux raw sockets.
type linuxRawSocket struct {
	sendFD   int
	conn     *icmp.PacketConn
	ipv6     bool
	sendBuf  []byte
	recvPool recvBufferPool
}

// NewRawSocket creates a new raw socket for ICMP probing.
// Attempts privileged raw socket first, falls back to SOCK_DGRAM.
func NewRawSocket(ipv6mode bool) (RawSocket, error) {
	if ipv6mode {
		return newRawSocket6()
	}

	return newRawSocket4()
}

func newRawSocket4() (RawSocket, error) {
	// Try privileged raw socket first.
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		// Fallback to unprivileged SOCK_DGRAM.
		conn, dErr := icmp.ListenPacket("udp4", "0.0.0.0")
		if dErr != nil {
			return nil, fmt.Errorf("no raw or dgram ICMP socket available: raw=%w, dgram=%w", err, dErr)
		}

		return &linuxRawSocket{sendFD: -1, conn: conn, ipv6: false, recvPool: newRecvBufferPool()}, nil
	}

	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		if closeErr := syscall.Close(fd); closeErr != nil {
			return nil, fmt.Errorf("create ICMP listener: %w", errors.Join(err, fmt.Errorf("close raw socket: %w", closeErr)))
		}

		return nil, fmt.Errorf("create ICMP listener: %w", err)
	}

	return &linuxRawSocket{sendFD: fd, conn: conn, ipv6: false, recvPool: newRecvBufferPool()}, nil
}

func newRawSocket6() (RawSocket, error) {
	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_RAW, syscall.IPPROTO_ICMPV6)
	if err != nil {
		conn, dErr := icmp.ListenPacket("udp6", "::")
		if dErr != nil {
			return nil, fmt.Errorf("no raw or dgram ICMPv6 socket available: raw=%w, dgram=%w", err, dErr)
		}

		return &linuxRawSocket{sendFD: -1, conn: conn, ipv6: true, recvPool: newRecvBufferPool()}, nil
	}

	conn, err := icmp.ListenPacket("ip6:ipv6-icmp", "::")
	if err != nil {
		if closeErr := syscall.Close(fd); closeErr != nil {
			return nil, fmt.Errorf("create ICMPv6 listener: %w", errors.Join(err, fmt.Errorf("close raw socket: %w", closeErr)))
		}

		return nil, fmt.Errorf("create ICMPv6 listener: %w", err)
	}

	return &linuxRawSocket{sendFD: fd, conn: conn, ipv6: true, recvPool: newRecvBufferPool()}, nil
}

func (s *linuxRawSocket) IsIPv6() bool {
	return s.ipv6
}

func (s *linuxRawSocket) SendICMP(dst net.IP, ttl, id, seq int, payload []byte) error {
	proto := 1 // ICMPv4
	if s.ipv6 {
		proto = 58 // ICMPv6
	}

	s.sendBuf = prepareICMPEchoPacket(s.sendBuf, payload, id, seq, s.ipv6)

	if s.sendFD >= 0 {
		return s.sendRaw(dst, ttl, s.sendBuf)
	}

	// SOCK_DGRAM fallback: set TTL via PacketConn control.
	if s.ipv6 {
		if err := s.conn.IPv6PacketConn().SetHopLimit(ttl); err != nil {
			return fmt.Errorf("set hop limit: %w", err)
		}
	}
	if !s.ipv6 {
		if err := s.conn.IPv4PacketConn().SetTTL(ttl); err != nil {
			return fmt.Errorf("set TTL: %w", err)
		}
	}

	addr := &net.UDPAddr{IP: dst, Port: proto}
	if _, err := s.conn.WriteTo(s.sendBuf, addr); err != nil {
		return fmt.Errorf("send ICMP: %w", err)
	}

	return nil
}

func (s *linuxRawSocket) SendUDP(dst net.IP, ttl, srcPort, dstPort int, payload []byte) (err error) {
	if s.sendFD < 0 {
		return errUDPProbeRequiresRawSocket
	}

	// Create a UDP socket with controlled TTL.
	family := syscall.AF_INET
	if s.ipv6 {
		family = syscall.AF_INET6
	}

	fd, err := syscall.Socket(family, syscall.SOCK_DGRAM, syscall.IPPROTO_UDP)
	if err != nil {
		return fmt.Errorf("create UDP socket: %w", err)
	}
	defer func() {
		if closeErr := syscall.Close(fd); closeErr != nil && err == nil {
			err = fmt.Errorf("close UDP socket: %w", closeErr)
		}
	}()

	if s.ipv6 {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl); err != nil {
			return fmt.Errorf("set hop limit: %w", err)
		}
	}
	if !s.ipv6 {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
			return fmt.Errorf("set TTL: %w", err)
		}
	}

	// Bind to source port.
	if s.ipv6 {
		sa := &syscall.SockaddrInet6{Port: srcPort}
		if err := syscall.Bind(fd, sa); err != nil {
			return fmt.Errorf("bind UDP6: %w", err)
		}

		dstSA := &syscall.SockaddrInet6{Port: dstPort}
		copy(dstSA.Addr[:], dst.To16())

		return syscall.Sendto(fd, payload, 0, dstSA)
	}

	sa := &syscall.SockaddrInet4{Port: srcPort}
	if err := syscall.Bind(fd, sa); err != nil {
		return fmt.Errorf("bind UDP: %w", err)
	}

	dstSA := &syscall.SockaddrInet4{Port: dstPort}
	copy(dstSA.Addr[:], dst.To4())

	return syscall.Sendto(fd, payload, 0, dstSA)
}

func (s *linuxRawSocket) SendTCP(dst net.IP, ttl, srcPort, dstPort int) (err error) {
	// Create a TCP socket with controlled TTL/hop-limit.
	family := syscall.AF_INET
	if s.ipv6 {
		family = syscall.AF_INET6
	}

	fd, err := syscall.Socket(family, syscall.SOCK_STREAM, syscall.IPPROTO_TCP)
	if err != nil {
		return fmt.Errorf("create TCP socket: %w", err)
	}
	defer func() {
		if closeErr := syscall.Close(fd); closeErr != nil && err == nil {
			err = fmt.Errorf("close TCP socket: %w", closeErr)
		}
	}()

	if s.ipv6 {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl); err != nil {
			return fmt.Errorf("set TCP hop limit: %w", err)
		}
	}
	if !s.ipv6 {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
			return fmt.Errorf("set TCP TTL: %w", err)
		}
	}

	// Non-blocking connect lets us dispatch SYN probes without stalling on connect timeouts.
	if err := syscall.SetNonblock(fd, true); err != nil {
		return fmt.Errorf("set TCP nonblock: %w", err)
	}

	if s.ipv6 {
		sa := &syscall.SockaddrInet6{Port: srcPort}
		if err := syscall.Bind(fd, sa); err != nil {
			return fmt.Errorf("bind TCP6: %w", err)
		}

		dstSA := &syscall.SockaddrInet6{Port: dstPort}
		copy(dstSA.Addr[:], dst.To16())
		err = syscall.Connect(fd, dstSA)
	}
	if !s.ipv6 {
		sa := &syscall.SockaddrInet4{Port: srcPort}
		if err := syscall.Bind(fd, sa); err != nil {
			return fmt.Errorf("bind TCP: %w", err)
		}

		dstSA := &syscall.SockaddrInet4{Port: dstPort}
		copy(dstSA.Addr[:], dst.To4())
		err = syscall.Connect(fd, dstSA)
	}

	// These indicate the SYN probe has been dispatched/asynchronously in progress.
	if err == nil ||
		errors.Is(err, syscall.EINPROGRESS) ||
		errors.Is(err, syscall.EALREADY) ||
		errors.Is(err, syscall.EINTR) ||
		errors.Is(err, syscall.EWOULDBLOCK) ||
		errors.Is(err, syscall.ECONNREFUSED) {
		return nil
	}

	return fmt.Errorf("connect TCP probe: %w", err)
}

func (s *linuxRawSocket) sendRaw(dst net.IP, ttl int, data []byte) error {
	if s.ipv6 {
		if err := syscall.SetsockoptInt(s.sendFD, syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl); err != nil {
			return fmt.Errorf("set hop limit: %w", err)
		}

		sa := &syscall.SockaddrInet6{Port: 0}
		copy(sa.Addr[:], dst.To16())

		return syscall.Sendto(s.sendFD, data, 0, sa)
	}

	if err := syscall.SetsockoptInt(s.sendFD, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
		return fmt.Errorf("set TTL: %w", err)
	}

	sa := &syscall.SockaddrInet4{Port: 0}
	copy(sa.Addr[:], dst.To4())

	return syscall.Sendto(s.sendFD, data, 0, sa)
}

func (s *linuxRawSocket) Receive(deadline time.Time) (*ICMPResponse, error) {
	if err := s.conn.SetReadDeadline(deadline); err != nil {
		return nil, fmt.Errorf("set deadline: %w", err)
	}

	buf := s.recvPool.get(recvBufSize)

	n, peer, err := s.conn.ReadFrom(buf)
	if err != nil {
		s.recvPool.put(buf)
		return nil, err
	}

	recvTime := time.Now()
	buf = buf[:n]

	resp := &ICMPResponse{
		RecvTime: recvTime,
		recvBuf:  buf,
		recvPool: &s.recvPool,
	}

	// Parse peer address.
	switch addr := peer.(type) {
	case *net.IPAddr:
		resp.SrcAddr = addr.IP
	case *net.UDPAddr:
		resp.SrcAddr = addr.IP
	}

	if s.ipv6 {
		parsed, parseErr := s.parseICMPv6(buf, resp)
		if parseErr != nil {
			resp.Release()
		}
		return parsed, parseErr
	}

	parsed, parseErr := s.parseICMPv4(buf, resp)
	if parseErr != nil {
		resp.Release()
	}
	return parsed, parseErr
}

func (s *linuxRawSocket) parseICMPv4(buf []byte, resp *ICMPResponse) (*ICMPResponse, error) {
	if len(buf) < icmpHeaderLen {
		return nil, errShortICMPHeader
	}

	resp.Type = int(buf[0])
	resp.Code = int(buf[1])
	resp.Payload = buf[icmpHeaderLen:]

	switch resp.Type {
	case icmpv4EchoReply:
		if len(buf) >= icmpHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(buf[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(buf[6:8]))
		}

	case icmpv4TimeExceeded, icmpv4DstUnreach:
		resp.ICMPLengthField = int(buf[5])
		s.parseInnerPacketV4(resp)
	}

	return resp, nil
}

func (s *linuxRawSocket) parseInnerPacketV4(resp *ICMPResponse) {
	// The payload contains the original IP header + at least 8 bytes
	// of the original datagram.
	inner := resp.Payload
	if len(inner) < ipv4HeaderMinLen+icmpHeaderLen {
		return
	}

	ihl := int(inner[0]&0x0f) * 4 //nolint:mnd
	if ihl < ipv4HeaderMinLen || len(inner) < ihl+icmpHeaderLen {
		return
	}

	resp.InnerSrcAddr = net.IP(inner[12:16]).To16()
	resp.InnerDstAddr = net.IP(inner[16:20]).To16()

	proto := inner[9]
	icmpData := inner[ihl:]

	switch proto {
	case syscall.IPPROTO_ICMP:
		// Inner ICMP: extract ID and Seq from the original Echo Request.
		if len(icmpData) >= icmpHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(icmpData[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(icmpData[6:8]))
		}
	case syscall.IPPROTO_UDP:
		// Inner UDP: extract destination port as sequence.
		if len(icmpData) >= 4 { //nolint:mnd
			resp.InnerSeq = int(binary.BigEndian.Uint16(icmpData[2:4]))
		}
	case syscall.IPPROTO_TCP:
		// Inner TCP: extract destination port as sequence.
		if len(icmpData) >= 4 { //nolint:mnd
			resp.InnerSeq = int(binary.BigEndian.Uint16(icmpData[2:4]))
		}
	}
}

func (s *linuxRawSocket) parseICMPv6(buf []byte, resp *ICMPResponse) (*ICMPResponse, error) {
	if len(buf) < icmpHeaderLen {
		return nil, errShortICMPv6Header
	}

	resp.Type = int(buf[0])
	resp.Code = int(buf[1])
	resp.Payload = buf[icmpHeaderLen:]

	switch resp.Type {
	case icmpv6EchoReply:
		if len(buf) >= icmpHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(buf[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(buf[6:8]))
		}

	case icmpv6TimeExceeded, icmpv6DstUnreach:
		s.parseInnerPacketV6(resp)
	}

	return resp, nil
}

func (s *linuxRawSocket) parseInnerPacketV6(resp *ICMPResponse) {
	inner := resp.Payload
	// IPv6 header is always 40 bytes.
	const ipv6HeaderLen = 40

	if len(inner) < ipv6HeaderLen+icmpHeaderLen {
		return
	}

	resp.InnerSrcAddr = net.IP(inner[8:24]).To16()
	resp.InnerDstAddr = net.IP(inner[24:40]).To16()

	nextHeader := inner[6]
	transportData := inner[ipv6HeaderLen:]

	switch nextHeader {
	case syscall.IPPROTO_ICMPV6:
		if len(transportData) >= icmpHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(transportData[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(transportData[6:8]))
		}
	case syscall.IPPROTO_UDP:
		if len(transportData) >= 4 { //nolint:mnd
			resp.InnerSeq = int(binary.BigEndian.Uint16(transportData[2:4]))
		}
	case syscall.IPPROTO_TCP:
		if len(transportData) >= 4 { //nolint:mnd
			resp.InnerSeq = int(binary.BigEndian.Uint16(transportData[2:4]))
		}
	}
}

func (s *linuxRawSocket) Close() error {
	var firstErr error

	if s.sendFD >= 0 {
		if err := syscall.Close(s.sendFD); err != nil {
			firstErr = err
		}
	}

	if s.conn != nil {
		if err := s.conn.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}

	return firstErr
}
