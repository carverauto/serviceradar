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
	"net"
	"syscall"
)

// processEthernetFrame parses an Ethernet frame and extracts TCP response information.
func (s *SYNScanner) processEthernetFrame(frame []byte) {
	reply, ok := parseTCPReplyFromEthernet(frame)
	if ok {
		s.processTCPReply(reply.srcIP, reply.tcp)
		return
	}

	icmpv6Reply, ok := parseICMPv6ErrorFromEthernet(frame)
	if ok {
		s.processICMPv6Error(icmpv6Reply)
	}
}

type tcpReplyFrame struct {
	srcIP net.IP
	tcp   *TCPHdr
}

func parseTCPReplyFromEthernet(frame []byte) (tcpReplyFrame, bool) {
	ethType, l3off, err := ethernetL3(frame)
	if err != nil {
		return tcpReplyFrame{}, false
	}

	switch ethType {
	case etherTypeIPv4:
		return parseIPv4TCPReply(frame, l3off)
	case etherTypeIPv6:
		return parseIPv6TCPReply(frame, l3off)
	default:
		return tcpReplyFrame{}, false
	}
}

type icmpv6ErrorFrame struct {
	targetIP   net.IP
	srcPort    uint16
	targetPort uint16
	err        error
}

func parseICMPv6ErrorFromEthernet(frame []byte) (icmpv6ErrorFrame, bool) {
	ethType, l3off, err := ethernetL3(frame)
	if err != nil || ethType != etherTypeIPv6 || len(frame) < l3off+ipv6HeaderSize+icmpv6HeaderSize {
		return icmpv6ErrorFrame{}, false
	}

	ip, ipLen, err := parseIPv6(frame[l3off:])
	if err != nil || ip.NextHeader != ipProtoICMPv6 {
		return icmpv6ErrorFrame{}, false
	}

	icmpOff := l3off + ipLen
	icmpType := frame[icmpOff]

	var resultErr error
	switch icmpType {
	case icmpv6DstUnreach:
		resultErr = ErrPortClosed
	case icmpv6PacketTooBig:
		resultErr = ErrICMPv6PacketTooBig
	case icmpv6TimeExceeded:
		resultErr = ErrICMPv6TimeExceeded
	default:
		return icmpv6ErrorFrame{}, false
	}

	embeddedOff := icmpOff + icmpv6HeaderSize
	embeddedIP, embeddedIPLen, err := parseIPv6(frame[embeddedOff:])
	if err != nil || embeddedIP.NextHeader != syscall.IPPROTO_TCP {
		return icmpv6ErrorFrame{}, false
	}

	tcpOff := embeddedOff + embeddedIPLen
	if len(frame) < tcpOff+tcpHeaderMinSize {
		return icmpv6ErrorFrame{}, false
	}

	tcp, _, err := parseTCP(frame[tcpOff:])
	if err != nil {
		return icmpv6ErrorFrame{}, false
	}

	return icmpv6ErrorFrame{targetIP: embeddedIP.DstIP, srcPort: tcp.SrcPort, targetPort: tcp.DstPort, err: resultErr}, true
}

func parseIPv4TCPReply(frame []byte, l3off int) (tcpReplyFrame, bool) {
	if len(frame) < l3off+ipv4HeaderMinSize {
		return tcpReplyFrame{}, false
	}
	ip, ipLen, err := parseIPv4(frame[l3off:])
	if err != nil || ip.Protocol != syscall.IPPROTO_TCP {
		return tcpReplyFrame{}, false
	}
	if len(frame) < l3off+ipLen+tcpHeaderMinSize {
		return tcpReplyFrame{}, false
	}

	tcp, _, err := parseTCP(frame[l3off+ipLen:])
	if err != nil {
		return tcpReplyFrame{}, false
	}

	return tcpReplyFrame{srcIP: ip.SrcIP, tcp: tcp}, true
}

func parseIPv6TCPReply(frame []byte, l3off int) (tcpReplyFrame, bool) {
	if len(frame) < l3off+ipv6HeaderSize {
		return tcpReplyFrame{}, false
	}
	ip, ipLen, err := parseIPv6(frame[l3off:])
	if err != nil || ip.NextHeader != syscall.IPPROTO_TCP {
		return tcpReplyFrame{}, false
	}
	if len(frame) < l3off+ipLen+tcpHeaderMinSize {
		return tcpReplyFrame{}, false
	}

	tcp, _, err := parseTCP(frame[l3off+ipLen:])
	if err != nil {
		return tcpReplyFrame{}, false
	}

	return tcpReplyFrame{srcIP: ip.SrcIP, tcp: tcp}, true
}

func sameCanonicalIPString(a, b string) bool {
	if a == "" || b == "" {
		return false
	}

	return canonicalIPString(a) == canonicalIPString(b)
}

func (s *SYNScanner) processTCPReply(srcIP net.IP, tcp *TCPHdr) {
	var resultErr error
	available := false

	switch {
	case tcp.Flags&(synFlag|ackFlag) == (synFlag | ackFlag):
		available = true
	case tcp.Flags&rstFlag != 0:
		resultErr = ErrPortClosed
	default:
		return
	}

	s.processTCPFinalResult(srcIP, tcp.DstPort, tcp.SrcPort, available, resultErr)
}

func (s *SYNScanner) processICMPv6Error(reply icmpv6ErrorFrame) {
	s.processTCPFinalResult(reply.targetIP, reply.srcPort, reply.targetPort, false, reply.err)
}
