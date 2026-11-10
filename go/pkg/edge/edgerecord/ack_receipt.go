// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package edgerecord

import (
	"bytes"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// ValidatedAck retains the exact acknowledgement and sent window accepted by
// ValidateAck. It is immutable after validation. The authenticated transport
// remains responsible for peer identity and the received-wire limit; this value
// does not authenticate an arbitrary message supplied by another caller.
type ValidatedAck struct {
	ack     *edgev1.EdgeDeliveryAckV1
	session Session
}

// ValidateAckEvidence seals an acknowledgement from the sender's authenticated
// session for downstream durable receipt writers. It preserves ValidateAck's
// ordinary semantics, including retryable and non-authoritative dispositions;
// a recovery publication writer must additionally require authoritative accept.
func ValidateAckEvidence(ack *edgev1.EdgeDeliveryAckV1, session Session, maxDispositions, maxCanonicalBytes int) (*ValidatedAck, error) {
	if err := ValidateAck(ack, session, maxDispositions, maxCanonicalBytes); err != nil {
		return nil, err
	}
	return &ValidatedAck{ack: proto.Clone(ack).(*edgev1.EdgeDeliveryAckV1), session: cloneAckSession(session)}, nil
}

// Snapshot returns independent copies. A zero value is not validated evidence.
func (v *ValidatedAck) Snapshot() (*edgev1.EdgeDeliveryAckV1, Session, error) {
	if v == nil || v.ack == nil {
		return nil, Session{}, ErrAckBinding
	}
	return proto.Clone(v.ack).(*edgev1.EdgeDeliveryAckV1), cloneAckSession(v.session), nil
}

func cloneAckSession(s Session) Session {
	s.SpoolID = bytes.Clone(s.SpoolID)
	s.Nonce = bytes.Clone(s.Nonce)
	if s.SentEvents != nil {
		events := make(map[uint64][]byte, len(s.SentEvents))
		for seq, id := range s.SentEvents {
			events[seq] = bytes.Clone(id)
		}
		s.SentEvents = events
	}
	return s
}
