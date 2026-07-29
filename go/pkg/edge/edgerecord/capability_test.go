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
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"math"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// TestAuthorityWindowClassification exercises currentAt/notYetValid at inclusive boundaries, one
// nanosecond outside, with a negative (clamped) tolerance, and at the int64 Min/Max endpoints where
// unchecked tolerance arithmetic would overflow/underflow into a misclassification.
func TestAuthorityWindowClassification(t *testing.T) {
	const nb, ex = int64(1000), int64(2000)
	pol := func(now, tol int64) AuthorizationPolicy {
		return AuthorizationPolicy{NowUnixNano: now, ClockToleranceNano: tol}
	}
	// Inclusive boundaries (zero tolerance).
	if !pol(nb, 0).currentAt(nb, ex) || !pol(ex, 0).currentAt(nb, ex) {
		t.Fatal("inclusive window boundaries must be current")
	}
	// One nanosecond outside.
	if pol(nb-1, 0).currentAt(nb, ex) || pol(ex+1, 0).currentAt(nb, ex) {
		t.Fatal("one-ns-outside must not be current")
	}
	if !pol(nb-1, 0).notYetValid(nb) || pol(nb, 0).notYetValid(nb) {
		t.Fatal("notYetValid boundary is inclusive of notBefore")
	}
	// Tolerance widens the window inclusively.
	if !pol(nb-5, 5).currentAt(nb, ex) || !pol(ex+5, 5).currentAt(nb, ex) || pol(nb-6, 5).currentAt(nb, ex) {
		t.Fatal("tolerance must widen the window inclusively")
	}
	// A NEGATIVE tolerance is clamped to 0 -- it neither widens nor shrinks.
	if !pol(nb, -100).currentAt(nb, ex) || pol(nb-1, -100).currentAt(nb, ex) {
		t.Fatal("negative tolerance must be clamped to zero")
	}
	// int64 Min/Max endpoints must not overflow/underflow into a misclassification.
	if !pol(0, 10).currentAt(math.MinInt64, math.MaxInt64) {
		t.Fatal("Min/Max window with tolerance must be current")
	}
	if pol(math.MinInt64, 10).notYetValid(math.MinInt64) {
		t.Fatal("MinInt64 notBefore must not underflow into not-yet-valid")
	}
	if !pol(math.MaxInt64, 10).currentAt(0, math.MaxInt64) {
		t.Fatal("MaxInt64 expires must not overflow out of current")
	}
}

// mapTrust models RETAINED key history: a key PRESENT in the map is KeyValid (including a key rotated
// out of active issuance -- retained history still validates it), and an ABSENT key is unknown /
// never-issued -> KeyInvalid (permanent). It does NOT model normal-retirement as removal (that would
// conflate rotation with unknown); funcTrust/statusTrust model the compromise (KeyHistoricallyRevoked)
// and unavailable lifecycles.
type mapTrust map[string]ed25519.PublicKey

func trustKey(issuerID, keyID []byte) string { return string(issuerID) + "|" + string(keyID) }

func (m mapTrust) ResolveKey(issuerID, keyID []byte, ev KeyEvidence) KeyResolution {
	if pub, ok := m[trustKey(issuerID, keyID)]; ok {
		return KeyResolution{Status: KeyValid, Public: pub, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
	}
	return KeyResolution{Status: KeyInvalid, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
}

// statusTrust returns a fixed KeyResolution for the single known key, so tests can exercise the
// KeyUnavailable (retryable) and KeyHistoricallyRevoked (audit-only) lifecycles distinctly from
// KeyInvalid.
type statusTrust struct {
	status KeyStatus
	public ed25519.PublicKey
}

func (s statusTrust) ResolveKey(_, _ []byte, ev KeyEvidence) KeyResolution {
	return KeyResolution{Status: s.status, Public: s.public, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
}

// nowFor returns the identity time (ns) embedded in a UUIDv7, used as a trusted
// evaluation "now" inside the capability window.
func nowFor(t *testing.T, id []byte) int64 {
	t.Helper()
	ms, err := UUIDv7Millis(id)
	if err != nil {
		t.Fatalf("uuid millis: %v", err)
	}
	return ms * 1_000_000
}

// signedRecord returns a record whose production capability is really signed, plus
// a policy that accepts it at the record's event time.
func signedRecord(t *testing.T) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	r := validRecord(t)
	SignCapability(r.GetProductionCapability(), priv)
	reseal(r)
	pc := r.GetProductionCapability()
	policy := AuthorizationPolicy{
		Trust:            mapTrust{trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId()): pub},
		NowUnixNano:      nowFor(t, r.GetEventId()),
		ActiveFence:      ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()),
		TrustPolicyEpoch: 1,
	}
	return r, policy
}

// Reviewer repro (r4-02/r5-02): a record with a bogus one-byte signature passes
// the STRUCTURAL ValidateRecord, but the crypto authorization boundary rejects it.
func TestValidateRecordSignedIsTheAuthorizationBoundary(t *testing.T) {
	r, policy := signedRecord(t)
	if err := ValidateRecordSigned(r, policy); err != nil {
		t.Fatalf("signed record must verify: %v", err)
	}

	r.GetProductionCapability().Signature = []byte{0x01}
	reseal(r)
	if err := ValidateRecord(r); err != nil {
		t.Fatalf("structural ValidateRecord should still pass: %v", err)
	}
	if err := ValidateRecordSigned(r, policy); !errors.Is(err, ErrCapabilitySignatureInvalid) {
		t.Fatalf("tampered signature = %v, want ErrCapabilitySignatureInvalid", err)
	}
}

// Reviewer repro (r5-23): a nil trust must fail closed, not panic.
func TestValidateRecordSignedNilTrust(t *testing.T) {
	r, _ := signedRecord(t)
	if err := ValidateRecordSigned(r, AuthorizationPolicy{}); !errors.Is(err, ErrTrustMissing) {
		t.Fatalf("nil trust = %v, want ErrTrustMissing", err)
	}
}

// fixedEpochTrust echoes a FIXED trust-policy epoch regardless of the request, so tests can simulate a
// stale / cross-snapshot / zero resolver reply that the response-bind check must reject.
type fixedEpochTrust struct {
	epoch  uint64
	public ed25519.PublicKey
}

func (f fixedEpochTrust) ResolveKey(_, _ []byte, ev KeyEvidence) KeyResolution {
	return KeyResolution{Status: KeyValid, Public: f.public, TrustPolicyEpoch: f.epoch, Purpose: ev.Purpose}
}

// The trust-policy epoch is both REQUEST-pinned and RESPONSE-bound: a zero REQUEST epoch fails closed
// (ErrTrustEpochUnset), and a resolver reply whose ECHOED epoch is zero or mismatches the request is a
// stale/cross-snapshot response -> ErrKeyUnavailable (retryable), never authorized.
func TestValidateSignedRequiresPinnedTrustEpoch(t *testing.T) {
	r, policy := signedRecord(t)
	pc := r.GetProductionCapability()
	pub := policy.Trust.(mapTrust)[trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId())]

	// (a) a ZERO REQUEST epoch fails closed before any resolution (record + frame).
	zero := policy
	zero.TrustPolicyEpoch = 0
	if err := ValidateRecordSigned(r, zero); !errors.Is(err, ErrTrustEpochUnset) {
		t.Fatalf("record, zero epoch = %v, want ErrTrustEpochUnset", err)
	}
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	f := &edgev1.EdgeDeliveryFrameV1{SpoolId: mustUUID(t), Sequence: 1, RecordSha256: sum[:], RecordBytes: rb}
	if _, err := ValidateFrameSigned(f, zero); !errors.Is(err, ErrTrustEpochUnset) {
		t.Fatalf("frame, zero epoch = %v, want ErrTrustEpochUnset", err)
	}

	// (b) a MISMATCHED echoed epoch (resolver replied from a different snapshot) -> retryable, even
	// though the signature would verify and the request epoch is nonzero.
	stale := policy
	stale.Trust = fixedEpochTrust{epoch: policy.TrustPolicyEpoch + 1, public: pub}
	if err := ValidateRecordSigned(r, stale); !errors.Is(err, ErrKeyUnavailable) {
		t.Fatalf("mismatched-epoch echo = %v, want ErrKeyUnavailable", err)
	}
	// (c) a ZERO echoed epoch (unset reply) -> retryable.
	zeroEcho := policy
	zeroEcho.Trust = fixedEpochTrust{epoch: 0, public: pub}
	if err := ValidateRecordSigned(r, zeroEcho); !errors.Is(err, ErrKeyUnavailable) {
		t.Fatalf("zero-epoch echo = %v, want ErrKeyUnavailable", err)
	}
	// Control: the SAME echoed epoch verifies.
	ok := policy
	ok.Trust = fixedEpochTrust{epoch: policy.TrustPolicyEpoch, public: pub}
	if err := ValidateRecordSigned(r, ok); err != nil {
		t.Fatalf("matching-epoch echo must verify: %v", err)
	}
}

// panicTrust fails the test if ResolveKey is ever called, proving a guard short-circuits before the
// resolver.
type panicTrust struct{}

func (panicTrust) ResolveKey(_, _ []byte, ev KeyEvidence) KeyResolution {
	panic("ResolveKey must not be reached")
}

// DIRECT helper coverage (the wrapper's zero-epoch path is masked): VerifyCapabilityWithTrust returns
// ErrTrustEpochUnset for a zero requested epoch BEFORE reaching the resolver (panicTrust would panic if
// reached), never the retryable ErrKeyUnavailable.
func TestVerifyCapabilityWithTrustRejectsZeroEpoch(t *testing.T) {
	r, policy := signedRecord(t)
	pc := r.GetProductionCapability()
	prod := edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION

	if _, err := VerifyCapabilityWithTrust(pc, prod, panicTrust{}, policy.NowUnixNano, 0); !errors.Is(err, ErrTrustEpochUnset) {
		t.Fatalf("zero epoch = %v, want ErrTrustEpochUnset (resolver must not be reached)", err)
	}
	// A nonzero epoch with the real (echoing) trust verifies to KeyValid.
	if status, err := VerifyCapabilityWithTrust(pc, prod, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch); err != nil || status != KeyValid {
		t.Fatalf("nonzero epoch = (%v, %v), want KeyValid/nil", status, err)
	}
}

// nilDerefTrust reads THROUGH its pointer receiver, so a (*nilDerefTrust)(nil) boxed in the
// CapabilityTrust interface panics inside ResolveKey unless a guard rejects it first. A bare
// `trust == nil` does NOT catch this typed nil (the interface is non-nil); isNilTrust must.
type nilDerefTrust struct{ epoch uint64 }

func (tr *nilDerefTrust) ResolveKey(_, _ []byte, ev KeyEvidence) KeyResolution {
	return KeyResolution{Status: KeyValid, TrustPolicyEpoch: tr.epoch, Purpose: ev.Purpose}
}

// A typed-nil resolver (a non-nil interface boxing a nil pointer) must fail closed with
// ErrTrustMissing at EVERY authorization entry, never panic in ResolveKey.
func TestAuthorizationEntriesRejectTypedNilTrust(t *testing.T) {
	r, policy := signedRecord(t)
	pc := r.GetProductionCapability()
	prod := edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION

	var typedNil *nilDerefTrust // nil pointer; boxes into a non-nil, nil-carrying interface below

	if _, err := VerifyCapabilityWithTrust(pc, prod, typedNil, policy.NowUnixNano, policy.TrustPolicyEpoch); !errors.Is(err, ErrTrustMissing) {
		t.Fatalf("VerifyCapabilityWithTrust(typed-nil) = %v, want ErrTrustMissing", err)
	}

	p := policy
	p.Trust = typedNil
	if err := ValidateRecordSigned(r, p); !errors.Is(err, ErrTrustMissing) {
		t.Fatalf("ValidateRecordSigned(typed-nil) = %v, want ErrTrustMissing", err)
	}

	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	f := &edgev1.EdgeDeliveryFrameV1{SpoolId: mustUUID(t), Sequence: 1, RecordSha256: sum[:], RecordBytes: rb}
	if _, err := ValidateFrameSigned(f, p); !errors.Is(err, ErrTrustMissing) {
		t.Fatalf("ValidateFrameSigned(typed-nil) = %v, want ErrTrustMissing", err)
	}
}

// Reviewer repro (r5-01): production authority must be current at the trusted now.
func TestValidateRecordSignedRequiresCurrentAuthority(t *testing.T) {
	r, policy := signedRecord(t)
	policy.NowUnixNano += 48 * 3_600 * 1_000_000_000 // two days past the window
	if err := ValidateRecordSigned(r, policy); !errors.Is(err, ErrAuthorityExpired) {
		t.Fatalf("expired authority = %v, want ErrAuthorityExpired", err)
	}
}

// Reviewer repro (r5-01): a producer fence below the active generation is stale.
func TestValidateRecordSignedRejectsStaleFence(t *testing.T) {
	r, policy := signedRecord(t)
	policy.ActiveFence = ResolvedFence(r.GetProducerContext().GetAuthorityEpoch() + 1)
	if err := ValidateRecordSigned(r, policy); !errors.Is(err, ErrFenceStale) {
		t.Fatalf("stale fence = %v, want ErrFenceStale", err)
	}
}

func TestValidateRecordSignedRejectsUnknownKey(t *testing.T) {
	r, policy := signedRecord(t)
	policy.Trust = mapTrust{}
	if err := ValidateRecordSigned(r, policy); !errors.Is(err, ErrCapabilityKeyUnresolved) {
		t.Fatalf("unknown key = %v, want ErrCapabilityKeyUnresolved", err)
	}
}

// Reviewer repro (r5-24 / key-lifecycle): same-issuer key rotation with the NORMATIVE lifecycle
// semantics. A key NORMALLY rotated out of active issuance STILL validates historical records via
// retained key history (KeyValid); a COMPROMISE-revoked key is REACHABLE as audit/ledger_only
// (ErrKeyHistoricallyRevoked), never a permanent reject; only an UNKNOWN/never-issued or cross-issuer
// key is a permanent reject (ErrCapabilityKeyUnresolved). Normal rotation is NOT conflated with unknown.
func TestCapabilityKeyRotationSameIssuer(t *testing.T) {
	issuer := mustUUID(t)
	keyIDA, keyIDB := mustUUID(t), mustUUID(t)
	pubA, privA, _ := ed25519.GenerateKey(nil)
	pubB, privB, _ := ed25519.GenerateKey(nil)

	signWith := func(keyID []byte, priv ed25519.PrivateKey) *edgev1.EdgeRecordV1 {
		r := validRecord(t)
		pc := r.GetProductionCapability()
		pc.IssuerId = issuer
		pc.IssuerKeyId = keyID
		SignCapability(pc, priv)
		reseal(r)
		return r
	}
	recA := signWith(keyIDA, privA)
	recB := signWith(keyIDB, privB)
	policyFor := func(r *edgev1.EdgeRecordV1, trust mapTrust) AuthorizationPolicy {
		return AuthorizationPolicy{Trust: trust, NowUnixNano: nowFor(t, r.GetEventId()),
			ActiveFence: ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()), TrustPolicyEpoch: 1}
	}

	overlap := mapTrust{trustKey(issuer, keyIDA): pubA, trustKey(issuer, keyIDB): pubB}
	if err := ValidateRecordSigned(recA, policyFor(recA, overlap)); err != nil {
		t.Fatalf("key A during overlap: %v", err)
	}
	if err := ValidateRecordSigned(recB, policyFor(recB, overlap)); err != nil {
		t.Fatalf("key B during overlap: %v", err)
	}
	policyForTrust := func(r *edgev1.EdgeRecordV1, trust CapabilityTrust) AuthorizationPolicy {
		return AuthorizationPolicy{Trust: trust, NowUnixNano: nowFor(t, r.GetEventId()),
			ActiveFence: ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()), TrustPolicyEpoch: 1}
	}

	// NORMAL rotation: key A rotated OUT of active issuance but retained -> recA STILL validates via
	// retained history (KeyValid), NOT rejected as unknown.
	rotated := funcTrust(func(_, keyID []byte, ev KeyEvidence) KeyResolution {
		switch {
		case bytes.Equal(keyID, keyIDA):
			return KeyResolution{Status: KeyValid, Public: pubA, Purpose: ev.Purpose} // retained history keeps it valid
		case bytes.Equal(keyID, keyIDB):
			return KeyResolution{Status: KeyValid, Public: pubB, Purpose: ev.Purpose}
		default:
			return KeyResolution{Status: KeyInvalid, Purpose: ev.Purpose}
		}
	})
	if err := ValidateRecordSigned(recA, policyForTrust(recA, rotated)); err != nil {
		t.Fatalf("normally-rotated key A must still validate via retained history: %v", err)
	}

	// COMPROMISE revocation of key A: historical trust is deliberately invalidated -> recA is REACHABLE
	// as audit/ledger_only (ErrKeyHistoricallyRevoked), never a permanent reject and never a silent apply.
	compromised := funcTrust(func(_, keyID []byte, ev KeyEvidence) KeyResolution {
		if bytes.Equal(keyID, keyIDA) {
			return KeyResolution{Status: KeyHistoricallyRevoked, Public: pubA, Purpose: ev.Purpose}
		}
		return KeyResolution{Status: KeyInvalid, Purpose: ev.Purpose}
	})
	if err := ValidateRecordSigned(recA, policyForTrust(recA, compromised)); !errors.Is(err, ErrKeyHistoricallyRevoked) {
		t.Fatalf("compromise-revoked key A = %v, want ErrKeyHistoricallyRevoked (reachable audit)", err)
	}

	// UNKNOWN / never-issued key A (absent entirely) -> permanent reject; key B still valid.
	unknown := mapTrust{trustKey(issuer, keyIDB): pubB}
	if err := ValidateRecordSigned(recA, policyFor(recA, unknown)); !errors.Is(err, ErrCapabilityKeyUnresolved) {
		t.Fatalf("unknown/never-issued key A = %v, want ErrCapabilityKeyUnresolved", err)
	}
	if err := ValidateRecordSigned(recB, policyFor(recB, unknown)); err != nil {
		t.Fatalf("key B still valid: %v", err)
	}
	wrongIssuer := mapTrust{trustKey(mustUUID(t), keyIDA): pubA}
	if err := ValidateRecordSigned(recA, policyFor(recA, wrongIssuer)); !errors.Is(err, ErrCapabilityKeyUnresolved) {
		t.Fatalf("cross-issuer key = %v, want ErrCapabilityKeyUnresolved", err)
	}
}

// Reviewer repro (r5-02): ValidateFrameSigned must verify the enclosed production
// signature even when no delivery capability is present.
func TestValidateFrameSignedVerifiesEnclosedRecord(t *testing.T) {
	r, policy := signedRecord(t)
	r.GetProductionCapability().Signature = []byte{0x02}
	reseal(r)
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	frame := &edgev1.EdgeDeliveryFrameV1{SpoolId: mustUUID(t), Sequence: 1, RecordSha256: sum[:], RecordBytes: rb}
	if _, err := ValidateFrameSigned(frame, policy); !errors.Is(err, ErrCapabilitySignatureInvalid) {
		t.Fatalf("tampered enclosed record = %v, want ErrCapabilitySignatureInvalid", err)
	}
}

// ValidateFrameSigned distinguishes the authority outcomes: fresh apply (which STILL verifies any
// attached grant), an ordinary late DRAIN under a current fence with expired production authority,
// and a stale-fence late-fenced AUDIT -- never conflating a current-fence renewal/rollover with
// stale-fence audit traffic.
//
// fence x key lifecycle) reads more clearly as a single table than split across many tiny tests.
//
//nolint:gocyclo // one test exhaustively enumerating the frame-decision matrix (fresh/drain/audit x
func TestValidateFrameSignedLateFenced(t *testing.T) {
	r, policy := signedRecord(t)
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	spool := mustUUID(t)
	frameFor := func(dc *edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeDeliveryFrameV1 {
		return &edgev1.EdgeDeliveryFrameV1{SpoolId: spool, Sequence: 1, RecordSha256: sum[:], RecordBytes: rb, DeliveryCapability: dc}
	}

	dpub, dpriv, _ := ed25519.GenerateKey(nil)
	dIssuer, dKey := mustUUID(t), mustUUID(t)
	policy.Trust.(mapTrust)[trustKey(dIssuer, dKey)] = dpub

	grant := func(nowNs int64, claims *edgev1.EdgeDeliveryClaimsV1) *edgev1.EdgeSignedCapabilityV1 {
		claims.EventId, claims.RecordSha256, claims.SpoolId, claims.Sequence = r.GetEventId(), sum[:], spool, 1
		dc := &edgev1.EdgeSignedCapabilityV1{
			CapabilityVersion: 1, IssuerId: dIssuer, IssuerKeyId: dKey, Algorithm: "ed25519",
			NotBeforeUnixNano: nowNs - 3_600_000_000_000, ExpiresAtUnixNano: nowNs + 3_600_000_000_000,
			Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: claims},
		}
		SignCapability(dc, dpriv)
		return dc
	}
	renewalClaims := func(nowNs int64) *edgev1.EdgeDeliveryClaimsV1 {
		return &edgev1.EdgeDeliveryClaimsV1{Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
			RenewedNotBeforeUnixNano: nowNs - 1_800_000_000_000, RenewedExpiresUnixNano: nowNs + 1_800_000_000_000,
		}}}
	}
	rolloverClaims := func() *edgev1.EdgeDeliveryClaimsV1 {
		return &edgev1.EdgeDeliveryClaimsV1{Transition: &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{
			RecoveryId: mustUUID(t), PriorSpoolId: mustUUID(t), PriorSequence: 7,
		}}}
	}
	now := policy.NowUnixNano

	// (1) Fresh: current production authority, current fence, no delivery grant -> PRIMARY/FRESH/None.
	if d, err := ValidateFrameSigned(frameFor(nil), policy); err != nil ||
		d.Publication != FramePublicationPrimary || d.DeliveryMode != FrameDeliveryModeFresh || d.GrantTransition != FrameGrantNone {
		t.Fatalf("fresh, no grant = (%+v, %v), want Primary/Fresh/None", d, err)
	}
	// (2) CURRENT authority WITH a valid attached grant: the DELIVERY MODE is GRANT-driven, NOT Fresh
	// (regression P1-3). A current-authority renewal -> PRIMARY/RENEWAL/Renewal; a current-authority
	// rollover -> PRIMARY/ROLLOVER/Rollover, so its recovery proof is carried instead of being dropped
	// as a Fresh no-proof.
	if d, err := ValidateFrameSigned(frameFor(grant(now, renewalClaims(now))), policy); err != nil ||
		d.Publication != FramePublicationPrimary || d.DeliveryMode != FrameDeliveryModeRenewal || d.GrantTransition != FrameGrantRenewal {
		t.Fatalf("current auth + renewal grant = (%+v, %v), want Primary/Renewal/Renewal", d, err)
	}
	if d, err := ValidateFrameSigned(frameFor(grant(now, rolloverClaims())), policy); err != nil ||
		d.Publication != FramePublicationPrimary || d.DeliveryMode != FrameDeliveryModeRollover || d.GrantTransition != FrameGrantRollover {
		t.Fatalf("current auth + rollover grant = (%+v, %v), want Primary/Rollover/Rollover", d, err)
	}
	// (3) Fresh with a FORGED attached grant -> rejected (zero decision), NOT silently applied.
	badGrant := grant(now, rolloverClaims())
	badGrant.Signature = []byte("bogus")
	if d, err := ValidateFrameSigned(frameFor(badGrant), policy); err == nil || d.Publication != FramePublicationUnspecified {
		t.Fatalf("fresh + forged attached grant = (%+v, %v), must be rejected with the zero decision", d, err)
	}

	// An out-of-bounds clock tolerance (negative OR above the cap) is a POLICY error -> zero
	// decision + ErrClockTolerance, so a huge tolerance cannot widen the window to "all time".
	tooBig := policy
	tooBig.ClockToleranceNano = MaxClockToleranceNano + 1
	if d, err := ValidateFrameSigned(frameFor(nil), tooBig); !errors.Is(err, ErrClockTolerance) || d.Publication != FramePublicationUnspecified {
		t.Fatalf("over-cap tolerance = (%+v, %v), want zero decision + ErrClockTolerance", d, err)
	}
	negTol := policy
	negTol.ClockToleranceNano = -1
	if _, err := ValidateFrameSigned(frameFor(nil), negTol); !errors.Is(err, ErrClockTolerance) {
		t.Fatalf("negative tolerance = %v, want ErrClockTolerance", err)
	}

	// (4) CURRENT fence, EXPIRED production authority, valid grant -> ordinary late DRAIN (not audit).
	drain := policy
	drain.NowUnixNano = now + 48*3_600_000_000_000 // two days past the production window
	drainNow := drain.NowUnixNano
	if d, err := ValidateFrameSigned(frameFor(grant(drainNow, renewalClaims(drainNow))), drain); err != nil ||
		d.Publication != FramePublicationPrimary || d.DeliveryMode != FrameDeliveryModeRenewal || d.GrantTransition != FrameGrantRenewal {
		t.Fatalf("current fence + expired prod + grant = (%+v, %v), want Primary/Renewal/Renewal", d, err)
	}

	// (5) NOT-YET-VALID (future-dated) production authority MUST NOT be usable early, even with a
	// current renewal OR rollover grant.
	future := policy
	future.NowUnixNano = now - 48*3_600_000_000_000 // two days BEFORE the production window opens
	futureNow := future.NowUnixNano
	if _, err := ValidateFrameSigned(frameFor(grant(futureNow, renewalClaims(futureNow))), future); !errors.Is(err, ErrAuthorityNotYetValid) {
		t.Fatalf("future prod + renewal grant = %v, want ErrAuthorityNotYetValid", err)
	}
	if _, err := ValidateFrameSigned(frameFor(grant(futureNow, rolloverClaims())), future); !errors.Is(err, ErrAuthorityNotYetValid) {
		t.Fatalf("future prod + rollover grant = %v, want ErrAuthorityNotYetValid", err)
	}

	// (6) STALE fence + valid grant -> AUDIT publication + LATE_FENCED_DELIVERY mode; the grant
	// transition (renewal OR rollover) is recorded separately.
	stale := policy
	stale.ActiveFence = ResolvedFence(r.GetProducerContext().GetAuthorityEpoch() + 1)
	if d, err := ValidateFrameSigned(frameFor(grant(now, renewalClaims(now))), stale); err != nil ||
		d.Publication != FramePublicationAudit || d.DeliveryMode != FrameDeliveryModeLateFenced || d.GrantTransition != FrameGrantRenewal {
		t.Fatalf("stale fence + renewal grant = (%+v, %v), want Audit/LateFenced/Renewal", d, err)
	}
	if d, err := ValidateFrameSigned(frameFor(grant(now, rolloverClaims())), stale); err != nil ||
		d.Publication != FramePublicationAudit || d.DeliveryMode != FrameDeliveryModeLateFenced || d.GrantTransition != FrameGrantRollover {
		t.Fatalf("stale fence + rollover grant = (%+v, %v), want Audit/LateFenced/Rollover", d, err)
	}
	// (7) STALE fence with NO grant -> ErrFenceStale.
	if _, err := ValidateFrameSigned(frameFor(nil), stale); !errors.Is(err, ErrFenceStale) {
		t.Fatalf("stale fence, no grant = %v, want ErrFenceStale", err)
	}

	// (8) A COMPROMISE-revoked (KeyHistoricallyRevoked) PRODUCTION key is a SECURITY downgrade that is a
	// REACHABLE TERMINAL outcome: the frame is DURABLY CAPTURED to SecurityQuarantine (ledger_only
	// downstream), never Primary, and -- critically -- it does NOT require a delivery grant. With a
	// grant present it is STILL SecurityQuarantine/Fresh (the grant governs stale/expired delivery, not
	// the security downgrade), never Audit/Renewal.
	prodPub := policy.Trust.(mapTrust)[trustKey(r.GetProductionCapability().GetIssuerId(), r.GetProductionCapability().GetIssuerKeyId())]
	revoked := policy
	revoked.Trust = funcTrust(func(issuerID, _ []byte, ev KeyEvidence) KeyResolution {
		switch {
		case bytes.Equal(issuerID, r.GetProductionCapability().GetIssuerId()):
			return KeyResolution{Status: KeyHistoricallyRevoked, Public: prodPub, Purpose: ev.Purpose}
		case bytes.Equal(issuerID, dIssuer):
			return KeyResolution{Status: KeyValid, Public: dpub, Purpose: ev.Purpose}
		default:
			return KeyResolution{Status: KeyInvalid, Purpose: ev.Purpose}
		}
	})
	if d, err := ValidateFrameSigned(frameFor(grant(now, renewalClaims(now))), revoked); err != nil ||
		d.Publication != FramePublicationSecurityQuarantine || d.DeliveryMode != FrameDeliveryModeFresh || d.GrantTransition != FrameGrantNone {
		t.Fatalf("revoked prod key + grant = (%+v, %v), want SecurityQuarantine/Fresh/None (terminal, no grant)", d, err)
	}
	// (9) Revoked production key with NO grant -> STILL durably captured (SecurityQuarantine), NOT
	// refused: the compromise capture is a reachable terminal path that needs no delivery grant.
	revokedNoGrant := policy
	revokedNoGrant.Trust = funcTrust(func(_, _ []byte, ev KeyEvidence) KeyResolution {
		return KeyResolution{Status: KeyHistoricallyRevoked, Public: prodPub, Purpose: ev.Purpose}
	})
	if d, err := ValidateFrameSigned(frameFor(nil), revokedNoGrant); err != nil ||
		d.Publication != FramePublicationSecurityQuarantine || d.DeliveryMode != FrameDeliveryModeFresh {
		t.Fatalf("revoked prod key, no grant = (%+v, %v), want SecurityQuarantine/Fresh (durably captured)", d, err)
	}
	// (10) Compromise PRECEDES the fence: an UNAVAILABLE fence must NOT mask a compromised key -- still
	// SecurityQuarantine, not ErrFenceNotReady.
	revokedUnavailFence := revokedNoGrant
	revokedUnavailFence.ActiveFence = ActiveFence{}
	if d, err := ValidateFrameSigned(frameFor(nil), revokedUnavailFence); err != nil ||
		d.Publication != FramePublicationSecurityQuarantine {
		t.Fatalf("revoked key + unavailable fence = (%+v, %v), want SecurityQuarantine (fence must not mask compromise)", d, err)
	}
}

// funcTrust is a per-issuer trust so one test can resolve DIFFERENT KeyResolutions for the production
// vs delivery issuer.
type funcTrust func(issuerID, keyID []byte, ev KeyEvidence) KeyResolution

func (f funcTrust) ResolveKey(issuerID, keyID []byte, ev KeyEvidence) KeyResolution {
	r := f(issuerID, keyID, ev)
	// Auto-echo the requested epoch so the per-test closures need not repeat it (the response-bind
	// check requires the echo). A test simulating a stale/mismatched echo uses a dedicated trust.
	r.TrustPolicyEpoch = ev.TrustPolicyEpoch
	return r
}

// TestFenceResolutionAndKeyLifecycle proves the explicit fence + key-lifecycle model (P0-1, P1-4): an
// UNAVAILABLE fence (zero value) or a locally-unknown FUTURE epoch is RETRYABLE (ErrFenceNotReady) and
// NEVER authorizes -- a forgotten/failed fence lookup can never read as "epoch 0 is current"; a
// KeyUnavailable resolution is RETRYABLE (ErrKeyUnavailable), distinct from a permanent KeyInvalid;
// and a KeyHistoricallyRevoked production key cannot freshly apply (ErrKeyHistoricallyRevoked).
func TestFenceResolutionAndKeyLifecycle(t *testing.T) {
	r, policy := signedRecord(t)
	pc := r.GetProductionCapability()
	pub := policy.Trust.(mapTrust)[trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId())]

	// (a) UNAVAILABLE fence (zero value, never resolved) -> retryable, NOT authorized. This is the
	// P0-1 core: a forgotten fence lookup must never authorize an epoch-5 record as "epoch 0 current".
	unavail := policy
	unavail.ActiveFence = ActiveFence{}
	if err := ValidateRecordSigned(r, unavail); !errors.Is(err, ErrFenceNotReady) {
		t.Fatalf("unavailable fence = %v, want ErrFenceNotReady", err)
	}

	// (b) A record epoch ABOVE the active fence is a locally-unknown FUTURE generation -> retryable
	// (never authorize a generation we have not learned). Fixture epoch is 5; set the fence to 4.
	fut := policy
	fut.ActiveFence = ResolvedFence(r.GetProducerContext().GetAuthorityEpoch() - 1)
	if err := ValidateRecordSigned(r, fut); !errors.Is(err, ErrFenceNotReady) {
		t.Fatalf("future epoch = %v, want ErrFenceNotReady", err)
	}

	// (c) KeyUnavailable -> ErrKeyUnavailable (retryable), never a permanent reject.
	kv := policy
	kv.Trust = statusTrust{status: KeyUnavailable}
	if err := ValidateRecordSigned(r, kv); !errors.Is(err, ErrKeyUnavailable) {
		t.Fatalf("unavailable key = %v, want ErrKeyUnavailable", err)
	}

	// (d) KeyHistoricallyRevoked = COMPROMISE revocation -> the signature still verifies (it was valid
	// at signing) but a fresh apply is refused; it is REACHABLE as ledger_only/audit
	// (ErrKeyHistoricallyRevoked), never a permanent reject and never a silent Primary.
	hr := policy
	hr.Trust = statusTrust{status: KeyHistoricallyRevoked, public: pub}
	if err := ValidateRecordSigned(r, hr); !errors.Is(err, ErrKeyHistoricallyRevoked) {
		t.Fatalf("compromise-revoked key = %v, want ErrKeyHistoricallyRevoked", err)
	}
}

// TestAggregateWorstTrustAcrossProductionAndSource proves the SOURCE key status is NOT discarded (the
// reviewer's finding): a COMPROMISE-revoked source (or production) key downgrades the WHOLE record to
// audit-only (ErrKeyHistoricallyRevoked), so a compromised capability can never slip through as a fresh
// apply; an INVALID source key is a permanent reject that dominates.
func TestAggregateWorstTrustAcrossProductionAndSource(t *testing.T) {
	pubP, privP, _ := ed25519.GenerateKey(nil)
	pubS, privS, _ := ed25519.GenerateKey(nil)
	r := validRecord(t)
	prodIssuer := r.GetProductionCapability().GetIssuerId()
	SignCapability(r.GetProductionCapability(), privP)

	ctx, scopeID := mustUUID(t), mustUUID(t)
	sc := sourceCap(t, r, ctx, scopeID, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK)
	srcIssuer := mustUUID(t)
	sc.IssuerId, sc.IssuerKeyId = srcIssuer, mustUUID(t)
	SignCapability(sc, privS)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sc, ContextId: ctx, ScopeId: scopeID, ScopeSha256: d32(0xAA),
	}
	reseal(r)

	pol := func(trust CapabilityTrust) AuthorizationPolicy {
		return AuthorizationPolicy{Trust: trust, NowUnixNano: nowFor(t, r.GetEventId()),
			ActiveFence: ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()), TrustPolicyEpoch: 1}
	}
	trustWith := func(prodStatus, srcStatus KeyStatus) funcTrust {
		return funcTrust(func(issuerID, _ []byte, ev KeyEvidence) KeyResolution {
			switch {
			case bytes.Equal(issuerID, prodIssuer):
				return KeyResolution{Status: prodStatus, Public: pubP, Purpose: ev.Purpose}
			case bytes.Equal(issuerID, srcIssuer):
				return KeyResolution{Status: srcStatus, Public: pubS, Purpose: ev.Purpose}
			default:
				return KeyResolution{Status: KeyInvalid, Purpose: ev.Purpose}
			}
		})
	}

	if err := ValidateRecordSigned(r, pol(trustWith(KeyValid, KeyValid))); err != nil {
		t.Fatalf("both keys valid must apply: %v", err)
	}
	if err := ValidateRecordSigned(r, pol(trustWith(KeyValid, KeyHistoricallyRevoked))); !errors.Is(err, ErrKeyHistoricallyRevoked) {
		t.Fatalf("compromised SOURCE (prod valid) = %v, want ErrKeyHistoricallyRevoked", err)
	}
	if err := ValidateRecordSigned(r, pol(trustWith(KeyHistoricallyRevoked, KeyValid))); !errors.Is(err, ErrKeyHistoricallyRevoked) {
		t.Fatalf("compromised PRODUCTION (source valid) = %v, want ErrKeyHistoricallyRevoked", err)
	}
	if err := ValidateRecordSigned(r, pol(trustWith(KeyValid, KeyInvalid))); !errors.Is(err, ErrCapabilityKeyUnresolved) {
		t.Fatalf("invalid SOURCE key = %v, want ErrCapabilityKeyUnresolved (permanent)", err)
	}
}
