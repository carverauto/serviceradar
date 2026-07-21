/*
 * Copyright 2026 Carver Automation Corporation.
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

package edgeframe

import (
	"errors"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestNewUUIDv7IsValidAndTimestamped(t *testing.T) {
	before := time.Now().UnixMilli()
	id, err := NewUUIDv7()
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	after := time.Now().UnixMilli()

	if err := ValidateUUIDv7(id); err != nil {
		t.Fatalf("validate: %v", err)
	}
	ms, err := UUIDv7Millis(id)
	if err != nil {
		t.Fatalf("millis: %v", err)
	}
	if ms < before || ms > after {
		t.Fatalf("embedded ms %d not within [%d,%d]", ms, before, after)
	}
}

func TestUUIDv7MillisRoundTrip(t *testing.T) {
	fixed := time.UnixMilli(1_784_600_123_456)
	id, err := newUUIDv7At(fixed)
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	ms, err := UUIDv7Millis(id)
	if err != nil {
		t.Fatalf("millis: %v", err)
	}
	if ms != fixed.UnixMilli() {
		t.Fatalf("ms = %d, want %d", ms, fixed.UnixMilli())
	}
}

func TestValidateUUIDv7Rejects(t *testing.T) {
	good, _ := newUUIDv7At(time.UnixMilli(1))

	short := good[:15]
	if !errors.Is(ValidateUUIDv7(short), ErrInvalidUUIDv7) {
		t.Fatal("short value should be rejected")
	}

	badVersion := append([]byte(nil), good...)
	badVersion[6] = (badVersion[6] & 0x0F) | 0x40 // version 4
	if !errors.Is(ValidateUUIDv7(badVersion), ErrInvalidUUIDv7) {
		t.Fatal("non-v7 version should be rejected")
	}

	badVariant := append([]byte(nil), good...)
	badVariant[8] = badVariant[8] & 0x3F // clear variant bits
	if !errors.Is(ValidateUUIDv7(badVariant), ErrInvalidUUIDv7) {
		t.Fatal("wrong variant should be rejected")
	}
}

func sampleBatch(hostname string) *edgev1.SweepObservationBatchV1 {
	return &edgev1.SweepObservationBatchV1{
		ExecutionId: make([]byte, 16),
		Source:      edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		Hosts: []*edgev1.SweepHostObservationV1{
			{Address: []byte{10, 0, 0, 1}, Hostname: hostname},
		},
	}
}

func sampleMeta() Meta {
	return Meta{
		SpoolID:           make([]byte, 16),
		Sequence:          5,
		NetworkScopeID:    make([]byte, 16),
		ExecutionID:       make([]byte, 16),
		AuthorizationKind: edgev1.EdgeResultAuthorizationKind_EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT,
		TrafficClass:      edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_BULK,
		CostModelVersion:  1,
	}
}

func TestEncodeProducesConsistentFrame(t *testing.T) {
	batch := sampleBatch("host-a")
	frame, err := Encode(
		edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
		batch, sampleMeta(), Costs{Rows: 1, WriteBytes: 512},
	)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	if frame.SchemaVersion != SchemaVersionV1 {
		t.Fatalf("schema_version = %d", frame.SchemaVersion)
	}
	if frame.Sequence != 5 {
		t.Fatalf("sequence = %d, want 5", frame.Sequence)
	}
	if err := ValidateUUIDv7(frame.EventId); err != nil {
		t.Fatalf("event_id not UUIDv7: %v", err)
	}
	if int(frame.EncodedSize) != len(frame.Payload) {
		t.Fatalf("encoded_size %d != payload len %d", frame.EncodedSize, len(frame.Payload))
	}
	if frame.ProjectedRowCount != 1 || frame.ProjectedWriteBytes != 512 {
		t.Fatalf("projected costs not carried: rows=%d bytes=%d", frame.ProjectedRowCount, frame.ProjectedWriteBytes)
	}
	if !VerifyPayloadChecksum(frame) {
		t.Fatal("checksum should verify for an untampered frame")
	}

	// The opaque payload round-trips to the original batch.
	var got edgev1.SweepObservationBatchV1
	if err := proto.Unmarshal(frame.Payload, &got); err != nil {
		t.Fatalf("payload does not decode: %v", err)
	}
	if got.GetHosts()[0].GetHostname() != "host-a" {
		t.Fatal("payload content lost")
	}
}

func TestEncodeRejectsOversizePayload(t *testing.T) {
	big := sampleBatch(strings.Repeat("x", MaxPayloadBytes+1024))
	_, err := Encode(
		edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
		big, sampleMeta(), Costs{},
	)
	if !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatalf("expected ErrPayloadTooLarge, got %v", err)
	}
}

func TestVerifyPayloadChecksumDetectsTampering(t *testing.T) {
	frame, err := Encode(
		edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
		sampleBatch("host-a"), sampleMeta(), Costs{},
	)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	frame.Payload[len(frame.Payload)-1] ^= 0xFF
	if VerifyPayloadChecksum(frame) {
		t.Fatal("tampered payload must fail checksum")
	}
}
