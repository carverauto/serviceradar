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

import "encoding/binary"

// RFC 4884 ICMP Extension Object constants.
const (
	// extHeaderLen is the size of the extension header (version + checksum).
	extHeaderLen = 4
	// extObjHeaderLen is the size of each extension object header.
	extObjHeaderLen = 4

	// MPLS extension class and c-type (RFC 4950).
	mplsExtClass = 1
	mplsExtCType = 1

	// mplsLabelEntryLen is the size of one MPLS label stack entry.
	mplsLabelEntryLen = 4

	// extVersion2 is the RFC 4884 extension structure version.
	extVersion2 = 2

	// minOrigDatagramLen is the minimum original datagram length (128 bytes)
	// before extension data begins in ICMP Time Exceeded / Dest Unreachable.
	minOrigDatagramLen = 128
)

// ParseMPLSFromICMP extracts MPLS label stack entries from ICMP Time Exceeded
// or Destination Unreachable message payloads.
//
// The payload starts after the ICMP header (type + code + checksum + unused/length).
// Per RFC 4884, the ICMP header's "length" field (byte 5, in 32-bit words) indicates
// where the original datagram ends and extensions begin.
//
// Layout:
//
//	[ICMP Header (8 bytes)] ← not included in payload
//	[Original Datagram (length * 4 bytes, min 128)]
//	[Extension Header (4 bytes): version(4 bits) | reserved(12 bits) | checksum(16 bits)]
//	[Extension Object 1]
//	  [Object Header (4 bytes): length(16 bits) | class(8 bits) | c-type(8 bits)]
//	  [Object Data: MPLS label entries (4 bytes each)]
//	[Extension Object 2]
//	...
func ParseMPLSFromICMP(payload []byte, icmpLengthField int) []MPLSLabel {
	// icmpLengthField is the "Length" field from byte 5 of the ICMP header,
	// expressed in 32-bit words. It tells us where the original datagram ends.
	origLen := max(icmpLengthField*4, minOrigDatagramLen) //nolint:mnd

	if len(payload) <= origLen+extHeaderLen {
		return nil
	}

	extData := payload[origLen:]

	// Parse extension header: version must be 2.
	version := extData[0] >> 4 //nolint:mnd
	if version != extVersion2 {
		return nil
	}

	return parseExtensionObjects(extData[extHeaderLen:])
}

// parseExtensionObjects iterates over RFC 4884 extension objects,
// looking for MPLS label stack entries.
func parseExtensionObjects(data []byte) []MPLSLabel {
	var labels []MPLSLabel

	for len(data) >= extObjHeaderLen {
		objLen := int(binary.BigEndian.Uint16(data[0:2]))
		objClass := data[2]
		objCType := data[3]

		if objLen < extObjHeaderLen || objLen > len(data) {
			break
		}

		if objClass == mplsExtClass && objCType == mplsExtCType {
			labels = append(labels, parseMPLSLabelEntries(data[extObjHeaderLen:objLen])...)
		}

		data = data[objLen:]
	}

	return labels
}

// parseMPLSLabelEntries parses MPLS label stack entries from extension object data.
// Each entry is 4 bytes:
//
//	[20-bit label | 3-bit exp | 1-bit S (bottom of stack) | 8-bit TTL]
func parseMPLSLabelEntries(data []byte) []MPLSLabel {
	var labels []MPLSLabel

	for len(data) >= mplsLabelEntryLen {
		entry := binary.BigEndian.Uint32(data[:mplsLabelEntryLen])

		labels = append(labels, MPLSLabel{
			Label: int(entry >> 12),            //nolint:mnd
			Exp:   int((entry >> 9) & 0x07),    //nolint:mnd
			S:     (entry>>8)&0x01 == 1,        //nolint:mnd
			TTL:   int(entry & 0xFF),
		})

		data = data[mplsLabelEntryLen:]
	}

	return labels
}
