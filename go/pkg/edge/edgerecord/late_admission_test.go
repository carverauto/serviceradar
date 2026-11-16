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

package edgerecord

import (
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const sixDaysNano = int64(6 * 24 * 3600 * 1_000_000_000)

// The oracle for every case below is the production-time rule in
// openspec/changes/add-edge-production-time-admission (design Decision 3): a record
// captured under authority valid when it was produced is admissible late days
// later, while the live rule keeps refusing it; only key INVALID/UNAVAILABLE and a
// missing trust snapshot refuse it, and a compromised key is admissible only toward
// security quarantine.
func TestValidateRecordProducedAdmitsADaysOldRecordTheLiveRuleRefuses(t *testing.T) {
	r, policy := signedRecord(t)
	policy.NowUnixNano += sixDaysNano
	// The fence moved on too: a stale epoch is core's to judge, not the agent's.
	policy.ActiveFence = ResolvedFence(r.GetProducerContext().GetAuthorityEpoch() + 1)

	if err := ValidateRecordSigned(r, policy); !errors.Is(err, ErrAuthorityExpired) {
		t.Fatalf("live rule on a six-day-old record = %v, want ErrAuthorityExpired", err)
	}
	outcome, err := ValidateRecordProduced(r, policy)
	if err != nil || outcome != LateAdmissible {
		t.Fatalf("production-time rule = (%v, %v), want LateAdmissible", outcome, err)
	}
	// An absent fence (deleted assignment) and an epoch ahead of the known fence are
	// also core's to judge: neither blocks late admission.
	policy.ActiveFence = ActiveFence{}
	if outcome, err := ValidateRecordProduced(r, policy); err != nil || outcome != LateAdmissible {
		t.Fatalf("absent fence = (%v, %v), want LateAdmissible", outcome, err)
	}
	policy.ActiveFence = ResolvedFence(r.GetProducerContext().GetAuthorityEpoch() - 1)
	if outcome, err := ValidateRecordProduced(r, policy); err != nil || outcome != LateAdmissible {
		t.Fatalf("fence behind the record = (%v, %v), want LateAdmissible", outcome, err)
	}
}

func TestValidateRecordProducedClassifiesKeyLifecycle(t *testing.T) {
	r, policy := signedRecord(t)
	policy.NowUnixNano += sixDaysNano
	pc := r.GetProductionCapability()
	public := policy.Trust.(mapTrust)[trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId())]

	revoked := policy
	revoked.Trust = statusTrust{status: KeyHistoricallyRevoked, public: public}
	if outcome, err := ValidateRecordProduced(r, revoked); err != nil || outcome != LateAdmissibleSecurity {
		t.Fatalf("compromise-revoked key = (%v, %v), want LateAdmissibleSecurity", outcome, err)
	}

	unknown := policy
	unknown.Trust = mapTrust{}
	if _, err := ValidateRecordProduced(r, unknown); !errors.Is(err, ErrCapabilityKeyUnresolved) {
		t.Fatalf("unknown key = %v, want permanent ErrCapabilityKeyUnresolved", err)
	}

	unavailable := policy
	unavailable.Trust = statusTrust{status: KeyUnavailable}
	if _, err := ValidateRecordProduced(r, unavailable); !errors.Is(err, ErrKeyUnavailable) {
		t.Fatalf("unavailable lookup = %v, want retryable ErrKeyUnavailable", err)
	}

	noTrust := policy
	noTrust.Trust = nil
	if _, err := ValidateRecordProduced(r, noTrust); !errors.Is(err, ErrTrustMissing) {
		t.Fatalf("no snapshot = %v, want retryable ErrTrustMissing", err)
	}
}

// lateFixture is a six-day-old signed record in a late frame, plus a delivery key
// core would sign late-admission decisions with.
type lateFixture struct {
	record   *edgev1.EdgeRecordV1
	policy   AuthorizationPolicy
	frameFor func(*edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeDeliveryFrameV1
	grant    func(*edgev1.EdgeDeliveryClaimsV1) *edgev1.EdgeSignedCapabilityV1
	late     func(edgev1.EdgeLatePublication, edgev1.EdgeLateDecisionReason) *edgev1.EdgeDeliveryClaimsV1
}

func newLateFixture(t *testing.T) lateFixture {
	t.Helper()
	r, policy := signedRecord(t)
	policy.NowUnixNano += sixDaysNano
	rb, err := CanonicalRecordBytes(r)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(rb)
	spool := mustUUID(t)
	dpub, dpriv, _ := ed25519.GenerateKey(nil)
	dIssuer, dKey := mustUUID(t), mustUUID(t)
	policy.Trust.(mapTrust)[trustKey(dIssuer, dKey)] = dpub
	producedAt, err := ProducedAtUnixNano(r)
	if err != nil {
		t.Fatal(err)
	}
	now := policy.NowUnixNano
	return lateFixture{
		record: r, policy: policy,
		frameFor: func(dc *edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeDeliveryFrameV1 {
			return &edgev1.EdgeDeliveryFrameV1{SpoolId: spool, Sequence: 1, RecordSha256: sum[:], RecordBytes: rb, DeliveryCapability: dc}
		},
		grant: func(claims *edgev1.EdgeDeliveryClaimsV1) *edgev1.EdgeSignedCapabilityV1 {
			claims.EventId, claims.RecordSha256, claims.SpoolId, claims.Sequence = r.GetEventId(), sum[:], spool, 1
			dc := &edgev1.EdgeSignedCapabilityV1{
				CapabilityVersion: 1, IssuerId: dIssuer, IssuerKeyId: dKey, Algorithm: "ed25519",
				NotBeforeUnixNano: now - 60_000_000_000, ExpiresAtUnixNano: now + 900_000_000_000,
				Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: claims},
			}
			SignCapability(dc, dpriv)
			return dc
		},
		late: func(publication edgev1.EdgeLatePublication, reason edgev1.EdgeLateDecisionReason) *edgev1.EdgeDeliveryClaimsV1 {
			return &edgev1.EdgeDeliveryClaimsV1{Transition: &edgev1.EdgeDeliveryClaimsV1_LateAdmission{LateAdmission: &edgev1.EdgeDeliveryLateAdmissionV1{
				ProducedAtUnixNano: producedAt, AuthorityEpoch: r.GetProducerContext().GetAuthorityEpoch(),
				Publication: publication, Reason: reason,
			}}}
		},
	}
}

func TestValidateLateFrameSignedPublishesCoresDecision(t *testing.T) {
	f := newLateFixture(t)
	principal := f.record.GetProducerContext().GetOriginPrincipalId()
	primary := f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED)
	audit := f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_AUDIT, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION)

	// Without core's decision the frame waits; it is never rejected for want of one.
	if _, err := ValidateLateFrameSigned(f.frameFor(nil), principal, f.policy); !errors.Is(err, ErrLateAdmissionGrantRequired) {
		t.Fatalf("no grant = %v, want retryable ErrLateAdmissionGrantRequired", err)
	}
	d, err := ValidateLateFrameSigned(f.frameFor(f.grant(primary)), principal, f.policy)
	if err != nil || d.Publication != FramePublicationPrimary || d.DeliveryMode != FrameDeliveryModeLateAdmission || d.GrantTransition != FrameGrantLateAdmission {
		t.Fatalf("PRIMARY decision = (%+v, %v), want Primary/LateAdmission", d, err)
	}
	if d, err := ValidateLateFrameSigned(f.frameFor(f.grant(audit)), principal, f.policy); err != nil || d.Publication != FramePublicationAudit {
		t.Fatalf("AUDIT decision = (%+v, %v), want Audit", d, err)
	}
}

func TestValidateLateFrameSignedRefusesAGrantForAnotherProductionAuthority(t *testing.T) {
	f := newLateFixture(t)
	principal := f.record.GetProducerContext().GetOriginPrincipalId()
	moved := f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED)
	moved.GetLateAdmission().ProducedAtUnixNano++
	if _, err := ValidateLateFrameSigned(f.frameFor(f.grant(moved)), principal, f.policy); !errors.Is(err, ErrLateAdmissionGrantMismatch) {
		t.Fatalf("grant naming another production time = %v, want ErrLateAdmissionGrantMismatch", err)
	}
	renewal := &edgev1.EdgeDeliveryClaimsV1{Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
		RenewedNotBeforeUnixNano: f.policy.NowUnixNano - 60_000_000_000, RenewedExpiresUnixNano: f.policy.NowUnixNano + 60_000_000_000,
	}}}
	if _, err := ValidateLateFrameSigned(f.frameFor(f.grant(renewal)), principal, f.policy); !errors.Is(err, ErrLateAdmissionGrantMismatch) {
		t.Fatalf("renewal on a late session = %v, want ErrLateAdmissionGrantMismatch", err)
	}
	// A production-time decision never passes as live authority.
	live := f.policy
	live.ActiveFence = ResolvedFence(f.record.GetProducerContext().GetAuthorityEpoch())
	primary := f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED)
	if _, err := ValidateFrameSigned(f.frameFor(f.grant(primary)), live); !errors.Is(err, ErrLateAdmissionGrantMismatch) {
		t.Fatalf("late grant on a live session = %v, want ErrLateAdmissionGrantMismatch", err)
	}
	// A decision whose reason contradicts its publication is malformed.
	contradictory := f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN)
	if _, err := ValidateLateFrameSigned(f.frameFor(f.grant(contradictory)), principal, f.policy); !errors.Is(err, ErrDeliveryClaims) {
		t.Fatalf("PRIMARY with an audit reason = %v, want ErrDeliveryClaims", err)
	}
}

// The three security classes are decided before any grant: a compromised key, a
// foreign origin, and a terminal authority interval are quarantined even when a
// PRIMARY grant is attached, so a revoked authority can never backfill.
func TestValidateLateFrameSignedQuarantinesBeforeAnyGrant(t *testing.T) {
	f := newLateFixture(t)
	principal := f.record.GetProducerContext().GetOriginPrincipalId()
	primary := f.grant(f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED))

	terminal := f.policy
	terminal.TerminalAuthority = true
	if d, err := ValidateLateFrameSigned(f.frameFor(primary), principal, terminal); err != nil || d.Publication != FramePublicationSecurityQuarantine {
		t.Fatalf("terminal interval with a PRIMARY grant = (%+v, %v), want SecurityQuarantine", d, err)
	}
	if d, err := ValidateLateFrameSigned(f.frameFor(primary), []byte("successor-principal"), f.policy); err != nil || d.Publication != FramePublicationSecurityQuarantine {
		t.Fatalf("foreign origin with a PRIMARY grant = (%+v, %v), want SecurityQuarantine", d, err)
	}
	pc := f.record.GetProductionCapability()
	compromised := f.policy
	compromised.Trust = statusTrust{status: KeyHistoricallyRevoked, public: f.policy.Trust.(mapTrust)[trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId())]}
	if d, err := ValidateLateFrameSigned(f.frameFor(nil), principal, compromised); err != nil || d.Publication != FramePublicationSecurityQuarantine {
		t.Fatalf("compromised key, no grant = (%+v, %v), want SecurityQuarantine", d, err)
	}
}

// Core's PRIMARY/AUDIT choice is covered by the delivery signature, so it cannot be
// flipped beside a valid signature.
func TestLateAdmissionDecisionIsSigned(t *testing.T) {
	f := newLateFixture(t)
	principal := f.record.GetProducerContext().GetOriginPrincipalId()
	audit := f.grant(f.late(edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_AUDIT, edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION))
	late := audit.GetDelivery().GetLateAdmission()
	late.Publication = edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY
	late.Reason = edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED
	if d, err := ValidateLateFrameSigned(f.frameFor(audit), principal, f.policy); !errors.Is(err, ErrCapabilitySignatureInvalid) {
		t.Fatalf("AUDIT decision rewritten to PRIMARY = (%+v, %v), want ErrCapabilitySignatureInvalid", d, err)
	}
}
