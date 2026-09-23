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
	"net"
	"sync"
	"time"
)

const defaultRecvBufferSize = 1500

type recvBufferPool struct {
	pool sync.Pool
}

// ICMPResponse represents a received ICMP packet with metadata.
type ICMPResponse struct {
	// SrcAddr is the IP that sent this ICMP response (the hop router or target).
	SrcAddr net.IP

	// Type is the ICMP message type (e.g., Time Exceeded, Echo Reply).
	Type int

	// Code is the ICMP message code.
	Code int

	// InnerSrcAddr is the source address from the original datagram
	// embedded in the ICMP error message.
	InnerSrcAddr net.IP

	// InnerDstAddr is the destination address from the original datagram.
	InnerDstAddr net.IP

	// InnerID is the ICMP identifier from the original Echo Request
	// (for ICMP probes) or 0 for UDP/TCP.
	InnerID int

	// InnerSeq is the ICMP sequence number from the original Echo Request
	// (for ICMP probes), or the destination port (for UDP/TCP probes).
	InnerSeq int

	// InnerProto is the transport protocol number of the quoted datagram.
	InnerProto int

	// InnerSrcPort and InnerDstPort are the quoted UDP/TCP ports.
	InnerSrcPort int
	InnerDstPort int

	// InnerTCPSeq is the quoted TCP sequence number. ICMP errors quote at least
	// the first 8 transport bytes, which for TCP are the ports and this field.
	InnerTCPSeq uint32

	// RecvTime is when the response was received.
	RecvTime time.Time

	// Payload is the raw ICMP payload (after ICMP header) for MPLS parsing.
	Payload []byte

	// ICMPLengthField is the "length" field from the ICMP header (byte 5),
	// expressed in 32-bit words. Used for RFC 4884 extension parsing.
	ICMPLengthField int

	recvBuf  []byte
	recvPool *recvBufferPool
}

// RawSocket abstracts raw ICMP socket operations for platform portability.
type RawSocket interface {
	// SendICMP sends an ICMP Echo Request with the specified TTL.
	SendICMP(dst net.IP, ttl int, id, seq int, payload []byte) error

	// SendUDP sends a UDP packet with the specified TTL.
	SendUDP(dst net.IP, ttl int, srcPort, dstPort int, payload []byte) error

	// OpenTCPFlow prepares one trace's TCP probe flow toward dst:dstPort.
	// timeout bounds how long a single probe may wait for the target's answer.
	OpenTCPFlow(dst net.IP, dstPort int, timeout time.Duration) (TCPFlow, error)

	// Receive reads the next ICMP response, blocking up to deadline.
	Receive(deadline time.Time) (*ICMPResponse, error)

	// Close releases socket resources.
	Close() error

	// IsIPv6 returns true if this socket operates on IPv6.
	IsIPv6() bool
}

// TCPFlow is one trace's TCP probe flow toward a single destination port.
// Implementations decide how a probe is identified on the wire; the tracer only
// deals in probe sequence numbers.
type TCPFlow interface {
	// SendSYN sends the SYN for probe seq with the given TTL.
	SendSYN(ttl, seq int) error

	// Receive returns the next SYN-ACK or RST from the target on this flow,
	// blocking up to deadline. A timeout returns an error whose Timeout() is true.
	Receive(deadline time.Time) (*TCPReply, error)

	// MatchQuoted maps the transport header quoted in an ICMP error back to the
	// probe that caused it.
	MatchQuoted(resp *ICMPResponse) (seq int, ok bool)

	// Crafted reports whether SYNs are crafted segments sent on one stable flow
	// (the raw-socket path) rather than kernel connect() attempts.
	Crafted() bool

	// Close releases the flow's sockets. The caller stops calling Receive first.
	Close() error
}

// TCPReply is a TCP-level answer from the probe target.
type TCPReply struct {
	// Seq is the probe this reply acknowledges, or -1 when the acknowledgement
	// number matched no probe of this flow.
	Seq int

	// SYNACK and RST report the reply's flags.
	SYNACK bool
	RST    bool

	// RecvTime is when the reply was observed.
	RecvTime time.Time
}

const (
	ipProtoICMP   = 1
	ipProtoTCP    = 6
	ipProtoUDP    = 17
	ipProtoICMPv6 = 58

	tcpFlagSYN = 0x02
	tcpFlagRST = 0x04
	tcpFlagACK = 0x10

	tcpHeaderMinLen = 20
	// tcpSynLen is a 20-byte TCP header plus one 4-byte MSS option.
	tcpSynLen = 24
	// tcpSynWindow is the advertised receive window on probe SYNs.
	tcpSynWindow = 64240
)

// parseQuotedTransport fills the quoted-transport fields of resp from the first
// bytes of the datagram an ICMP error carried back.
func parseQuotedTransport(resp *ICMPResponse, proto byte, data []byte) {
	resp.InnerProto = int(proto)

	switch proto {
	case ipProtoICMP, ipProtoICMPv6:
		if len(data) >= 8 { //nolint:mnd
			resp.InnerID = int(binary.BigEndian.Uint16(data[4:6]))
			resp.InnerSeq = int(binary.BigEndian.Uint16(data[6:8]))
		}
	case ipProtoUDP, ipProtoTCP:
		if len(data) >= 4 { //nolint:mnd
			resp.InnerSrcPort = int(binary.BigEndian.Uint16(data[0:2]))
			resp.InnerDstPort = int(binary.BigEndian.Uint16(data[2:4]))
			resp.InnerSeq = resp.InnerDstPort
		}
		if proto == ipProtoTCP && len(data) >= 8 { //nolint:mnd
			resp.InnerTCPSeq = binary.BigEndian.Uint32(data[4:8])
		}
	}
}

// buildTCPSyn writes a SYN segment (with an MSS option) into buf and returns it.
// src and dst must be the addresses the packet will actually carry, because
// they are part of the checksum pseudo-header.
func buildTCPSyn(buf []byte, src, dst net.IP, srcPort, dstPort int, seq uint32) []byte {
	if cap(buf) < tcpSynLen {
		buf = make([]byte, tcpSynLen)
	}

	seg := buf[:tcpSynLen]
	clear(seg)

	binary.BigEndian.PutUint16(seg[0:2], uint16(srcPort))
	binary.BigEndian.PutUint16(seg[2:4], uint16(dstPort))
	binary.BigEndian.PutUint32(seg[4:8], seq)
	seg[12] = (tcpSynLen / 4) << 4 //nolint:mnd // data offset in 32-bit words
	seg[13] = tcpFlagSYN
	binary.BigEndian.PutUint16(seg[14:16], tcpSynWindow)

	mss := uint16(1460) //nolint:mnd
	if src.To4() == nil {
		mss = 1440 //nolint:mnd
	}

	seg[20] = 2 // MSS option kind
	seg[21] = 4 // option length
	binary.BigEndian.PutUint16(seg[22:24], mss)
	binary.BigEndian.PutUint16(seg[16:18], tcpChecksum(src, dst, seg))

	return seg
}

// tcpChecksum computes the TCP checksum of seg over the IPv4 or IPv6
// pseudo-header. seg's checksum field must be zero.
func tcpChecksum(src, dst net.IP, seg []byte) uint16 {
	var pseudo []byte

	if src4, dst4 := src.To4(), dst.To4(); src4 != nil && dst4 != nil {
		pseudo = make([]byte, 12, 12+len(seg)) //nolint:mnd
		copy(pseudo[0:4], src4)
		copy(pseudo[4:8], dst4)
		pseudo[9] = ipProtoTCP
		binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(seg)))
	} else {
		pseudo = make([]byte, 40, 40+len(seg)) //nolint:mnd
		copy(pseudo[0:16], src.To16())
		copy(pseudo[16:32], dst.To16())
		binary.BigEndian.PutUint32(pseudo[32:36], uint32(len(seg)))
		pseudo[39] = ipProtoTCP
	}

	return checksum(append(pseudo, seg...))
}

// tcpSegment is the subset of a received TCP header the tracer needs.
type tcpSegment struct {
	srcPort int
	dstPort int
	ack     uint32
	flags   byte
}

// parseTCPSegment reads the header of a TCP segment (starting at the TCP
// header, not the IP header).
func parseTCPSegment(b []byte) (tcpSegment, bool) {
	if len(b) < tcpHeaderMinLen {
		return tcpSegment{}, false
	}

	return tcpSegment{
		srcPort: int(binary.BigEndian.Uint16(b[0:2])),
		dstPort: int(binary.BigEndian.Uint16(b[2:4])),
		ack:     binary.BigEndian.Uint32(b[8:12]),
		flags:   b[13],
	}, true
}

// isProbeAnswer reports whether a segment is a target's answer to a SYN: a
// SYN-ACK, or an RST (with or without ACK). Anything else on the flow is noise.
func (seg tcpSegment) isProbeAnswer() bool {
	synAck := seg.flags&(tcpFlagSYN|tcpFlagACK) == tcpFlagSYN|tcpFlagACK
	return synAck || seg.flags&tcpFlagRST != 0
}

// probeTimeoutError is returned by TCPFlow.Receive when the deadline passes.
type probeTimeoutError struct{}

func (probeTimeoutError) Error() string   { return "tcp probe receive timeout" }
func (probeTimeoutError) Timeout() bool   { return true }
func (probeTimeoutError) Temporary() bool { return true }

func newRecvBufferPool() recvBufferPool {
	return recvBufferPool{
		pool: sync.Pool{
			New: func() any {
				buf := make([]byte, defaultRecvBufferSize)
				return &buf
			},
		},
	}
}

func (p *recvBufferPool) get(size int) []byte {
	if p == nil {
		return make([]byte, size)
	}

	buf := *(p.pool.Get().(*[]byte))
	if cap(buf) < size {
		return make([]byte, size)
	}

	return buf[:size]
}

func (p *recvBufferPool) put(buf []byte) {
	if p == nil {
		return
	}
	if cap(buf) < defaultRecvBufferSize {
		return
	}

	reusable := buf[:defaultRecvBufferSize]
	p.pool.Put(&reusable)
}

// Release returns pooled receive storage back to the raw-socket buffer pool.
func (r *ICMPResponse) Release() {
	if r == nil || r.recvBuf == nil {
		return
	}

	r.recvPool.put(r.recvBuf)
	r.recvBuf = nil
	r.recvPool = nil
	r.Payload = nil
}

func prepareICMPEchoPacket(buf []byte, payload []byte, id, seq int, ipv6 bool) []byte {
	packetLen := 8 + len(payload)
	if cap(buf) < packetLen {
		buf = make([]byte, packetLen)
	}

	packet := buf[:packetLen]
	clear(packet)

	packet[0] = icmpEchoRequestType(ipv6)
	packet[1] = 0
	binary.BigEndian.PutUint16(packet[4:6], uint16(id))
	binary.BigEndian.PutUint16(packet[6:8], uint16(seq))
	copy(packet[8:], payload)

	if !ipv6 {
		binary.BigEndian.PutUint16(packet[2:4], checksum(packet))
	}

	return packet
}

func icmpEchoRequestType(ipv6 bool) byte {
	if ipv6 {
		return 128
	}

	return 8
}

func checksum(data []byte) uint16 {
	var sum uint32

	for i := 0; i+1 < len(data); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(data[i : i+2]))
	}

	if len(data)%2 == 1 {
		sum += uint32(data[len(data)-1]) << 8
	}

	for sum > 0xFFFF {
		sum = (sum >> 16) + (sum & 0xFFFF)
	}

	return ^uint16(sum)
}
