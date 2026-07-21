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

// Package gwpublish is the gateway-side publish derivation core (task 3.3). It
// turns a validated EdgeResultFrame plus the gateway's trusted (certificate-
// derived) identity into the fields a JetStream publish needs, without any NATS
// I/O:
//
//   - SemanticDigest: the immutable database-semantic digest, computed over the
//     domain-identity terms only and deliberately EXCLUDING spool/partition
//     delivery coordinates and renewable delivery proof, so it is stable across
//     retries, replays, and physical placement (task 1.5).
//   - MsgID: the Nats-Msg-Id for JetStream de-duplication, derived from trusted
//     identity plus spool id/sequence and the semantic digest.
//   - ExpectedStream: the Nats-Expected-Stream, from the shared routing map.
//   - Classify: maps a publish error into capacity / timeout / protocol /
//     permanent so the caller can withhold progress or DLQ correctly.
package gwpublish

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"

	"github.com/carverauto/serviceradar/go/pkg/edge/streamroute"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// TrustedIdentity is the gateway-verified identity (from the deployment CA /
// certificate subject), NOT taken from the frame. It anchors the msg id so a
// spoofed in-frame identity cannot forge another sender's de-dup namespace.
type TrustedIdentity struct {
	NetworkScopeID []byte
	AgentID        []byte
}

// SemanticDigest returns the immutable database-semantic digest of a frame. It
// covers the domain-identity envelope (event id, kind, schema, payload hash,
// execution identity, authorization, range, scope, traffic class, cost terms)
// and excludes spool id, sequence, compression, sizes, and the renewable
// collection/delivery capabilities -- i.e. everything about placement, receipt,
// and delivery proof. Two frames that are the same observation carry the same
// semantic digest regardless of which spool coordinate or lane delivered them.
func SemanticDigest(f *edgev1.EdgeResultFrame) []byte {
	h := sha256.New()
	var num [8]byte
	writeBytes := func(b []byte) {
		binary.BigEndian.PutUint64(num[:], uint64(len(b)))
		_, _ = h.Write(num[:])
		_, _ = h.Write(b)
	}
	writeU64 := func(v uint64) {
		binary.BigEndian.PutUint64(num[:], v)
		_, _ = h.Write(num[:])
	}

	writeBytes(f.GetEventId())
	writeU64(uint64(f.GetPayloadKind()))
	writeU64(uint64(f.GetSchemaVersion()))
	writeBytes(f.GetPayloadSha256())
	writeBytes(f.GetExecutionId())
	writeU64(uint64(f.GetExecutionShard()))
	writeU64(f.GetAssignmentEpoch())
	writeU64(uint64(f.GetAuthorizationKind()))
	writeBytes(f.GetAuthorizationContextId())
	writeBytes(f.GetTargetRangeId())
	writeBytes(f.GetTargetRangeSha256())
	writeBytes(f.GetNetworkScopeId())
	writeU64(uint64(f.GetTrafficClass()))
	writeU64(uint64(f.GetCostModelVersion()))
	writeU64(uint64(f.GetProjectedRowCount()))
	writeU64(f.GetProjectedWriteBytes())
	return h.Sum(nil)
}

// MsgID derives the Nats-Msg-Id for JetStream de-duplication from the gateway's
// trusted identity, the frame's spool id and sequence, and the semantic digest.
// Republishing the exact same spool coordinate yields the same id (idempotent
// publish), while distinct senders occupy distinct id namespaces.
func MsgID(id TrustedIdentity, f *edgev1.EdgeResultFrame) string {
	h := sha256.New()
	var num [8]byte
	writeBytes := func(b []byte) {
		binary.BigEndian.PutUint64(num[:], uint64(len(b)))
		_, _ = h.Write(num[:])
		_, _ = h.Write(b)
	}
	writeBytes(id.NetworkScopeID)
	writeBytes(id.AgentID)
	writeBytes(f.GetSpoolId())
	binary.BigEndian.PutUint64(num[:], f.GetSequence())
	_, _ = h.Write(num[:])
	writeBytes(SemanticDigest(f))
	return hex.EncodeToString(h.Sum(nil))
}

// LaneFor derives the delivery lane kind from a frame's payload kind and traffic
// class. Spool-loss tombstones always route to the recovery-control lane.
func LaneFor(f *edgev1.EdgeResultFrame) edgev1.EdgeResultLaneKind {
	if f.GetPayloadKind() == edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SPOOL_LOSS_TOMBSTONE_V1 {
		return edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_RECOVERY_CONTROL
	}
	interactive := f.GetTrafficClass() == edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE
	switch f.GetPayloadKind() {
	case edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1,
		edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_LEGACY_MTR_JSON_V0:
		if interactive {
			return edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_INTERACTIVE
		}
		return edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_BULK
	default:
		if interactive {
			return edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_INTERACTIVE
		}
		return edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK
	}
}

// ExpectedStream returns the Nats-Expected-Stream the frame must publish to,
// from the shared routing map, plus the partition it hashes to.
func ExpectedStream(f *edgev1.EdgeResultFrame) (stream string, partition uint32, err error) {
	lane := LaneFor(f)
	partition = streamroute.Partition(f.GetNetworkScopeId())
	stream, err = streamroute.PhysicalStream(lane)
	return stream, partition, err
}

// ErrorClass is the coarse category of a publish failure. The caller withholds
// the resolved prefix on Capacity/Timeout (retryable), and DLQs on Permanent.
type ErrorClass int

const (
	// ClassNone means no error.
	ClassNone ErrorClass = iota
	// ClassCapacity is stream-full / no-responders / quota back-pressure.
	ClassCapacity
	// ClassTimeout is a publish ack timeout.
	ClassTimeout
	// ClassProtocol is a wrong-stream / malformed-request protocol error.
	ClassProtocol
	// ClassPermanent is an unrecoverable rejection (poison); route to DLQ.
	ClassPermanent
)

// Sentinels the NATS adapter wraps its transport errors into, so this pure core
// can classify without importing the NATS client.
var (
	ErrCapacity  = errors.New("gwpublish: capacity/back-pressure")
	ErrTimeout   = errors.New("gwpublish: publish ack timeout")
	ErrProtocol  = errors.New("gwpublish: protocol error")
	ErrPermanent = errors.New("gwpublish: permanent rejection")
)

// Classify maps a wrapped publish error to its class.
func Classify(err error) ErrorClass {
	switch {
	case err == nil:
		return ClassNone
	case errors.Is(err, ErrCapacity):
		return ClassCapacity
	case errors.Is(err, ErrTimeout):
		return ClassTimeout
	case errors.Is(err, ErrProtocol):
		return ClassProtocol
	case errors.Is(err, ErrPermanent):
		return ClassPermanent
	default:
		// Unknown errors are treated as retryable timeouts, never silently
		// dropped or treated as durable success.
		return ClassTimeout
	}
}

// Retryable reports whether a class should withhold progress and be retried
// (as opposed to DLQ'd or accepted).
func (c ErrorClass) Retryable() bool {
	return c == ClassCapacity || c == ClassTimeout
}
