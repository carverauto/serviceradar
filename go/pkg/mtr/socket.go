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
	"net"
	"time"
)

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
