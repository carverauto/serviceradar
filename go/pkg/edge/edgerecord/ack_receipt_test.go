// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package edgerecord

import (
	"bytes"
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestValidatedAckRetainsAcceptedSessionEvidence(t *testing.T) {
	event := fixedUUIDv7(0x31)
	session := Session{SpoolID: fixedUUIDv7(0x32), Nonce: fixedUUIDv7(0x33), HighestSent: 1, NextSequence: 2, FirstUnresolved: 1, SentEvents: map[uint64][]byte{1: event}}
	ack := &edgev1.EdgeDeliveryAckV1{SpoolId: session.SpoolID, SessionNonce: session.Nonce, ResolvedThroughSequence: 1, Dispositions: []*edgev1.EdgeRecordDisposition{{Sequence: 1, EventId: event, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}}}
	sealed, err := ValidateAckEvidence(ack, session, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	// Neither the sender's subsequently advanced window nor a consumer modifying
	// its snapshot may change the evidence whose validation already succeeded.
	ack.Dispositions[0].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
	session.Nonce[0] ^= 1
	session.SpoolID[0] ^= 1
	event[0] ^= 1
	delete(session.SentEvents, 1)
	first, sent, err := sealed.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	first.Dispositions[0].EventId[0] ^= 1
	sent.Nonce[0] ^= 1
	sent.SpoolID[0] ^= 1
	sent.SentEvents[1][0] ^= 1
	sent.HighestSent = 99
	got, state, err := sealed.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.SpoolId, fixedUUIDv7(0x32)) || !bytes.Equal(state.SpoolID, got.SpoolId) || !bytes.Equal(state.Nonce, fixedUUIDv7(0x33)) || !bytes.Equal(got.SessionNonce, state.Nonce) || state.HighestSent != 1 || !bytes.Equal(state.SentEvents[1], fixedUUIDv7(0x31)) || !bytes.Equal(got.Dispositions[0].EventId, state.SentEvents[1]) || got.Dispositions[0].Kind != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE {
		t.Fatal("validated ack changed through an alias")
	}
	if err := ValidateAck(got, state, 0, 0); err != nil {
		t.Fatal(err)
	}
	got.Dispositions[0].EventId = fixedUUIDv7(0x34)
	if carrier, err := ValidateAckEvidence(got, state, 0, 0); carrier != nil || !errors.Is(err, ErrDisposition) {
		t.Fatalf("invalid ack acquired evidence: %v %v", carrier, err)
	}
	if _, _, err := new(ValidatedAck).Snapshot(); !errors.Is(err, ErrAckBinding) {
		t.Fatalf("unvalidated zero value: %v", err)
	}
}
