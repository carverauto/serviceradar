//go:build darwin

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
	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"
)

const (
	darwinICMPv4EchoReply    = 0
	darwinICMPv4TimeExceeded = 11
	darwinICMPv4DstUnreach   = 3

	darwinICMPv6EchoReply    = 129
	darwinICMPv6TimeExceeded = 3
	darwinICMPv6DstUnreach   = 1

	darwinIPv4HeaderMinLen = 20
	darwinICMPHeaderLen    = 8
	darwinRecvBufSize      = 1500
)

var (
	errShortICMPHeader   = errors.New("packet too short for ICMP header")
	errShortICMPv6Header = errors.New("packet too short for ICMPv6 header")
)

// darwinRawSocket implements RawSocket using macOS raw sockets.
// On macOS, raw sockets include the IP header in received packets,
// and IP header length field uses host byte order.
type darwinRawSocket struct {
	sendFD int
	conn   *icmp.PacketConn
	ipv6   bool
}

// NewRawSocket creates a new raw socket for ICMP probing on macOS.
func NewRawSocket(ipv6mode bool) (RawSocket, error) {
	if ipv6mode {
		return newDarwinRawSocket6()
	}

	return newDarwinRawSocket4()
}

func newDarwinRawSocket4() (RawSocket, error) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("create raw socket (need root): %w", err)
	}

	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		if closeErr := syscall.Close(fd); closeErr != nil {
			return nil, fmt.Errorf("create ICMP listener: %w", errors.Join(err, fmt.Errorf("close raw socket: %w", closeErr)))
		}

		return nil, fmt.Errorf("create ICMP listener: %w", err)
	}

	return &darwinRawSocket{sendFD: fd, conn: conn, ipv6: false}, nil
}

func newDarwinRawSocket6() (RawSocket, error) {
	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_RAW, syscall.IPPROTO_ICMPV6)
	if err != nil {
		return nil, fmt.Errorf("create raw ICMPv6 socket (need root): %w", err)
	}

	conn, err := icmp.ListenPacket("ip6:ipv6-icmp", "::")
	if err != nil {
		if closeErr := syscall.Close(fd); closeErr != nil {
			return nil, fmt.Errorf("create ICMPv6 listener: %w", errors.Join(err, fmt.Errorf("close raw socket: %w", closeErr)))
		}

		return nil, fmt.Errorf("create ICMPv6 listener: %w", err)
	}

	return &darwinRawSocket{sendFD: fd, conn: conn, ipv6: true}, nil
}

func (s *darwinRawSocket) IsIPv6() bool {
	return s.ipv6
}

func (s *darwinRawSocket) SendICMP(dst net.IP, ttl, id, seq int, payload []byte) error {
	var msgType icmp.Type
	if s.ipv6 {
		msgType = ipv6.ICMPTypeEchoRequest
	} else {
		msgType = ipv4.ICMPTypeEcho
	}

	msg := icmp.Message{
		Type: msgType,
		Code: 0,
		Body: &icmp.Echo{
			ID:   id,
			Seq:  seq,
			Data: payload,
		},
	}

	data, err := msg.Marshal(nil)
	if err != nil {
		return fmt.Errorf("marshal ICMP: %w", err)
	}

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

func (s *darwinRawSocket) SendUDP(dst net.IP, ttl, srcPort, dstPort int, payload []byte) (err error) {
	var family int
	if s.ipv6 {
		family = syscall.AF_INET6
	} else {
		family = syscall.AF_INET
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

		sa := &syscall.SockaddrInet6{Port: srcPort}
		if err := syscall.Bind(fd, sa); err != nil {
			return fmt.Errorf("bind UDP6: %w", err)
		}

		dstSA := &syscall.SockaddrInet6{Port: dstPort}
		copy(dstSA.Addr[:], dst.To16())

		return syscall.Sendto(fd, payload, 0, dstSA)
	}

	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
		return fmt.Errorf("set TTL: %w", err)
	}

	sa := &syscall.SockaddrInet4{Port: srcPort}
	if err := syscall.Bind(fd, sa); err != nil {
		return fmt.Errorf("bind UDP: %w", err)
	}

	dstSA := &syscall.SockaddrInet4{Port: dstPort}
	copy(dstSA.Addr[:], dst.To4())

	return syscall.Sendto(fd, payload, 0, dstSA)
}

func (s *darwinRawSocket) SendTCP(dst net.IP, ttl, srcPort, dstPort int) (err error) {
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
	} else {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl); err != nil {
			return fmt.Errorf("set TCP TTL: %w", err)
		}
	}

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
	} else {
		sa := &syscall.SockaddrInet4{Port: srcPort}
		if err := syscall.Bind(fd, sa); err != nil {
			return fmt.Errorf("bind TCP: %w", err)
		}

		dstSA := &syscall.SockaddrInet4{Port: dstPort}
		copy(dstSA.Addr[:], dst.To4())
		err = syscall.Connect(fd, dstSA)
	}

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

func (s *darwinRawSocket) Receive(deadline time.Time) (*ICMPResponse, error) {
	if err := s.conn.SetReadDeadline(deadline); err != nil {
		return nil, fmt.Errorf("set deadline: %w", err)
	}

	buf := getRecvBuffer(darwinRecvBufSize)

	n, peer, err := s.conn.ReadFrom(buf)
	if err != nil {
		putRecvBuffer(buf)
		return nil, err
	}

	recvTime := time.Now()
	buf = buf[:n]

	resp := &ICMPResponse{
		RecvTime: recvTime,
		recvBuf:  buf,
	}

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

func (s *darwinRawSocket) parseICMPv4(buf []byte, resp *ICMPResponse) (*ICMPResponse, error) {
	if len(buf) < darwinICMPHeaderLen {
		return nil, errShortICMPHeader
	}

	resp.Type = int(buf[0])
	resp.Code = int(buf[1])
	resp.Payload = buf[darwinICMPHeaderLen:]

	switch resp.Type {
	case darwinICMPv4EchoReply:
		if len(buf) >= darwinICMPHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(buf[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(buf[6:8]))
		}

	case darwinICMPv4TimeExceeded, darwinICMPv4DstUnreach:
		resp.ICMPLengthField = int(buf[5])
		s.parseInnerPacketV4(resp)
	}

	return resp, nil
}

func (s *darwinRawSocket) parseInnerPacketV4(resp *ICMPResponse) {
	inner := resp.Payload
	if len(inner) < darwinIPv4HeaderMinLen+darwinICMPHeaderLen {
		return
	}

	ihl := int(inner[0]&0x0f) * 4 //nolint:mnd
	if ihl < darwinIPv4HeaderMinLen || len(inner) < ihl+darwinICMPHeaderLen {
		return
	}

	resp.InnerSrcAddr = net.IP(inner[12:16]).To16()
	resp.InnerDstAddr = net.IP(inner[16:20]).To16()

	proto := inner[9]
	icmpData := inner[ihl:]

	switch proto {
	case syscall.IPPROTO_ICMP:
		if len(icmpData) >= darwinICMPHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(icmpData[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(icmpData[6:8]))
		}
	case syscall.IPPROTO_UDP:
		if len(icmpData) >= 4 { //nolint:mnd
			resp.InnerSeq = int(binary.BigEndian.Uint16(icmpData[2:4]))
		}
	case syscall.IPPROTO_TCP:
		if len(icmpData) >= 4 { //nolint:mnd
			resp.InnerSeq = int(binary.BigEndian.Uint16(icmpData[2:4]))
		}
	}
}

func (s *darwinRawSocket) parseICMPv6(buf []byte, resp *ICMPResponse) (*ICMPResponse, error) {
	if len(buf) < darwinICMPHeaderLen {
		return nil, errShortICMPv6Header
	}

	resp.Type = int(buf[0])
	resp.Code = int(buf[1])
	resp.Payload = buf[darwinICMPHeaderLen:]

	switch resp.Type {
	case darwinICMPv6EchoReply:
		if len(buf) >= darwinICMPHeaderLen {
			resp.InnerID = int(binary.BigEndian.Uint16(buf[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(buf[6:8]))
		}

	case darwinICMPv6TimeExceeded, darwinICMPv6DstUnreach:
		s.parseInnerPacketV6(resp)
	}

	return resp, nil
}

func (s *darwinRawSocket) parseInnerPacketV6(resp *ICMPResponse) {
	inner := resp.Payload
	const ipv6HeaderLen = 40

	if len(inner) < ipv6HeaderLen+darwinICMPHeaderLen {
		return
	}

	resp.InnerSrcAddr = net.IP(inner[8:24]).To16()
	resp.InnerDstAddr = net.IP(inner[24:40]).To16()

	nextHeader := inner[6]
	transportData := inner[ipv6HeaderLen:]

	switch nextHeader {
	case syscall.IPPROTO_ICMPV6:
		if len(transportData) >= darwinICMPHeaderLen {
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

func (s *darwinRawSocket) Close() error {
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
