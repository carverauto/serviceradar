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
	"testing"
)

func TestParseMPLSFromICMP_NoExtensions(t *testing.T) {
	t.Parallel()

	// Payload shorter than minimum original datagram length.
	payload := make([]byte, 100)
	labels := ParseMPLSFromICMP(payload, 0)

	if labels != nil {
		t.Errorf("expected nil labels, got %+v", labels)
	}
}

func TestParseMPLSFromICMP_WrongVersion(t *testing.T) {
	t.Parallel()

	// Build payload with version 1 extension header.
	payload := make([]byte, minOrigDatagramLen+extHeaderLen+extObjHeaderLen+mplsLabelEntryLen)
	payload[minOrigDatagramLen] = 0x10 // version 1

	labels := ParseMPLSFromICMP(payload, 0)
	if labels != nil {
		t.Errorf("expected nil for version 1, got %+v", labels)
	}
}

func TestParseMPLSFromICMP_SingleLabel(t *testing.T) {
	t.Parallel()

	payload := buildMPLSPayload([]MPLSLabel{
		{Label: 16, Exp: 0, S: true, TTL: 64},
	})

	labels := ParseMPLSFromICMP(payload, 0)

	if len(labels) != 1 {
		t.Fatalf("expected 1 label, got %d", len(labels))
	}

	if labels[0].Label != 16 {
		t.Errorf("Label = %d, want 16", labels[0].Label)
	}

	if labels[0].Exp != 0 {
		t.Errorf("Exp = %d, want 0", labels[0].Exp)
	}

	if !labels[0].S {
		t.Error("S should be true")
	}

	if labels[0].TTL != 64 {
		t.Errorf("TTL = %d, want 64", labels[0].TTL)
	}
}

func TestParseMPLSFromICMP_LabelStack(t *testing.T) {
	t.Parallel()

	payload := buildMPLSPayload([]MPLSLabel{
		{Label: 1000, Exp: 5, S: false, TTL: 255},
		{Label: 2000, Exp: 3, S: true, TTL: 1},
	})

	labels := ParseMPLSFromICMP(payload, 0)

	if len(labels) != 2 {
		t.Fatalf("expected 2 labels, got %d", len(labels))
	}

	if labels[0].Label != 1000 {
		t.Errorf("Label[0] = %d, want 1000", labels[0].Label)
	}

	if labels[0].Exp != 5 {
		t.Errorf("Exp[0] = %d, want 5", labels[0].Exp)
	}

	if labels[0].S {
		t.Error("S[0] should be false")
	}

	if labels[1].Label != 2000 {
		t.Errorf("Label[1] = %d, want 2000", labels[1].Label)
	}

	if !labels[1].S {
		t.Error("S[1] should be true")
	}
}

func TestParseMPLSFromICMP_ICMPLengthField(t *testing.T) {
	t.Parallel()

	// Use the ICMP length field to set original datagram length.
	// 40 * 4 = 160 bytes (greater than minOrigDatagramLen).
	icmpLength := 40
	origLen := icmpLength * 4

	payload := make([]byte, origLen+extHeaderLen+extObjHeaderLen+mplsLabelEntryLen)
	payload[origLen] = 0x20 // version 2

	// Extension object: MPLS class=1, c-type=1
	objLen := extObjHeaderLen + mplsLabelEntryLen
	binary.BigEndian.PutUint16(payload[origLen+extHeaderLen:], uint16(objLen))
	payload[origLen+extHeaderLen+2] = mplsExtClass
	payload[origLen+extHeaderLen+3] = mplsExtCType

	// Label entry: label=99, exp=0, S=1, TTL=10
	entry := uint32(99)<<12 | 0x01<<8 | 10
	binary.BigEndian.PutUint32(payload[origLen+extHeaderLen+extObjHeaderLen:], entry)

	labels := ParseMPLSFromICMP(payload, icmpLength)

	if len(labels) != 1 {
		t.Fatalf("expected 1 label, got %d", len(labels))
	}

	if labels[0].Label != 99 {
		t.Errorf("Label = %d, want 99", labels[0].Label)
	}
}

func TestParseMPLSFromICMP_NonMPLSObject(t *testing.T) {
	t.Parallel()

	payload := make([]byte, minOrigDatagramLen+extHeaderLen+extObjHeaderLen+8)
	payload[minOrigDatagramLen] = 0x20 // version 2

	// Extension object with wrong class (class=2, not MPLS).
	objLen := extObjHeaderLen + 8
	binary.BigEndian.PutUint16(payload[minOrigDatagramLen+extHeaderLen:], uint16(objLen))
	payload[minOrigDatagramLen+extHeaderLen+2] = 2 // not MPLS
	payload[minOrigDatagramLen+extHeaderLen+3] = 1

	labels := ParseMPLSFromICMP(payload, 0)

	if labels != nil {
		t.Errorf("expected nil for non-MPLS object, got %+v", labels)
	}
}

// buildMPLSPayload constructs a test ICMP payload with MPLS extension objects.
func buildMPLSPayload(labels []MPLSLabel) []byte {
	labelDataLen := len(labels) * mplsLabelEntryLen
	objLen := extObjHeaderLen + labelDataLen
	totalLen := minOrigDatagramLen + extHeaderLen + objLen

	payload := make([]byte, totalLen)

	// Extension header at offset minOrigDatagramLen: version 2.
	payload[minOrigDatagramLen] = 0x20

	// Object header.
	offset := minOrigDatagramLen + extHeaderLen
	binary.BigEndian.PutUint16(payload[offset:], uint16(objLen))
	payload[offset+2] = mplsExtClass
	payload[offset+3] = mplsExtCType

	// Label entries.
	for i, l := range labels {
		var sbit uint32
		if l.S {
			sbit = 1
		}

		entry := uint32(l.Label)<<12 | uint32(l.Exp)<<9 | sbit<<8 | uint32(l.TTL)
		binary.BigEndian.PutUint32(payload[offset+extObjHeaderLen+i*mplsLabelEntryLen:], entry)
	}

	return payload
}
