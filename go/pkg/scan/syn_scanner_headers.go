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
)

// IPv4
type IPv4Hdr struct {
	IHL      uint8
	Protocol uint8
	SrcIP    net.IP
	DstIP    net.IP
}

func parseIPv4(b []byte) (*IPv4Hdr, int, error) {
	if len(b) < ipv4HeaderMinSize {
		return nil, 0, ErrShortIPv4Header
	}

	vihl := b[0]
	if vihl>>4 != ipv4Version {
		return nil, 0, ErrNotIPv4
	}

	ihl := vihl & 0x0F

	hdrLen := int(ihl) * 4

	if hdrLen < ipv4HeaderMinSize || len(b) < hdrLen {
		return nil, 0, ErrBadIPv4HeaderLength
	}

	return &IPv4Hdr{
		IHL:      ihl,
		Protocol: b[9],
		SrcIP:    net.IPv4(b[12], b[13], b[14], b[15]),
		DstIP:    net.IPv4(b[16], b[17], b[18], b[19]),
	}, hdrLen, nil
}

// IPv6
type IPv6Hdr struct {
	NextHeader uint8
	SrcIP      net.IP
	DstIP      net.IP
}

func parseIPv6(b []byte) (*IPv6Hdr, int, error) {
	if len(b) < ipv6HeaderSize {
		return nil, 0, ErrShortIPv6Header
	}

	if b[0]>>4 != ipv6Version {
		return nil, 0, ErrNotIPv6
	}

	return &IPv6Hdr{
		NextHeader: b[6],
		SrcIP:      append(net.IP(nil), b[8:24]...),
		DstIP:      append(net.IP(nil), b[24:40]...),
	}, ipv6HeaderSize, nil
}

// TCP
type TCPHdr struct {
	SrcPort uint16
	DstPort uint16
	Seq     uint32
	Ack     uint32
	Flags   uint8
}

func parseTCP(b []byte) (*TCPHdr, int, error) {
	if len(b) < tcpHeaderMinSize {
		return nil, 0, ErrShortTCPHeader
	}

	dataOff := (b[12] >> 4) & 0x0F
	hdrLen := int(dataOff) * 4

	if hdrLen < tcpHeaderMinSize || len(b) < hdrLen {
		return nil, 0, ErrBadTCPHeaderLength
	}

	return &TCPHdr{
		SrcPort: binary.BigEndian.Uint16(b[0:2]),
		DstPort: binary.BigEndian.Uint16(b[2:4]),
		Seq:     binary.BigEndian.Uint32(b[4:8]),
		Ack:     binary.BigEndian.Uint32(b[8:12]),
		Flags:   b[13],
	}, hdrLen, nil
}
