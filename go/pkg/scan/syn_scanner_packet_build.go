//go:build linux
// +build linux

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

package scan

import (
	"encoding/binary"
	"net"
	"syscall"

	"github.com/carverauto/serviceradar/go/internal/fastsum"
)

// initPacketTemplate initializes the reusable packet template with static fields
func (s *SYNScanner) initPacketTemplate() {
	// IPv4 header template (20 bytes)
	s.packetTemplate[0] = 0x45 // version=4, ihl=5
	s.packetTemplate[1] = 0    // TOS

	binary.BigEndian.PutUint16(s.packetTemplate[2:], ipv4TcpPacketSize) // total length (20 IP + 20 TCP)

	// ID will be set per packet: s.packetTemplate[4:6]
	binary.BigEndian.PutUint16(s.packetTemplate[6:], 0) // flags+frag

	s.packetTemplate[8] = defaultTTL // TTL
	s.packetTemplate[9] = syscall.IPPROTO_TCP

	// checksum will be set per packet: s.packetTemplate[10:12]
	// src IP will be set per packet: s.packetTemplate[12:16]
	// dst IP will be set per packet: s.packetTemplate[16:20]

	// TCP header template (20 bytes)
	// src port will be set per packet: s.packetTemplate[20:22]
	// dst port will be set per packet: s.packetTemplate[22:24]
	// seq will be set per packet: s.packetTemplate[24:28]
	binary.BigEndian.PutUint32(s.packetTemplate[28:], 0) // ack

	s.packetTemplate[32] = (5 << 4) // data offset=5
	s.packetTemplate[33] = 0x02     // SYN flag

	binary.BigEndian.PutUint16(s.packetTemplate[34:], defaultTCPWindow) // window

	// checksum will be set per packet: s.packetTemplate[36:38]
	binary.BigEndian.PutUint16(s.packetTemplate[38:], 0) // urgent ptr
}

// generateRandomID returns a thread-safe random IP header ID
func (s *SYNScanner) generateRandomID() uint16 {
	s.randMu.Lock()
	id := uint16(s.rand.IntN(maxRandomID))
	s.randMu.Unlock()

	return id
}

// randUint32 returns a thread-safe random uint32 using the scanner's RNG
func (s *SYNScanner) randUint32() uint32 {
	s.randMu.Lock()
	v := s.rand.Uint32()
	s.randMu.Unlock()

	return v
}

// buildSynPacketFromTemplate efficiently builds a SYN packet using the pre-allocated template
func (s *SYNScanner) buildSynPacketFromTemplate(srcIP, destIP net.IP, srcPort, destPort uint16) []byte {
	// Get packet buffer from pool to reduce allocations
	packet := s.packetPool.Get().([]byte)
	copy(packet, s.packetTemplate[:])

	// Set variable IPv4 fields
	id := s.generateRandomID()

	binary.BigEndian.PutUint16(packet[4:], id) // IP ID

	copy(packet[12:16], srcIP.To4())  // src IP
	copy(packet[16:20], destIP.To4()) // dst IP

	// Calculate and set IPv4 checksum using fast path
	binary.BigEndian.PutUint16(packet[10:], 0)
	binary.BigEndian.PutUint16(packet[10:], fastsum.Checksum(packet[:20]))

	// Set variable TCP fields
	binary.BigEndian.PutUint16(packet[20:], srcPort)        // src port
	binary.BigEndian.PutUint16(packet[22:], destPort)       // dst port
	binary.BigEndian.PutUint32(packet[24:], s.randUint32()) // seq

	// Calculate and set TCP checksum using fast path (no payload)
	binary.BigEndian.PutUint16(packet[36:], 0)

	var src4, dst4 [4]byte
	copy(src4[:], srcIP.To4())
	copy(dst4[:], destIP.To4())
	tcpCS := fastsum.TCPv4(src4, dst4, packet[20:40], nil)
	binary.BigEndian.PutUint16(packet[36:], tcpCS)

	return packet
}

func buildSYNPacketIPv6(srcIP, destIP net.IP, srcPort, destPort uint16, seq uint32) []byte {
	src16 := srcIP.To16()
	dst16 := destIP.To16()
	if src16 == nil || dst16 == nil || srcIP.To4() != nil || destIP.To4() != nil {
		return nil
	}

	packet := make([]byte, ipv6TcpPacketSize)

	packet[0] = 0x60
	binary.BigEndian.PutUint16(packet[4:], tcpHeaderMinSize)
	packet[6] = syscall.IPPROTO_TCP
	packet[7] = defaultTTL
	copy(packet[8:24], src16)
	copy(packet[24:40], dst16)

	tcp := packet[ipv6HeaderSize:]
	binary.BigEndian.PutUint16(tcp[0:], srcPort)
	binary.BigEndian.PutUint16(tcp[2:], destPort)
	binary.BigEndian.PutUint32(tcp[4:], seq)
	binary.BigEndian.PutUint32(tcp[8:], 0)
	tcp[12] = 5 << 4
	tcp[13] = synFlag
	binary.BigEndian.PutUint16(tcp[14:], defaultTCPWindow)
	binary.BigEndian.PutUint16(tcp[16:], 0)
	binary.BigEndian.PutUint16(tcp[18:], 0)

	var src, dst [16]byte
	copy(src[:], src16)
	copy(dst[:], dst16)
	binary.BigEndian.PutUint16(tcp[16:], fastsum.TCPv6(src, dst, tcp, nil))

	return packet
}

// Packet Crafting and Utility Functions

// Checksum helpers

func ChecksumNew(data []byte) uint16 { return fastsum.Checksum(data) }

// TCP checksum with IPv4 pseudo-header
func TCPChecksumNew(src, dst net.IP, tcpHdr, payload []byte) uint16 {
	var src4, dst4 [4]byte
	copy(src4[:], src.To4())
	copy(dst4[:], dst.To4())

	return fastsum.TCPv4(src4, dst4, tcpHdr, payload)
}

// TCPChecksumIPv6New computes the TCP checksum with an IPv6 pseudo-header.
func TCPChecksumIPv6New(src, dst net.IP, tcpHdr, payload []byte) uint16 {
	var src16, dst16 [16]byte
	copy(src16[:], src.To16())
	copy(dst16[:], dst.To16())

	return fastsum.TCPv6(src16, dst16, tcpHdr, payload)
}
