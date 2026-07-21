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

// Package edgeauth is the gateway-side authorization decision core (task 3.2). It
// verifies an inbound EdgeResultFrame against the sender's trusted identity (the
// deployment-CA / certificate-subject derived Subject) and a scheduler-signed
// capability whose signature the transport adapter has already checked. All
// checks are local: scope/identity binding, capability validity window,
// assignment epoch/generation, and authorization kind are decided from the passed
// Subject and Capability alone -- never a per-frame core or database lookup. A
// stale-epoch immutable replay is permitted only under an exact event-bound
// delivery capability, and such a frame is flagged for audit-only/fenced
// projection. This package holds no crypto or I/O; the adapter supplies verified
// inputs.
package edgeauth

import (
	"bytes"
	"errors"
	"fmt"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Subject is the trusted edge identity resolved from the deployment CA and the
// presented certificate subject. It is authoritative; frame-carried identity is
// only accepted when it agrees with this.
type Subject struct {
	InstallationID []byte
	NetworkScopeID []byte
	AgentID        []byte
	GatewayID      []byte
	PartitionID    uint32
}

// Capability is a scheduler-signed collection or delivery capability whose
// signature the adapter has already verified. It binds the authorized scope,
// epoch, validity window, and (for a replay-bound delivery capability) the exact
// event id and payload checksum.
type Capability struct {
	Kind               edgev1.EdgeResultAuthorizationKind
	NetworkScopeID     []byte
	AgentID            []byte
	AssignmentEpoch    uint64
	NotBeforeUnixNano  int64
	NotAfterUnixNano   int64
	IsDelivery         bool   // true = renewable delivery capability, false = collection
	BoundEventID       []byte // non-empty only for an event-bound replay capability
	BoundPayloadSHA256 []byte // non-empty only for an event-bound replay capability
}

var (
	// ErrScopeMismatch is returned when the frame's network scope does not match
	// the trusted subject or the capability.
	ErrScopeMismatch = errors.New("edgeauth: network scope mismatch")
	// ErrIdentityMismatch is returned when the frame's agent identity does not
	// match the trusted subject or capability.
	ErrIdentityMismatch = errors.New("edgeauth: identity mismatch")
	// ErrAuthKindMismatch is returned when the frame's authorization kind does
	// not match the capability's kind.
	ErrAuthKindMismatch = errors.New("edgeauth: authorization kind mismatch")
	// ErrCapabilityExpired is returned when now is outside the capability window.
	ErrCapabilityExpired = errors.New("edgeauth: capability outside validity window")
	// ErrEpochConflict is returned when the frame's assignment epoch is newer than
	// the capability authorizes (a forward/generation conflict).
	ErrEpochConflict = errors.New("edgeauth: assignment epoch conflict")
	// ErrStaleReplayUnbound is returned when a stale-epoch frame is presented
	// without an exact event/checksum-bound delivery capability.
	ErrStaleReplayUnbound = errors.New("edgeauth: stale-epoch replay requires an event-bound delivery capability")
)

// Decision is the outcome of a successful verification.
type Decision struct {
	// AuditOnly is true when the frame was admitted under a stale-epoch
	// event-bound delivery capability; the consumer must project it fenced /
	// audit-only rather than as fresh authoritative state.
	AuditOnly bool
}

// VerifyDelivery checks a frame against the trusted subject and a verified
// capability at time nowUnixNano. It returns a Decision on success or a typed
// error on any binding/validity/epoch conflict.
func VerifyDelivery(subject Subject, f *edgev1.EdgeResultFrame, cap Capability, nowUnixNano int64) (Decision, error) {
	// Scope: frame, subject, and capability must agree.
	if !bytes.Equal(f.GetNetworkScopeId(), subject.NetworkScopeID) {
		return Decision{}, fmt.Errorf("%w: frame vs subject", ErrScopeMismatch)
	}
	if !bytes.Equal(cap.NetworkScopeID, subject.NetworkScopeID) {
		return Decision{}, fmt.Errorf("%w: capability vs subject", ErrScopeMismatch)
	}
	// Identity: capability must be issued to this agent.
	if len(cap.AgentID) != 0 && !bytes.Equal(cap.AgentID, subject.AgentID) {
		return Decision{}, ErrIdentityMismatch
	}
	// Authorization kind must match the capability.
	if f.GetAuthorizationKind() != cap.Kind {
		return Decision{}, fmt.Errorf("%w: frame %v cap %v", ErrAuthKindMismatch, f.GetAuthorizationKind(), cap.Kind)
	}
	// Validity window (inclusive).
	if nowUnixNano < cap.NotBeforeUnixNano || nowUnixNano > cap.NotAfterUnixNano {
		return Decision{}, fmt.Errorf("%w: now=%d window=[%d,%d]", ErrCapabilityExpired,
			nowUnixNano, cap.NotBeforeUnixNano, cap.NotAfterUnixNano)
	}

	// Epoch/generation handling.
	frameEpoch := f.GetAssignmentEpoch()
	switch {
	case frameEpoch == cap.AssignmentEpoch:
		return Decision{AuditOnly: false}, nil
	case frameEpoch > cap.AssignmentEpoch:
		// The frame claims a newer generation than the capability authorizes.
		return Decision{}, fmt.Errorf("%w: frame epoch %d > cap epoch %d", ErrEpochConflict, frameEpoch, cap.AssignmentEpoch)
	default:
		// Stale-epoch frame: allowed only under an exact event-bound delivery
		// capability, and then only for audit-only/fenced projection.
		if !cap.IsDelivery || len(cap.BoundEventID) == 0 {
			return Decision{}, ErrStaleReplayUnbound
		}
		if !bytes.Equal(cap.BoundEventID, f.GetEventId()) {
			return Decision{}, fmt.Errorf("%w: event id not bound", ErrStaleReplayUnbound)
		}
		if len(cap.BoundPayloadSHA256) != 0 && !bytes.Equal(cap.BoundPayloadSHA256, f.GetPayloadSha256()) {
			return Decision{}, fmt.Errorf("%w: payload checksum not bound", ErrStaleReplayUnbound)
		}
		return Decision{AuditOnly: true}, nil
	}
}
