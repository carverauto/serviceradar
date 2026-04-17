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

var recvBufferPool = sync.Pool{
	New: func() any {
		return make([]byte, defaultRecvBufferSize)
	},
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

	// RecvTime is when the response was received.
	RecvTime time.Time

	// Payload is the raw ICMP payload (after ICMP header) for MPLS parsing.
	Payload []byte

	// ICMPLengthField is the "length" field from the ICMP header (byte 5),
	// expressed in 32-bit words. Used for RFC 4884 extension parsing.
	ICMPLengthField int

	recvBuf []byte
}

// RawSocket abstracts raw ICMP socket operations for platform portability.
type RawSocket interface {
	// SendICMP sends an ICMP Echo Request with the specified TTL.
	SendICMP(dst net.IP, ttl int, id, seq int, payload []byte) error

	// SendUDP sends a UDP packet with the specified TTL.
	SendUDP(dst net.IP, ttl int, srcPort, dstPort int, payload []byte) error

	// SendTCP sends a TCP SYN probe with the specified TTL.
	SendTCP(dst net.IP, ttl int, srcPort, dstPort int) error

	// Receive reads the next ICMP response, blocking up to deadline.
	Receive(deadline time.Time) (*ICMPResponse, error)

	// Close releases socket resources.
	Close() error

	// IsIPv6 returns true if this socket operates on IPv6.
	IsIPv6() bool
}

func getRecvBuffer(size int) []byte {
	buf := recvBufferPool.Get().([]byte)
	if cap(buf) < size {
		return make([]byte, size)
	}

	return buf[:size]
}

func putRecvBuffer(buf []byte) {
	if cap(buf) < defaultRecvBufferSize {
		return
	}

	recvBufferPool.Put(buf[:defaultRecvBufferSize])
}

// Release returns pooled receive storage back to the raw-socket buffer pool.
func (r *ICMPResponse) Release() {
	if r == nil || r.recvBuf == nil {
		return
	}

	putRecvBuffer(r.recvBuf)
	r.recvBuf = nil
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
