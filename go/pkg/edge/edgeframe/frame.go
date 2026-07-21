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

// Package edgeframe wraps a canonical domain payload (a sweep observation batch,
// MTR trace batch, execution event, or spool-loss tombstone) into a versioned
// EdgeResultFrame transport envelope: it deterministically marshals the payload,
// computes its SHA-256 and encoded/uncompressed sizes, allocates a UUIDv7
// event ID, and stamps the routing/authorization/cost metadata. It is the
// bridge between the batch builder (obsbatch) and the agent spool + gRPC sender.
//
// Compression defaults to none; the frame never carries authoritative routing
// identity that the gateway will re-derive from mTLS.
package edgeframe

import (
	"crypto/sha256"
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// SchemaVersionV1 is the schema version stamped on every v1 frame.
const SchemaVersionV1 = 1

// MaxPayloadBytes is the hard ceiling for an encoded frame payload (512 KiB),
// matching the data plane's hard frame size; a payload above it is a builder
// error and is rejected here defensively.
const MaxPayloadBytes = 512 * 1024

// ErrPayloadTooLarge reports that an encoded payload exceeds MaxPayloadBytes.
var ErrPayloadTooLarge = errors.New("edgeframe: encoded payload exceeds hard frame limit")

// Meta carries the per-frame metadata a caller supplies for one lane. The spool
// owns SpoolID and Sequence (persistent, contiguous per lane); the scheduler
// owns the authorization/range/scope fields and capabilities.
type Meta struct {
	SpoolID                []byte
	Sequence               uint64
	NetworkScopeID         []byte
	ExecutionID            []byte
	ExecutionShard         uint32
	AssignmentEpoch        *uint64
	AuthorizationKind      edgev1.EdgeResultAuthorizationKind
	AuthorizationContextID []byte
	TargetRangeID          []byte
	TargetRangeSHA256      []byte
	CollectionCapability   []byte
	DeliveryCapability     []byte
	TrafficClass           edgev1.EdgeResultTrafficClass
	CostModelVersion       uint32
}

// Costs are the caller-computed downstream projections (upper bounds) for one
// frame: the number of database rows and the conservative SQL/index/WAL bytes it
// will produce. They drive consumer admission budgets.
type Costs struct {
	Rows       uint32
	WriteBytes uint64
}

// Encode marshals payload, computes its checksum/sizes, allocates a UUIDv7
// event ID, and returns a complete EdgeResultFrame. It never mutates payload.
func Encode(kind edgev1.EdgeResultPayloadKind, payload proto.Message, meta Meta, costs Costs) (*edgev1.EdgeResultFrame, error) {
	body, err := proto.MarshalOptions{Deterministic: true}.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("edgeframe: marshal payload: %w", err)
	}
	if len(body) > MaxPayloadBytes {
		return nil, fmt.Errorf("%w: %d > %d", ErrPayloadTooLarge, len(body), MaxPayloadBytes)
	}

	eventID, err := NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("edgeframe: allocate event id: %w", err)
	}

	sum := sha256.Sum256(body)

	frame := &edgev1.EdgeResultFrame{
		SpoolId:                meta.SpoolID,
		Sequence:               meta.Sequence,
		EventId:                eventID,
		PayloadKind:            kind,
		SchemaVersion:          SchemaVersionV1,
		Compression:            edgev1.EdgeResultCompression_EDGE_RESULT_COMPRESSION_NONE,
		EncodedSize:            uint32(len(body)),
		UncompressedSize:       uint32(len(body)),
		PayloadSha256:          sum[:],
		ExecutionId:            meta.ExecutionID,
		ExecutionShard:         meta.ExecutionShard,
		AssignmentEpoch:        meta.AssignmentEpoch,
		CollectionCapability:   meta.CollectionCapability,
		ProjectedRowCount:      costs.Rows,
		Payload:                body,
		AuthorizationKind:      meta.AuthorizationKind,
		AuthorizationContextId: meta.AuthorizationContextID,
		TargetRangeId:          meta.TargetRangeID,
		TargetRangeSha256:      meta.TargetRangeSHA256,
		DeliveryCapability:     meta.DeliveryCapability,
		ProjectedWriteBytes:    costs.WriteBytes,
		CostModelVersion:       meta.CostModelVersion,
		NetworkScopeId:         meta.NetworkScopeID,
		TrafficClass:           meta.TrafficClass,
	}
	return frame, nil
}

// VerifyPayloadChecksum recomputes the SHA-256 of a frame's payload and reports
// whether it matches the declared digest. Consumers use this before decoding.
func VerifyPayloadChecksum(frame *edgev1.EdgeResultFrame) bool {
	if frame == nil {
		return false
	}
	if uint32(len(frame.GetPayload())) != frame.GetEncodedSize() {
		return false
	}
	sum := sha256.Sum256(frame.GetPayload())
	declared := frame.GetPayloadSha256()
	if len(declared) != len(sum) {
		return false
	}
	for i := range sum {
		if sum[i] != declared[i] {
			return false
		}
	}
	return true
}
