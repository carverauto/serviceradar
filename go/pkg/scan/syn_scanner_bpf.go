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
	"errors"
	"fmt"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

const packetFanoutGroupIDMask = 0xFFFF

var errInvalidFanoutGroup = errors.New("invalid packet fanout group ID")

// BPF + Fanout
// TODO: double-tag (QinQ) variant or an auxdata-aware approach
func attachBPF(fd int, localIP4, localIP6 net.IP, sportLo, sportHi uint16) error {
	ip6 := localIP6.To16()
	if ip6 == nil || localIP6.To4() != nil {
		return attachBPFIPv4(fd, localIP4, sportLo, sportHi)
	}

	ip4 := localIP4.To4()
	if ip4 == nil {
		return ErrNonIPv4LocalIP
	}

	ipHi := uint32(binary.BigEndian.Uint16(ip4[0:2]))
	ipLo := uint32(binary.BigEndian.Uint16(ip4[2:4]))
	lo := uint32(sportLo)
	hi := uint32(sportHi)

	v6 := [4]uint32{
		binary.BigEndian.Uint32(ip6[0:4]),
		binary.BigEndian.Uint32(ip6[4:8]),
		binary.BigEndian.Uint32(ip6[8:12]),
		binary.BigEndian.Uint32(ip6[12:16]),
	}

	prog := []unix.SockFilter{
		// Non-VLAN dispatch.
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 12},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherTypeVLAN, Jt: 27, Jf: 0},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherTypeQinQ, Jt: 26, Jf: 0},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherType9100, Jt: 25, Jf: 0},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherTypeIPv4, Jt: 2, Jf: 0},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherTypeIPv6, Jt: 13, Jf: 0},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// Non-VLAN IPv4 TCP replies to the scanner source-port range.
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 23},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: syscall.IPPROTO_TCP, Jt: 0, Jf: 9},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 30},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipHi, Jt: 0, Jf: 7},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 32},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipLo, Jt: 0, Jf: 5},
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 14},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 16},
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// Non-VLAN IPv6 packets destined to the scanner's local IPv6.
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 38},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[0], Jt: 0, Jf: 7},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 42},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[1], Jt: 0, Jf: 5},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 46},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[2], Jt: 0, Jf: 3},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 50},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[3], Jt: 0, Jf: 1},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// VLAN dispatch.
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 16},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherTypeIPv4, Jt: 1, Jf: 0},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: etherTypeIPv6, Jt: 12, Jf: 21},

		// VLAN IPv4 TCP replies to the scanner source-port range.
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 27},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: syscall.IPPROTO_TCP, Jt: 0, Jf: 9},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 34},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipHi, Jt: 0, Jf: 7},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 36},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipLo, Jt: 0, Jf: 5},
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 18},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 20},
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// VLAN IPv6 packets destined to the scanner's local IPv6.
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 42},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[0], Jt: 0, Jf: 7},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 46},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[1], Jt: 0, Jf: 5},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 50},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[2], Jt: 0, Jf: 3},
		{Code: unix.BPF_LD | unix.BPF_W | unix.BPF_ABS, K: 54},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: v6[3], Jt: 0, Jf: 1},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
	}

	fprog := unix.SockFprog{Len: uint16(len(prog)), Filter: &prog[0]}

	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &fprog)
}

func attachBPFIPv4(fd int, localIP net.IP, sportLo, sportHi uint16) error {
	ip4 := localIP.To4()
	if ip4 == nil {
		return ErrNonIPv4LocalIP
	}

	// Compare IP halves as host-order 16-bit values (cBPF ldh returns host-order).
	ipHi := uint32(binary.BigEndian.Uint16(ip4[0:2]))
	ipLo := uint32(binary.BigEndian.Uint16(ip4[2:4]))

	// IMPORTANT: cBPF 'ldh' loads are host-endian; do NOT htons() these.
	lo := uint32(sportLo)
	hi := uint32(sportHi)

	prog := []unix.SockFilter{
		//  0: EtherType @ [12]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 12},
		//  1: vlan? (0x8100) -> VLAN block @18
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x8100, Jt: 16, Jf: 0},
		//  2: vlan? (0x88a8) -> VLAN block @18
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x88A8, Jt: 15, Jf: 0},
		//  3: vlan? (0x9100) -> VLAN block @18
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x9100, Jt: 14, Jf: 0},

		// Non‑VLAN path (IPv4 at L2+14)
		//  4: if EtherType != IPv4 -> drop (5)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x0800, Jt: 1, Jf: 0},
		//  5: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
		//  6: proto @ [23]
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 23},
		//  7: if proto != TCP -> drop (-> 17)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 6, Jt: 0, Jf: 9},
		//  8: dst ip upper 16 @ [30]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 30},
		//  9: if upper != local -> drop (-> 17)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipHi, Jt: 0, Jf: 7},
		// 10: dst ip lower 16 @ [32]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 32},
		// 11: if lower != local -> drop (-> 17)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipLo, Jt: 0, Jf: 5},
		// 12: X = 4*(IHL) @ [14]
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 14},
		// 13: tcp dport @ [16+X]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 16},
		// 14: if dport < lo -> drop (-> 17)
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		// 15: if dport > hi -> drop (-> 17)
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		// 16: accept
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		// 17: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// VLAN path (single tag; IPv4 at L2+18)
		// 18: inner EtherType @ [16]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 16},
		// 19: if inner EtherType != IPv4 -> drop (-> 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x0800, Jt: 0, Jf: 11},
		// 20: proto @ [27]
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 27},
		// 21: if proto != TCP -> drop (-> 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 6, Jt: 0, Jf: 9},
		// 22: dst ip upper 16 @ [34]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 34},
		// 23: if upper != local -> drop (-> 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipHi, Jt: 0, Jf: 7},
		// 24: dst ip lower 16 @ [36]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 36},
		// 25: if lower != local -> drop (-> 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipLo, Jt: 0, Jf: 5},
		// 26: X = 4*(IHL) @ [18]
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 18},
		// 27: tcp dport @ [20+X]  (18 + 2 + X)
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 20},
		// 28: if dport < lo -> drop (-> 31)
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		// 29: if dport > hi -> drop (-> 31)
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		// 30: accept
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		// 31: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
	}

	fprog := unix.SockFprog{Len: uint16(len(prog)), Filter: &prog[0]}

	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &fprog)
}

// createFanoutGroup asks the kernel to allocate a group ID that is unique in
// the current network namespace. The first ring creates the group; the
// scanner's remaining rings join it through enableFanout.
//
// Using a process-derived group ID here is not sufficient: every SYNScanner in
// one agent process would join the same PACKET_FANOUT group, causing the kernel
// to load-balance replies across scanners with unrelated source-port maps.
func createFanoutGroup(fd int) (int, error) {
	mode := unix.PACKET_FANOUT_HASH | unix.PACKET_FANOUT_FLAG_DEFRAG | unix.PACKET_FANOUT_FLAG_UNIQUEID
	val := (mode & packetFanoutGroupIDMask) << 16

	if err := unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_FANOUT, val); err != nil {
		return 0, fmt.Errorf("create unique packet fanout group: %w", err)
	}

	configured, err := unix.GetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_FANOUT)
	if err != nil {
		return 0, fmt.Errorf("read unique packet fanout group: %w", err)
	}

	groupID := configured & packetFanoutGroupIDMask
	return groupID, nil
}

func enableFanout(fd int, groupID int) error {
	// See `man 7 packet`: lower 16 bits = group ID, upper 16 bits = mode|flags.
	// option = (mode|flags)<<16 | groupID
	if groupID < 0 || groupID > packetFanoutGroupIDMask {
		return fmt.Errorf("%w: %d", errInvalidFanoutGroup, groupID)
	}

	mode := unix.PACKET_FANOUT_HASH | unix.PACKET_FANOUT_FLAG_DEFRAG
	val := ((mode & packetFanoutGroupIDMask) << 16) | (groupID & packetFanoutGroupIDMask)

	return unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_FANOUT, val)
}

// AF_PACKET Open/Bind

func openSnifferOnInterface(iFace string) (int, error) {
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(htons(unix.ETH_P_ALL)))
	if err != nil {
		return 0, fmt.Errorf("AF_PACKET socket: %w", err)
	}

	ifi, err := net.InterfaceByName(iFace)
	if err != nil {
		_ = unix.Close(fd)

		return 0, fmt.Errorf("iFace %s: %w", iFace, err)
	}

	sll := &unix.SockaddrLinklayer{Protocol: htons(unix.ETH_P_ALL), Ifindex: ifi.Index}
	if err := unix.Bind(fd, sll); err != nil {
		_ = unix.Close(fd)

		return 0, fmt.Errorf("bind %s: %w", iFace, err)
	}

	return fd, nil
}

// VLAN-aware L2/L3 parsing + cBPF

func ethernetL3(b []byte) (eth uint16, l3off int, err error) {
	if len(b) < ethernetHeaderSize {
		return 0, 0, ErrShortEthernet
	}

	off := 12
	eth = binary.BigEndian.Uint16(b[off : off+2])
	l3off = 14

	// Peel up to two tags (802.1Q / QinQ / 0x9100)
	for i := 0; i < 2; i++ {
		if eth == etherTypeVLAN || eth == etherTypeQinQ || eth == etherType9100 {
			if len(b) < l3off+4 {
				return 0, 0, ErrShortVLANHeader
			}

			// skip TCI (2 bytes) and read inner ethertype
			eth = binary.BigEndian.Uint16(b[l3off+2 : l3off+4])
			l3off += 4
		} else {
			break
		}
	}

	return eth, l3off, nil
}
