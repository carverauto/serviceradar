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
	"crypto/sha256"
	"errors"
	"fmt"
	"math"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// frameRecordBytesFieldNumber is EdgeDeliveryFrameV1.record_bytes (field 5).
const frameRecordBytesFieldNumber = 5

const (
	sha256Len            = 32
	uuidLen              = 16
	MaxCompressionRatio  = 100
	MaxUncompressedBytes = 32 * 1024 * 1024
	// MaxZstdWindowBytes bounds the WINDOW a Zstd frame may advertise -- what the decoder
	// must retain as history while producing output, as distinct from how much output there
	// is. v1 gives it the SAME VALUE as MaxUncompressedBytes, and that is a coincidence
	// rather than a rule: they answer different questions, and a frame advertising a 64 MiB
	// window while emitting 1 MiB passes the output ceiling and the ratio and is still
	// refused. Spelling it separately is what stops a change to one silently moving the
	// other.
	MaxZstdWindowBytes = 32 * 1024 * 1024

	// Hard caps applied when a caller passes a non-positive limit, so an ack byte
	// or count budget is ALWAYS enforced (a zero max never disables the limit).
	DefaultMaxDispositions     = 4096
	DefaultMaxDispositionBytes = 256 * 1024

	// Lane-open bounds.
	MinNonceBytes   = 16
	MaxNonceBytes   = 64
	MaxByteCredits  = 1 << 30
	MaxFrameCredits = 1 << 20

	// MaxClockToleranceNano bounds the authority-window clock skew (5 minutes). A tolerance above
	// this would widen every window toward "all time"; a policy outside [0, MaxClockToleranceNano]
	// is rejected fail-closed rather than silently trusted.
	MaxClockToleranceNano = 5 * 60 * 1_000_000_000

	// Frozen RAW wire size bounds for the three decode stages, enforced BEFORE protobuf decode so an
	// unbounded/oversize input is a PERMANENT rejection (ErrRecordTooLarge/ErrFrameTooLarge/
	// ErrClientMessageTooLarge), NOT poison and NOT an undecodable-but-retried input. They bound the
	// EXACT received bytes, not proto.Size (which collapses non-minimal encodings). MaxRecordBytes
	// (512 KiB) is defined in canonical.go.
	//
	// MaxDeliveryEnvelopeBytes bounds a delivery frame's NON-record overhead: the signed delivery
	// capability, spool_id, record_sha256, sequence, and field framing. A signed capability is ~1 KiB;
	// 16 KiB is a generous, fixed ceiling.
	MaxDeliveryEnvelopeBytes = 16 * 1024
	// MaxFrameBytes bounds one raw EdgeDeliveryFrameV1 = record bytes (<= MaxRecordBytes) + the
	// delivery envelope.
	MaxFrameBytes = MaxRecordBytes + MaxDeliveryEnvelopeBytes
	// MaxClientMessageBytes bounds one raw EdgeRecordClientMessage: a lane_open OR a delivery_frame
	// plus the oneof field tag (1 byte) and length prefix (<= 5 bytes for a varint of MaxFrameBytes).
	MaxClientMessageBytes = MaxFrameBytes + 8
)

var (
	ErrNilRecord     = errors.New("edgerecord: nil record")
	ErrPayloadFamily = errors.New("edgerecord: payload family unspecified/unknown")
	// ErrPayloadFraming is the FAMILY <-> TYPED ENTRY POINT invariant, distinct from
	// ErrPayloadFamily: the value is a declared member, but it is not the framing family this
	// ingress accepts. Separate sentinels because "not a family" and "not THIS family" are
	// different faults, and a caller that merged them could not tell a malformed record from a
	// misrouted one.
	ErrPayloadFraming        = errors.New("edgerecord: payload family may not enter this ingress")
	ErrRouteProfile          = errors.New("edgerecord: route profile unspecified/unknown")
	ErrTrafficClass          = errors.New("edgerecord: traffic class unspecified/unknown")
	ErrCompression           = errors.New("edgerecord: compression unspecified/unknown")
	ErrContract              = errors.New("edgerecord: output contract missing or malformed")
	ErrNetworkScope          = errors.New("edgerecord: authoritative network scope missing/malformed")
	ErrCostModel             = errors.New("edgerecord: cost model version missing")
	ErrDigestLength          = errors.New("edgerecord: digest is not 32 bytes")
	ErrSemanticDigest        = errors.New("edgerecord: semantic envelope digest mismatch")
	ErrIdentity              = errors.New("edgerecord: malformed identity")
	ErrOrigin                = errors.New("edgerecord: producer origin unspecified/unknown")
	ErrProducerContext       = errors.New("edgerecord: producer context missing/incomplete")
	ErrPayloadDigest         = errors.New("edgerecord: payload does not match payload_sha256")
	ErrEncodedSize           = errors.New("edgerecord: encoded_size does not match payload length")
	ErrUncompressedSize      = errors.New("edgerecord: uncompressed_size invalid for compression")
	ErrPayloadTooLarge       = errors.New("edgerecord: payload exceeds bound")
	ErrRecordTooLarge        = errors.New("edgerecord: encoded record exceeds 512 KiB bound")
	ErrRecordDecode          = errors.New("edgerecord: record bytes do not decode")
	ErrRecordEncode          = errors.New("edgerecord: record cannot be canonically encoded")
	ErrUnknownFields         = errors.New("edgerecord: record retains unknown protobuf fields")
	ErrRecordBytes           = errors.New("edgerecord: delivery frame carries no record bytes")
	ErrDeliverySequence      = errors.New("edgerecord: delivery sequence must be >= 1")
	ErrRecordChecksum        = errors.New("edgerecord: record checksum mismatch")
	ErrSourceAuthorization   = errors.New("edgerecord: source authorization missing/invalid")
	ErrSourceAuthKind        = errors.New("edgerecord: source authorization kind unspecified/unknown")
	ErrProductionGrant       = errors.New("edgerecord: production capability does not authorize this record")
	ErrIdentityTime          = errors.New("edgerecord: event identity time outside the signed authority window")
	ErrRecoveryLane          = errors.New("edgerecord: recovery payload/route/authority mismatch")
	ErrLaneRouteClass        = errors.New("edgerecord: lane route/class unspecified/unknown")
	ErrSequenceBase          = errors.New("edgerecord: sequence base must be 1")
	ErrNonce                 = errors.New("edgerecord: session nonce missing")
	ErrSessionMismatch       = errors.New("edgerecord: record route/class does not match the session lane")
	ErrAckBinding            = errors.New("edgerecord: ack not bound to the session nonce/spool")
	ErrAckWindow             = errors.New("edgerecord: ack resolves beyond the sent window")
	ErrDisposition           = errors.New("edgerecord: invalid ack disposition")
	ErrAuthorityExpired      = errors.New("edgerecord: capability authority is not current at evaluation time")
	ErrFenceStale            = errors.New("edgerecord: producer authority epoch is below the active fence")
	ErrDeliveryDecision      = errors.New("edgerecord: no current publication authority for this record")
	ErrDeliveryRenewalWindow = errors.New("edgerecord: delivery renewal window invalid")
	ErrLaneCredits           = errors.New("edgerecord: lane-open credits missing/over cap/over request")
	ErrAuthorityNotYetValid  = errors.New("edgerecord: capability authority is not yet valid at evaluation time")
	ErrDeliveryClaims        = errors.New("edgerecord: delivery claims malformed")
	ErrClockTolerance        = errors.New("edgerecord: clock tolerance out of [0, MaxClockToleranceNano]")
	// ErrFenceNotReady is RETRYABLE: the active authority fence is unavailable (never resolved) or the
	// record's authority epoch is a locally-unknown FUTURE generation. The caller MUST leave the
	// record unresolved (not-ready) and retry once the fence is known -- it MUST NOT authorize.
	ErrFenceNotReady         = errors.New("edgerecord: active authority fence unavailable or ahead of record (retryable)")
	ErrTrustEpochUnset       = errors.New("edgerecord: trust-policy epoch not pinned (zero); all key resolutions in one decision must share a nonzero epoch")
	ErrFrameTooLarge         = errors.New("edgerecord: raw delivery frame exceeds MaxFrameBytes bound")
	ErrClientMessageTooLarge = errors.New("edgerecord: raw client message exceeds MaxClientMessageBytes bound")
)

// FenceRelation classifies a record's producer authority epoch against the active fence generation.
type FenceRelation uint8

const (
	// FenceUnavailable -- the active fence was never resolved (zero-value/unknown). RETRYABLE:
	// NEVER authorize (a forgotten or failed fence lookup must not read as "epoch 0 is current").
	FenceUnavailable FenceRelation = iota
	// FenceCurrent -- the record's epoch EQUALS the active generation.
	FenceCurrent
	// FenceStale -- the record's epoch is BELOW the active generation (an old, fenced-out producer).
	FenceStale
	// FenceFuture -- the record's epoch is ABOVE the active generation: a locally-unknown FUTURE
	// fence. RETRYABLE (we cannot yet validate a generation we have not learned); never authorize.
	FenceFuture
)

// ActiveFence is the resolved active authority fence. The ZERO value is UNAVAILABLE, so an
// AuthorizationPolicy whose fence was never set NEVER authorizes -- a missing/failed fence lookup can
// never masquerade as "epoch 0 is current". Construct a known fence with ResolvedFence.
type ActiveFence struct {
	resolved bool
	epoch    uint64
}

// ResolvedFence builds a known active fence at the given generation epoch.
func ResolvedFence(epoch uint64) ActiveFence { return ActiveFence{resolved: true, epoch: epoch} }

// relation classifies a record's producer authority epoch against this fence. An unresolved fence is
// always FenceUnavailable (retryable), regardless of the record's epoch.
func (fence ActiveFence) relation(recordEpoch uint64) FenceRelation {
	if !fence.resolved {
		return FenceUnavailable
	}
	switch {
	case recordEpoch < fence.epoch:
		return FenceStale
	case recordEpoch > fence.epoch:
		return FenceFuture
	default:
		return FenceCurrent
	}
}

// AuthorizationPolicy is the evaluation context the signed boundary decides
// against: the issuer-key resolver, a trusted evaluation time (+ clock
// tolerance), and the active authority fence (an explicit ActiveFence, whose zero
// value is UNAVAILABLE and never authorizes). Historical collection evidence
// (source authority + the record's event time) stays bound to its original
// window, but PUBLICATION requires production authority current at NowUnixNano
// and a producer fence at the active generation.
type AuthorizationPolicy struct {
	Trust              CapabilityTrust
	NowUnixNano        int64
	ClockToleranceNano int64
	ActiveFence        ActiveFence
	// TrustPolicyEpoch is the single immutable trust-policy snapshot for the WHOLE decision. Every
	// capability (production, source, delivery) resolves at THIS epoch, so a mid-decision revocation
	// cannot mix snapshots inside one frame. Zero is INVALID -- the signed boundary fails closed
	// (ErrTrustEpochUnset) rather than resolve keys against an unpinned policy.
	TrustPolicyEpoch uint64
}

// validateClockTolerance rejects a policy whose clock tolerance is outside [0,
// MaxClockToleranceNano] -- a negative tolerance would silently shrink windows and an unbounded
// positive one would widen every window toward "all time". The signed boundary calls this first
// and returns a zero decision + error on an invalid policy.
func (p AuthorizationPolicy) validateClockTolerance() error {
	if p.ClockToleranceNano < 0 || p.ClockToleranceNano > MaxClockToleranceNano {
		return ErrClockTolerance
	}
	return nil
}

// clampTolerance bounds a clock tolerance to [0, MaxClockToleranceNano] as defense in depth, so
// currentAt/notYetValid can never widen a window past the cap even if a caller bypasses
// validateClockTolerance.
func clampTolerance(t int64) int64 {
	switch {
	case t < 0:
		return 0
	case t > MaxClockToleranceNano:
		return MaxClockToleranceNano
	default:
		return t
	}
}

// satSub / satAdd are saturating int64 arithmetic: the widened window endpoints
// notBefore-tolerance and expires+tolerance can otherwise underflow/overflow past the int64
// boundary and misclassify authority. They clamp to Min/MaxInt64 instead of wrapping.
func satSub(a, b int64) int64 {
	switch {
	case b > 0 && a < math.MinInt64+b:
		return math.MinInt64
	case b < 0 && a > math.MaxInt64+b:
		return math.MaxInt64
	default:
		return a - b
	}
}

func satAdd(a, b int64) int64 {
	switch {
	case b > 0 && a > math.MaxInt64-b:
		return math.MaxInt64
	case b < 0 && a < math.MinInt64-b:
		return math.MinInt64
	default:
		return a + b
	}
}

// currentAt reports whether now lies inside [notBefore, expires] widened by the (clamped) clock
// tolerance, using saturating endpoints (inclusive on both ends).
func (p AuthorizationPolicy) currentAt(notBefore, expires int64) bool {
	tol := clampTolerance(p.ClockToleranceNano)
	return p.NowUnixNano >= satSub(notBefore, tol) && p.NowUnixNano <= satAdd(expires, tol)
}

// notYetValid reports whether now precedes the tolerance-widened start of the window.
func (p AuthorizationPolicy) notYetValid(notBefore int64) bool {
	return p.NowUnixNano < satSub(notBefore, clampTolerance(p.ClockToleranceNano))
}

// ValidateRecordSigned is the AUTHORIZATION boundary: structural ValidateRecord,
// then cryptographic verification of every present capability against the
// resolved issuer key, then the current-authority decision -- production
// authority MUST be current at the trusted now and the producer fence MUST NOT be
// stale. Historical source authority is verified but not required to be current
// (its window is bound to the event time). The gateway/sink MUST use this (or
// ValidateFrameSigned for late drain), never structural ValidateRecord, to treat
// a record as authorized.
func ValidateRecordSigned(r *edgev1.EdgeRecordV1, policy AuthorizationPolicy) error {
	if isNilTrust(policy.Trust) {
		return ErrTrustMissing
	}
	// Every key resolution in this decision MUST share one pinned nonzero trust-policy epoch, so a
	// mid-decision revocation cannot mix snapshots. A zero epoch fails closed.
	if policy.TrustPolicyEpoch == 0 {
		return ErrTrustEpochUnset
	}
	if err := policy.validateClockTolerance(); err != nil {
		return err
	}
	if err := ValidateRecord(r); err != nil {
		return err
	}
	pc := r.GetProductionCapability()
	prodStatus, err := VerifyCapabilityWithTrust(pc,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
	if err != nil {
		return fmt.Errorf("production_capability: %w", err)
	}
	// AGGREGATE the WORST trust outcome across production AND source authority. The source status is
	// NOT discarded: a COMPROMISE-revoked SOURCE key downgrades the whole record to audit even when
	// production verifies, so a compromised capability can never slip through as a fresh apply.
	worst := prodStatus
	if sa := r.GetSourceAuthorization(); sa != nil {
		srcStatus, srcErr := VerifyCapabilityWithTrust(sa.GetCapability(),
			edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
		if srcErr != nil {
			return fmt.Errorf("source_authorization: %w", srcErr)
		}
		worst = worseKeyStatus(worst, srcStatus)
	}
	// A COMPROMISE-revoked signing key (production OR source) can NEVER authoritative_apply here. It is
	// REACHABLE as ledger_only/audit + security quarantine, surfaced distinctly (NOT a permanent
	// reject), and dominates window/fence -- a compromised key is audit-only regardless of freshness.
	// (Normal expiry/rotation is KeyValid via retained history and passes.)
	if worst == KeyHistoricallyRevoked {
		return ErrKeyHistoricallyRevoked
	}
	// A FRESH apply requires production authority CURRENT at the trusted now.
	if !policy.currentAt(pc.GetNotBeforeUnixNano(), pc.GetExpiresAtUnixNano()) {
		return fmt.Errorf("production_capability: %w", ErrAuthorityExpired)
	}
	// Fence classification is explicit: an UNAVAILABLE fence (never resolved) or a FUTURE epoch (a
	// generation we have not learned) is RETRYABLE (ErrFenceNotReady) and NEVER authorizes; a STALE
	// epoch is fenced out. Only a CURRENT epoch passes.
	switch policy.ActiveFence.relation(r.GetProducerContext().GetAuthorityEpoch()) {
	case FenceUnavailable, FenceFuture:
		return ErrFenceNotReady
	case FenceStale:
		return ErrFenceStale
	case FenceCurrent:
	}
	return nil
}

// ValidateFrameSigned is the composed delivery decision. It ALWAYS decodes and
// signature-verifies the enclosed record (so an invalid enclosed production/source
// signature is caught even when no delivery capability is present), then decides
// publication authority: EITHER the record's own production authority is current
// at now, OR a current, signed, correctly-scoped delivery capability authorizes a
// late drain (renewal window contains now and is inside the signed envelope, or a
// rollover). A record whose production authority expired and that carries no
// current delivery grant is refused.
func ValidateFrameSigned(f *edgev1.EdgeDeliveryFrameV1, policy AuthorizationPolicy) (FrameDecision, error) {
	if isNilTrust(policy.Trust) {
		return FrameDecision{}, ErrTrustMissing
	}
	// One pinned nonzero trust-policy epoch for the whole frame decision (production/source/delivery all
	// resolve at it), so a revocation race cannot mix snapshots. A zero epoch fails closed.
	if policy.TrustPolicyEpoch == 0 {
		return FrameDecision{}, ErrTrustEpochUnset
	}
	if err := policy.validateClockTolerance(); err != nil {
		return FrameDecision{}, err
	}
	if err := ValidateDeliveryFrame(f, true); err != nil {
		return FrameDecision{}, err
	}
	record, err := DecodeRecord(f.GetRecordBytes())
	if err != nil {
		return FrameDecision{}, err
	}
	// Verify the enclosed record's signatures + structure (WITHOUT the current-now
	// requirement -- late drain of historically-valid evidence is the whole point).
	pc := record.GetProductionCapability()
	prodStatus, err := VerifyCapabilityWithTrust(pc,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
	if err != nil {
		// KeyUnavailable -> ErrKeyUnavailable (retryable); KeyInvalid -> ErrCapabilityKeyUnresolved
		// (permanent); a bad signature -> ErrCapabilitySignatureInvalid. All propagate as-is.
		return FrameDecision{}, fmt.Errorf("production_capability: %w", err)
	}
	// AGGREGATE the worst trust outcome across production AND source: a COMPROMISE-revoked SOURCE key
	// downgrades the whole frame to audit even when production verifies (the source status is not
	// discarded). Normal expiry/rotation is KeyValid via retained history and does not downgrade.
	worst := prodStatus
	if sa := record.GetSourceAuthorization(); sa != nil {
		srcStatus, srcErr := VerifyCapabilityWithTrust(sa.GetCapability(),
			edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
		if srcErr != nil {
			return FrameDecision{}, fmt.Errorf("source_authorization: %w", srcErr)
		}
		worst = worseKeyStatus(worst, srcStatus)
	}

	// COMPROMISE (production OR source key) is a SECURITY downgrade that PRECEDES fence / window /
	// late-grant classification and requires NO delivery grant: the frame is DURABLY CAPTURED to the
	// security-quarantine stream (ledger_only + security-quarantine DLQ downstream) -- a REACHABLE
	// TERMINAL outcome, never masked by a stale/unavailable fence and never refused for want of a
	// delivery grant. The delivery grant governs stale/expired DELIVERY, not the security downgrade.
	if worst == KeyHistoricallyRevoked {
		return FrameDecision{
			Publication:     FramePublicationSecurityQuarantine,
			DeliveryMode:    FrameDeliveryModeFresh,
			GrantTransition: FrameGrantNone,
		}, nil
	}

	dc := f.GetDeliveryCapability()
	// Explicit fence classification: an UNAVAILABLE fence (never resolved) or a FUTURE epoch (a
	// generation we have not learned) is RETRYABLE (ErrFenceNotReady) and produces NO decision; only
	// a resolved CURRENT/STALE fence proceeds.
	rel := policy.ActiveFence.relation(record.GetProducerContext().GetAuthorityEpoch())
	switch rel {
	case FenceUnavailable, FenceFuture:
		return FrameDecision{}, ErrFenceNotReady
	case FenceCurrent, FenceStale:
	}
	fenceStale := rel == FenceStale
	// Classify the production window three ways -- NOT-YET-VALID / CURRENT / EXPIRED -- instead of
	// collapsing not-yet-valid and expired into "!current". A future-dated production grant can
	// NEVER be used early, even with a current delivery grant; only EXPIRED authority is renewable.
	notBefore, expires := pc.GetNotBeforeUnixNano(), pc.GetExpiresAtUnixNano()
	if policy.notYetValid(notBefore) {
		return FrameDecision{}, fmt.Errorf("production_capability: %w", ErrAuthorityNotYetValid)
	}
	prodCurrent := policy.currentAt(notBefore, expires)

	// Fresh/primary publish: production authority current, fence current (compromise was already
	// captured terminally above) -> PRIMARY apply. The DELIVERY MODE is GRANT-driven, NOT "Fresh because
	// authority is current": an ATTACHED valid grant (a current-authority rollover recovering a prior
	// spool, or a renewal) makes the mode RENEWAL/ROLLOVER so its recovery proof is carried; only a frame
	// with NO grant is FRESH. A forged attached grant still fails verification.
	if prodCurrent && !fenceStale {
		grant := FrameGrantNone
		if dc != nil {
			if grant, err = verifyDeliveryGrant(dc, policy); err != nil {
				return FrameDecision{}, err
			}
		}
		mode := FrameDeliveryModeFresh
		if grant != FrameGrantNone {
			mode = lateDrainMode(grant)
		}
		return FrameDecision{Publication: FramePublicationPrimary, DeliveryMode: mode, GrantTransition: grant}, nil
	}

	// Otherwise (EXPIRED production authority, a stale fence, OR an audit-only revoked key) a current,
	// signed delivery grant re-authorizes a late/audit delivery. With no valid grant the frame is
	// refused; the specific cause (stale fence / revoked key / expired) is returned so the caller can
	// distinguish it.
	if dc == nil {
		if fenceStale {
			return FrameDecision{}, ErrFenceStale
		}
		return FrameDecision{}, fmt.Errorf("%w: expired production authority and no delivery grant", ErrDeliveryDecision)
	}
	grant, err := verifyDeliveryGrant(dc, policy)
	if err != nil {
		return FrameDecision{}, err
	}
	// A STALE FENCE is the AUDIT publication with delivery mode LATE_FENCED_DELIVERY. A CURRENT fence
	// with merely-expired production authority is an ORDINARY late drain -- PRIMARY publication with
	// delivery mode = the grant's transition.
	if fenceStale {
		return FrameDecision{Publication: FramePublicationAudit, DeliveryMode: FrameDeliveryModeLateFenced, GrantTransition: grant}, nil
	}
	return FrameDecision{Publication: FramePublicationPrimary, DeliveryMode: lateDrainMode(grant), GrantTransition: grant}, nil
}

// lateDrainMode maps a late-drain grant transition to its transport delivery mode.
func lateDrainMode(grant FrameGrantTransition) FrameDeliveryMode {
	if grant == FrameGrantRollover {
		return FrameDeliveryModeRollover
	}
	return FrameDeliveryModeRenewal
}

// verifyDeliveryGrant verifies a delivery capability's signature (via trust), reuses the complete
// delivery-claim validator (validateDeliveryClaims), checks the current-now envelope window, and
// -- for a renewal -- that the inner renewal window sits inside the signed envelope AND contains
// now. It returns which grant transition (renewal/rollover) authorized the outcome.
func verifyDeliveryGrant(dc *edgev1.EdgeSignedCapabilityV1, policy AuthorizationPolicy) (FrameGrantTransition, error) {
	// A delivery grant re-authorizes a CURRENT late/audit drain, so its key must be currently valid.
	// A retired-since (KeyHistoricallyRevoked) delivery key cannot authorize a current drain (it would
	// be self-contradictory with the current-window check below), so require KeyValid.
	status, err := VerifyCapabilityWithTrust(dc,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
	if err != nil {
		return FrameGrantNone, fmt.Errorf("delivery_capability: %w", err)
	}
	if status != KeyValid {
		return FrameGrantNone, fmt.Errorf("delivery_capability: %w", ErrKeyHistoricallyRevoked)
	}
	claims := dc.GetDelivery()
	if err := validateDeliveryClaims(claims); err != nil {
		return FrameGrantNone, fmt.Errorf("delivery_capability: %w", err)
	}
	if !policy.currentAt(dc.GetNotBeforeUnixNano(), dc.GetExpiresAtUnixNano()) {
		return FrameGrantNone, fmt.Errorf("delivery_capability: %w", ErrAuthorityExpired)
	}
	if rn := claims.GetRenewal(); rn != nil {
		if rn.GetRenewedNotBeforeUnixNano() < dc.GetNotBeforeUnixNano() ||
			rn.GetRenewedExpiresUnixNano() > dc.GetExpiresAtUnixNano() ||
			!policy.currentAt(rn.GetRenewedNotBeforeUnixNano(), rn.GetRenewedExpiresUnixNano()) {
			return FrameGrantNone, fmt.Errorf("delivery_capability: %w: renewal window", ErrDeliveryRenewalWindow)
		}
		return FrameGrantRenewal, nil
	}
	return FrameGrantRollover, nil
}

// validateDeliveryClaims is the single, frame-INDEPENDENT delivery-claim validator reused by frame
// admission (ValidateDeliveryFrame) AND publication-proof generation (DeliveryProofDigest): bound
// event_id/spool_id (UUIDv7), record_sha256 (32 bytes), a nonzero sequence, and a well-formed
// transition member -- a renewal's inner window well-ordered; a rollover's recovery_id a UUIDv7,
// prior_spool_id a canonical UUID, and prior_sequence >= 1.
func validateDeliveryClaims(claims *edgev1.EdgeDeliveryClaimsV1) error {
	if claims == nil {
		return fmt.Errorf("%w: missing delivery claims", ErrDeliveryClaims)
	}
	if err := validateUUIDv7Field(claims.GetEventId()); err != nil {
		return fmt.Errorf("%w: event_id", ErrDeliveryClaims)
	}
	if len(claims.GetRecordSha256()) != sha256Len {
		return fmt.Errorf("%w: record_sha256", ErrDeliveryClaims)
	}
	if err := validateUUIDv7Field(claims.GetSpoolId()); err != nil {
		return fmt.Errorf("%w: spool_id", ErrDeliveryClaims)
	}
	if claims.GetSequence() == 0 {
		return fmt.Errorf("%w: sequence", ErrDeliveryClaims)
	}
	switch tr := claims.GetTransition().(type) {
	case *edgev1.EdgeDeliveryClaimsV1_Renewal:
		if tr.Renewal.GetRenewedExpiresUnixNano() <= tr.Renewal.GetRenewedNotBeforeUnixNano() {
			return fmt.Errorf("%w: renewal window", ErrDeliveryClaims)
		}
	case *edgev1.EdgeDeliveryClaimsV1_Rollover:
		ro := tr.Rollover
		if err := validateUUIDv7Field(ro.GetRecoveryId()); err != nil {
			return fmt.Errorf("%w: recovery_id", ErrDeliveryClaims)
		}
		// prior_spool_id is a UUIDv7 (not merely any canonical UUID) and MUST DIFFER from this
		// claim's spool_id -- a rollover moves to a NEW spool, so a same-spool rollover is invalid.
		if err := validateUUIDv7Field(ro.GetPriorSpoolId()); err != nil {
			return fmt.Errorf("%w: prior_spool_id", ErrDeliveryClaims)
		}
		if bytes.Equal(ro.GetPriorSpoolId(), claims.GetSpoolId()) {
			return fmt.Errorf("%w: prior_spool_id equals spool_id", ErrDeliveryClaims)
		}
		if ro.GetPriorSequence() == 0 {
			return fmt.Errorf("%w: prior_sequence", ErrDeliveryClaims)
		}
	default:
		return fmt.Errorf("%w: transition (renewal|rollover) required", ErrDeliveryClaims)
	}
	return nil
}

// FramePublication is the GATEWAY-side publication outcome only -- which durable subject the
// authenticated gateway/publisher publishes this frame to. It is NOT the EventWriter projection
// decision: primary publication does NOT authorize projection. EventWriter INDEPENDENTLY re-checks
// the producer fence transactionally at apply time (a fence that was current at publication can be
// stale by then), so a Primary here may still resolve to ledger_only/audit downstream. The ZERO
// value is UNSPECIFIED / INVALID, so an error path (which returns the zero FrameDecision) can never
// be misread as a publication outcome.
type FramePublication uint8

const (
	// FramePublicationUnspecified is the zero value: not decided / invalid. Never treat as success.
	FramePublicationUnspecified FramePublication = iota
	// FramePublicationPrimary -- the gateway publishes to the primary durable stream (fresh publish
	// OR an ordinary late drain). This is a PUBLICATION outcome, NOT projection authority; EventWriter
	// still re-checks the fence transactionally before it may apply.
	FramePublicationPrimary
	// FramePublicationAudit -- the gateway publishes to the audit stream (the stale-fence late-fenced
	// outcome); EventWriter treats it as ledger-audit-only.
	FramePublicationAudit
	// FramePublicationSecurityQuarantine -- a COMPROMISE-revoked production/source key. The frame is
	// durably captured to the SECURITY-QUARANTINE stream (a distinct terminal outcome that PRECEDES
	// fence/late-grant classification and needs NO delivery grant); EventWriter projects it ledger_only
	// and routes it to the security-quarantine DLQ. Distinct from FramePublicationAudit (valid
	// historical evidence under a stale fence), because the trust downgrade is a security event.
	FramePublicationSecurityQuarantine
)

// FrameDeliveryMode is the gateway-attested transport disposition, aligned one-to-one with the
// provenance delivery_mode (1=FRESH / 2=RENEWAL / 3=ROLLOVER / 4=LATE_FENCED_DELIVERY). The zero
// value is UNSPECIFIED / INVALID.
type FrameDeliveryMode uint8

const (
	// FrameDeliveryModeUnspecified is the zero value: not decided / invalid.
	FrameDeliveryModeUnspecified FrameDeliveryMode = iota
	// FrameDeliveryModeFresh -- a fresh publish (no late grant used for the transport disposition).
	FrameDeliveryModeFresh
	// FrameDeliveryModeRenewal -- a late drain authorized by a same-spool renewal.
	FrameDeliveryModeRenewal
	// FrameDeliveryModeRollover -- a late drain authorized by a recovery rollover.
	FrameDeliveryModeRollover
	// FrameDeliveryModeLateFenced -- a stale-fence late-fenced delivery (audit).
	FrameDeliveryModeLateFenced
)

// FrameGrantTransition records which delivery-capability transition (if any) authorized the
// outcome, INDEPENDENT of the publication/mode. None when no grant was used (fresh, no grant).
type FrameGrantTransition uint8

const (
	// FrameGrantNone -- no delivery grant used.
	FrameGrantNone FrameGrantTransition = iota
	// FrameGrantRenewal -- a same-spool renewal grant.
	FrameGrantRenewal
	// FrameGrantRollover -- a recovery rollover grant.
	FrameGrantRollover
)

// FrameDecision is the typed ValidateFrameSigned outcome across the frozen dimensions. The zero
// value (Publication == FramePublicationUnspecified) is INVALID: callers MUST check the returned
// error and MUST NOT treat the zero value as a decision. Publication is the GATEWAY publication
// outcome ONLY -- it does NOT authorize EventWriter projection, which independently re-checks the
// fence transactionally at apply time. DeliveryMode is the publisher-attested transport
// disposition, and GrantTransition is the (optional) delivery-capability transition that authorized
// a late/attached outcome.
type FrameDecision struct {
	Publication     FramePublication
	DeliveryMode    FrameDeliveryMode
	GrantTransition FrameGrantTransition
}

// ValidateRecord STRUCTURALLY fail-closes an EdgeRecordV1 (it is NOT the crypto
// authorization boundary -- use ValidateRecordSigned for that). In addition to
// structural checks it
// (a) binds the exact payload bytes to the declared digest/sizes/compression and
// bounded-validates a Zstd frame, (b) requires the whole record to encode
// canonically within the 512 KiB bound so a value the delivery path must reject
// can never be accepted here, (c) verifies the production capability authorizes
// this exact record and its identity time falls inside the signed window,
// (d) verifies typed source authorization whose outer values equal its signed
// claims, and (e) enforces the reserved recovery-lane relationship.
func ValidateRecord(r *edgev1.EdgeRecordV1) error {
	if r == nil {
		return ErrNilRecord
	}
	// A record carrying retained unknown protobuf fields is rejected here, exactly
	// as the canonical delivery decode (DecodeRecord) rejects it, so the
	// public ValidateRecord contract never approves bytes the delivery path
	// quarantines. Unknown fields are also not covered by the semantic digest.
	if hasUnknownFields(r) {
		return ErrUnknownFields
	}
	if err := validateUUIDv7Field(r.GetEventId()); err != nil {
		return fmt.Errorf("%w: event_id: %w", ErrIdentity, err)
	}
	if !knownPayloadFamily(r.GetPayloadFamily()) {
		return ErrPayloadFamily
	}
	if !knownRouteProfile(r.GetRouteProfile()) {
		return ErrRouteProfile
	}
	if !knownTrafficClass(r.GetTrafficClass()) {
		return ErrTrafficClass
	}
	if err := validatePayloadBinding(r); err != nil {
		return err
	}
	if err := validateContract(r.GetOutputContract()); err != nil {
		return err
	}
	if err := validateProducerContext(r.GetProducerContext()); err != nil {
		return err
	}
	if ValidateCanonicalUUID(r.GetNetworkScopeId()) != nil {
		return ErrNetworkScope
	}
	if err := validateProductionCapability(r); err != nil {
		return err
	}
	if r.GetCostModelVersion() == 0 {
		return ErrCostModel
	}
	if err := validateSourceAuthorization(r); err != nil {
		return err
	}
	if err := validateRecoveryLane(r); err != nil {
		return err
	}
	if err := validateIdentityTime(r); err != nil {
		return err
	}
	if len(r.GetSemanticEnvelopeSha256()) != sha256Len {
		return fmt.Errorf("%w: semantic_envelope_sha256", ErrDigestLength)
	}
	if !bytes.Equal(SemanticEnvelopeDigest(r), r.GetSemanticEnvelopeSha256()) {
		return ErrSemanticDigest
	}
	// The whole record MUST encode canonically within the hard bound. This
	// catches an oversize full record and any nested marshal error (e.g. invalid
	// UTF-8) that ValidateDeliveryFrame/CanonicalRecordBytes would otherwise
	// reject downstream -- ValidateRecord never approves what the delivery path
	// cannot admit.
	canon, err := CanonicalRecordBytes(r)
	if err != nil {
		return ErrRecordEncode
	}
	if len(canon) > MaxRecordBytes {
		return ErrRecordTooLarge
	}
	return nil
}

func validatePayloadBinding(r *edgev1.EdgeRecordV1) error {
	payload := r.GetPayload()
	if len(payload) > MaxPayloadBytes {
		return ErrPayloadTooLarge
	}
	if int(r.GetEncodedSize()) != len(payload) {
		return ErrEncodedSize
	}
	sum := sha256.Sum256(payload)
	if len(r.GetPayloadSha256()) != sha256Len || !bytes.Equal(sum[:], r.GetPayloadSha256()) {
		return ErrPayloadDigest
	}
	// GATE: knownCompression is the single authority for which codecs are accepted, and it runs
	// BEFORE the per-codec logic below. The switch then only decides HOW to validate an accepted
	// codec, so the accepted SET lives in exactly one place -- the same place the cross-runtime
	// enum-policy manifest reads it from.
	if !knownCompression(r.GetCompression()) {
		return ErrCompression
	}
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch r.GetCompression() {
	case edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE:
		if r.GetUncompressedSize() != r.GetEncodedSize() {
			return ErrUncompressedSize
		}
	case edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD:
		// uncompressed_size is the decoded size. It must be nonzero, under the
		// absolute ceiling, and within the ratio ceiling of the encoded frame so a
		// decompression bomb is refused before decoding. (Zstd may expand a tiny
		// incompressible payload, so there is no lower bound vs encoded_size.)
		u := uint64(r.GetUncompressedSize())
		if u == 0 || u > MaxUncompressedBytes || u > uint64(r.GetEncodedSize())*MaxCompressionRatio {
			return ErrUncompressedSize
		}
		// Actually validate the frame: correct output size, no dictionary, single
		// frame, no trailing bytes.
		if err := ValidateZstdPayload(payload, r.GetUncompressedSize()); err != nil {
			return err
		}
	default:
		return ErrCompression
	}
	return nil
}

// validateProductionCapability requires a PRODUCTION-purpose signed capability
// whose claims authorize THIS attested producer to emit THIS contract at a
// bounded cost. Every signed binding is compared to the record's producer_context
// / output_contract, so a grant issued for one assignment, instance, run, fence
// epoch, package, registry snapshot, or cost ceiling cannot be replayed with
// another producer context (finding: production authority replay across
// assignments).
func validateProductionCapability(r *edgev1.EdgeRecordV1) error {
	pc := r.GetProductionCapability()
	if err := ValidateCapability(pc, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION); err != nil {
		return fmt.Errorf("production_capability: %w", err)
	}
	claims := pc.GetProduction()
	c := r.GetOutputContract()
	p := r.GetProducerContext()
	if claims.GetContractId() != c.GetContractId() ||
		claims.GetContractVersion() != c.GetContractVersion() ||
		!bytes.Equal(claims.GetContractBundleSha256(), c.GetContractBundleSha256()) ||
		claims.GetRegistryEpoch() != c.GetRegistryEpoch() ||
		!bytes.Equal(claims.GetRegistrySnapshotSha256(), c.GetRegistrySnapshotSha256()) ||
		!bytes.Equal(claims.GetEffectiveGrantSha256(), c.GetEffectiveGrantSha256()) {
		return fmt.Errorf("%w: contract", ErrProductionGrant)
	}
	if !bytes.Equal(claims.GetNetworkScopeId(), r.GetNetworkScopeId()) {
		return fmt.Errorf("%w: network scope", ErrProductionGrant)
	}
	if claims.GetTrafficClass() != r.GetTrafficClass() || claims.GetRouteProfile() != r.GetRouteProfile() {
		return fmt.Errorf("%w: class/route", ErrProductionGrant)
	}
	// Attested producer identity: every signed value MUST equal producer_context.
	if claims.GetOriginKind() != p.GetOriginKind() ||
		!bytes.Equal(claims.GetOriginPrincipalId(), p.GetOriginPrincipalId()) ||
		!bytes.Equal(claims.GetProducerInstanceId(), p.GetProducerInstanceId()) ||
		!bytes.Equal(claims.GetProducerAssignmentId(), p.GetProducerAssignmentId()) ||
		!bytes.Equal(claims.GetRunId(), p.GetRunId()) ||
		claims.GetRunShard() != p.GetRunShard() ||
		claims.GetAuthorityEpoch() != p.GetAuthorityEpoch() ||
		!bytes.Equal(claims.GetScopeId(), p.GetScopeId()) ||
		!bytes.Equal(claims.GetScopeSha256(), p.GetScopeSha256()) ||
		!bytes.Equal(claims.GetPackageSha256(), p.GetPackageSha256()) ||
		claims.GetPackageId() != p.GetPackageId() {
		return fmt.Errorf("%w: producer identity", ErrProductionGrant)
	}
	// Cost/fence ceiling: the record's projected work MUST NOT exceed the grant.
	if claims.GetCostModelVersion() != r.GetCostModelVersion() ||
		r.GetProjectedRowCount() > claims.GetMaxProjectedRowCount() ||
		r.GetProjectedWriteBytes() > claims.GetMaxProjectedWriteBytes() {
		return fmt.Errorf("%w: cost ceiling", ErrProductionGrant)
	}
	return nil
}

func validateSourceAuthorization(r *edgev1.EdgeRecordV1) error {
	sa := r.GetSourceAuthorization()
	if sa == nil {
		// No source authorization. Absence is explicit and legal, and does NOT imply
		// PASSIVE attribution -- the two axes are independent.
		return nil
	}
	if !knownSourceAuthKind(sa.GetKind()) {
		return ErrSourceAuthKind
	}
	if err := ValidateCapability(sa.GetCapability(), edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE); err != nil {
		return fmt.Errorf("%w: %w", ErrSourceAuthorization, err)
	}
	claims := sa.GetCapability().GetSource()
	// Outer values MUST equal the signed claims -- no unsigned outer value widens
	// authority.
	if claims.GetKind() != sa.GetKind() ||
		!bytes.Equal(claims.GetContextId(), sa.GetContextId()) ||
		!bytes.Equal(claims.GetScopeId(), sa.GetScopeId()) ||
		!bytes.Equal(claims.GetScopeSha256(), sa.GetScopeSha256()) {
		return fmt.Errorf("%w: outer values do not match signed claims", ErrSourceAuthorization)
	}
	// context/scope ids are canonical UUIDs (any version -- the scheduler allocates
	// v4); only event/trace identity-time ids are strict v7.
	if ValidateCanonicalUUID(sa.GetContextId()) != nil || ValidateCanonicalUUID(sa.GetScopeId()) != nil ||
		len(sa.GetScopeSha256()) != sha256Len {
		return fmt.Errorf("%w: malformed context/scope identity", ErrSourceAuthorization)
	}
	if !bytes.Equal(claims.GetNetworkScopeId(), r.GetNetworkScopeId()) {
		return fmt.Errorf("%w: scope network mismatch", ErrSourceAuthorization)
	}
	// The collection authority is bound to THIS attested producer and lane: the
	// signed agent/assignment/run/shard/epoch and class/route MUST equal the
	// record's producer_context and topology, so source authority cannot be moved
	// to another producer or lane.
	p := r.GetProducerContext()
	if !bytes.Equal(claims.GetOriginPrincipalId(), p.GetOriginPrincipalId()) ||
		!bytes.Equal(claims.GetProducerInstanceId(), p.GetProducerInstanceId()) ||
		!bytes.Equal(claims.GetProducerAssignmentId(), p.GetProducerAssignmentId()) ||
		!bytes.Equal(claims.GetRunId(), p.GetRunId()) ||
		claims.GetRunShard() != p.GetRunShard() ||
		claims.GetAuthorityEpoch() != p.GetAuthorityEpoch() {
		return fmt.Errorf("%w: producer identity", ErrSourceAuthorization)
	}
	if claims.GetTrafficClass() != r.GetTrafficClass() || claims.GetRouteProfile() != r.GetRouteProfile() {
		return fmt.Errorf("%w: class/route", ErrSourceAuthorization)
	}
	if claims.GetOriginKind() != p.GetOriginKind() {
		return fmt.Errorf("%w: origin kind", ErrSourceAuthorization)
	}
	return nil
}

// validateRecoveryLane enforces the reserved recovery lane: a recovery-control
// payload MUST use the recovery route and carry recovery source authority, and
// the recovery route MUST NOT carry non-recovery payloads.
func validateRecoveryLane(r *edgev1.EdgeRecordV1) error {
	recoveryPayload := r.GetPayloadFamily() == edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
	recoveryRoute := r.GetRouteProfile() == edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	if recoveryPayload != recoveryRoute {
		return ErrRecoveryLane
	}
	if recoveryPayload {
		sa := r.GetSourceAuthorization()
		if sa == nil || sa.GetKind() != edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL {
			return ErrRecoveryLane
		}
	} else if sa := r.GetSourceAuthorization(); sa != nil &&
		sa.GetKind() == edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL {
		return ErrRecoveryLane // recovery authority on a non-recovery lane
	}
	return nil
}

// validateIdentityTime requires the event id's embedded UUIDv7 time to fall
// within the production capability's validity window (and the source collection
// window when present), so a stale/forged identity time is rejected.
func validateIdentityTime(r *edgev1.EdgeRecordV1) error {
	ns, err := UUIDv7Nanos(r.GetEventId())
	if err != nil {
		return ErrIdentityTime
	}
	pc := r.GetProductionCapability()
	if ns < pc.GetNotBeforeUnixNano() || ns > pc.GetExpiresAtUnixNano() {
		return fmt.Errorf("%w: production window", ErrIdentityTime)
	}
	if sa := r.GetSourceAuthorization(); sa != nil {
		sc := sa.GetCapability()
		// The event time MUST fall inside BOTH the source capability's signing
		// envelope window (not_before/expires) AND its collection window; either
		// bound may be the narrower one.
		if ns < sc.GetNotBeforeUnixNano() || ns > sc.GetExpiresAtUnixNano() {
			return fmt.Errorf("%w: source envelope window", ErrIdentityTime)
		}
		claims := sc.GetSource()
		if ns < claims.GetCollectionNotBeforeUnixNano() || ns > claims.GetCollectionExpiresUnixNano() {
			return fmt.Errorf("%w: collection window", ErrIdentityTime)
		}
	}
	return nil
}

// ValidateFrameRawEnvelope enforces the RELATIONAL delivery-envelope budget on the EXACT RAW wire bytes
// of an EdgeDeliveryFrameV1, at the DECODE boundary and BEFORE protobuf canonicalization. A decoded-size
// check (proto.Size, in ValidateDeliveryFrame) collapses duplicate/non-minimal fields, so 20 KiB of
// duplicate `sequence` fields would decode to a tiny canonical frame and slip under the budget. This
// peels the LAST record_bytes (field 5) value -- exactly what proto decode keeps (last-wins) -- and
// requires the remaining RAW overhead (everything else on the wire, including duplicate fields) to fit
// MaxDeliveryEnvelopeBytes. Go decode boundaries MUST call this on the raw frame bytes before decode. A
// structurally malformed frame returns ErrRecordDecode (the decode itself would reject it anyway).
func ValidateFrameRawEnvelope(rawFrame []byte) error {
	if len(rawFrame) > MaxFrameBytes {
		return ErrFrameTooLarge
	}
	recordLen := 0
	b := rawFrame
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return ErrRecordDecode
		}
		b = b[n:]
		if num == frameRecordBytesFieldNumber && typ == protowire.BytesType {
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return ErrRecordDecode
			}
			recordLen = len(v) // last-wins, matching proto decode
			b = b[m:]
			continue
		}
		m := protowire.ConsumeFieldValue(num, typ, b)
		if m < 0 {
			return ErrRecordDecode
		}
		b = b[m:]
	}
	if len(rawFrame)-recordLen > MaxDeliveryEnvelopeBytes {
		return fmt.Errorf("%w: raw envelope overhead over budget", ErrFrameTooLarge)
	}
	return nil
}

// ValidateDeliveryFrame fail-closes an EdgeDeliveryFrameV1: sequence >= 1, a
// bounded record_bytes whose SHA-256 matches record_sha256, a valid UUIDv7 spool
// id, a valid optional DELIVERY-purpose delivery capability bound to this record,
// and (when decode is requested) that record_bytes is the exact canonical
// encoding of a valid record. NOTE: the envelope-budget check here uses proto.Size
// (a canonical FLOOR that collapses duplicate fields); the AUTHORITATIVE relational
// bound on raw wire bytes is ValidateFrameRawEnvelope, run at the decode boundary.
func ValidateDeliveryFrame(f *edgev1.EdgeDeliveryFrameV1, decodeRecord bool) error {
	if f == nil {
		return ErrNilRecord
	}
	// Reject retained unknown fields on the frame AND its nested signed delivery
	// capability (recursively): those bytes are outside the field-framed capability
	// signature, so a later reader could reinterpret an authorized frame. The
	// enclosed record's own bytes are opaque here and are checked separately when
	// decoded (DecodeRecord).
	if hasUnknownFields(f) {
		return ErrUnknownFields
	}
	if err := validateUUIDv7Field(f.GetSpoolId()); err != nil {
		return fmt.Errorf("%w: spool_id: %w", ErrIdentity, err)
	}
	if f.GetSequence() < 1 {
		return ErrDeliverySequence
	}
	if len(f.GetRecordBytes()) == 0 {
		return ErrRecordBytes
	}
	if len(f.GetRecordBytes()) > MaxRecordBytes {
		return ErrRecordTooLarge
	}
	// The NON-record overhead (delivery capability + spool/sha/sequence + framing) has its own frozen
	// budget. A frame is bounded RELATIONALLY, not just by total size: a 1-byte record_bytes with a
	// bloated delivery capability / issuer id (which would still be under the total MaxFrameBytes) is
	// rejected. proto.Size is the canonical size; subtracting the record_bytes payload leaves the
	// envelope overhead, which MUST fit MaxDeliveryEnvelopeBytes.
	if proto.Size(f)-len(f.GetRecordBytes()) > MaxDeliveryEnvelopeBytes {
		return fmt.Errorf("%w: delivery envelope overhead over budget", ErrFrameTooLarge)
	}
	if len(f.GetRecordSha256()) != sha256Len {
		return fmt.Errorf("%w: record_sha256", ErrDigestLength)
	}
	sum := sha256.Sum256(f.GetRecordBytes())
	if !bytes.Equal(sum[:], f.GetRecordSha256()) {
		return ErrRecordChecksum
	}
	if dc := f.GetDeliveryCapability(); dc != nil {
		if err := ValidateCapability(dc, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY); err != nil {
			return fmt.Errorf("delivery_capability: %w", err)
		}
		// A delivery capability is bound to the exact record AND the exact mutable
		// coordinate (record bytes, spool, sequence). Its transition oneof models
		// either an ordinary same-spool renewal or a recovery rollover; a renewal
		// cannot pose as a rollover or carry a rollover coordinate.
		claims := dc.GetDelivery()
		if !bytes.Equal(claims.GetRecordSha256(), f.GetRecordSha256()) ||
			!bytes.Equal(claims.GetSpoolId(), f.GetSpoolId()) ||
			claims.GetSequence() != f.GetSequence() {
			return fmt.Errorf("delivery_capability: %w", ErrRecordChecksum)
		}
		// Structural transition validation via the shared delivery-claim validator (renewal window
		// well-ordered; rollover recovery_id/prior_spool UUIDv7 + prior_sequence + prior_spool !=
		// spool_id). The frame binding above pins claims.spool_id == f.spool_id, so the shared
		// validator's prior_spool_id != spool_id check subsumes the frame-specific comparison.
		if err := validateDeliveryClaims(claims); err != nil {
			return fmt.Errorf("delivery_capability: %w", err)
		}
		// The signed event_id MUST equal the enclosed record's event_id: decode the
		// canonical record (recovery/reauthorization is not the hot path).
		record, err := DecodeRecord(f.GetRecordBytes())
		if err != nil {
			return err
		}
		if !bytes.Equal(claims.GetEventId(), record.GetEventId()) {
			return fmt.Errorf("delivery_capability: %w: event id", ErrRecordChecksum)
		}
		if decodeRecord {
			return ValidateRecord(record)
		}
		return nil
	}
	if decodeRecord {
		record, err := DecodeRecord(f.GetRecordBytes())
		if err != nil {
			return err
		}
		return ValidateRecord(record)
	}
	return nil
}

// ValidateServerMessage is the boundary for the gateway-to-agent envelope. The frozen ABI rejects
// recursively retained unknown fields, and that check MUST happen on the WRAPPER before switching on
// the oneof: unknown bytes carried at the envelope root stay on the wrapper and are discarded when a
// caller extracts `GetAck()`, so validating only the inner message leaves the return path
// asymmetric with the recursive client-message boundary.
func ValidateServerMessage(m *edgev1.EdgeRecordServerMessage) error {
	if m == nil {
		return ErrNilRecord
	}

	if hasUnknownFields(m) {
		return ErrUnknownFields
	}

	// The envelope MUST carry exactly one SET variant. An unset oneof, an unknown variant, or a
	// typed-nil inner message (`&..._Ack{Ack: nil}`) all decode into a struct this boundary would
	// otherwise wave through, leaving the caller to deref a nil inner message. Session-specific
	// checks stay in the composed ValidateAck / ValidateLaneOpenAck validators.
	switch p := m.GetPayload().(type) {
	case *edgev1.EdgeRecordServerMessage_Ack:
		if p == nil || p.Ack == nil {
			return ErrNilRecord
		}
	case *edgev1.EdgeRecordServerMessage_LaneOpenAck:
		if p == nil || p.LaneOpenAck == nil {
			return ErrNilRecord
		}
	default:
		// nil (unset) or a variant this build does not know.
		return ErrNilRecord
	}

	return nil
}

// serverMessage oneof field numbers, for the RAW envelope boundary below.
const (
	serverMessageLaneOpenAckFieldNumber = 1
	serverMessageAckFieldNumber         = 2
)

// ValidateServerMessageRawEnvelope enforces, on the EXACT wire bytes, that a gateway-to-agent
// envelope carries EXACTLY ONE payload occurrence -- the same rule the client envelope enforces.
//
// This CANNOT be done on the decoded struct: protobuf resolves a repeated oneof last-one-wins, so
// concatenating `server_lane_open_ack.bin || server_ack.bin` decodes to a single valid ack and the
// duplicate is already lost. Callers validating untrusted server bytes MUST run this BEFORE
// decoding, then ValidateServerMessage on the result.
func ValidateServerMessageRawEnvelope(raw []byte) error {
	payloads := 0
	b := raw

	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return ErrRecordDecode
		}

		b = b[n:]

		if num == serverMessageLaneOpenAckFieldNumber || num == serverMessageAckFieldNumber {
			payloads++
		}

		m := protowire.ConsumeFieldValue(num, typ, b)
		if m < 0 {
			return ErrRecordDecode
		}

		b = b[m:]
	}

	if payloads != 1 {
		return ErrRecordDecode
	}

	return nil
}

// ---------------------------------------------------------------------------
// Lane / session binding (isolation)
// ---------------------------------------------------------------------------

func ValidateLaneOpen(o *edgev1.EdgeRecordLaneOpen) error {
	if o == nil {
		return ErrNilRecord
	}
	// The lane handshake is part of the FROZEN edge ABI, so it rejects RETAINED UNKNOWN FIELDS
	// recursively, exactly as the record/frame/capability boundaries already do. Without this the
	// two runtimes disagree on the same bytes: Go's parser retains a well-formed unknown field (or
	// group) on a lane_open and `ValidateLaneOpen` accepted it, while the Elixir ingress boundary
	// rejects it as wire poison -- a Go-accept versus gateway-close divergence. Fail closed on both
	// sides rather than narrowing the Elixir check.
	if hasUnknownFields(o) {
		return ErrUnknownFields
	}
	if !knownRouteProfile(o.GetRouteProfile()) || !knownTrafficClass(o.GetTrafficClass()) {
		return ErrLaneRouteClass
	}
	if err := validateUUIDv7Field(o.GetSpoolId()); err != nil {
		return fmt.Errorf("%w: spool_id: %w", ErrIdentity, err)
	}
	if o.GetSequenceBase() != 1 {
		return ErrSequenceBase
	}
	// The first unresolved sequence is a real lane sequence (>= base); 0 is invalid.
	if o.GetFirstUnresolvedSequence() < o.GetSequenceBase() {
		return fmt.Errorf("%w: first_unresolved_sequence below base", ErrSequenceBase)
	}
	if len(o.GetSessionNonce()) < MinNonceBytes || len(o.GetSessionNonce()) > MaxNonceBytes {
		return ErrNonce
	}
	// Requested credits must be positive and under the hard admission caps.
	if o.GetRequestedByteCredits() == 0 || o.GetRequestedByteCredits() > MaxByteCredits ||
		o.GetRequestedFrameCredits() == 0 || o.GetRequestedFrameCredits() > MaxFrameCredits {
		return ErrLaneCredits
	}
	return nil
}

// ValidateLaneOpenAck fail-closes the gateway's lane-open ack against the request
// it answers: spool/nonce/route/class MUST echo the request, and granted credits
// MUST be positive, no larger than requested, and under the hard caps.
func ValidateLaneOpenAck(a *edgev1.EdgeRecordLaneOpenAck, req *edgev1.EdgeRecordLaneOpen) error {
	if a == nil || req == nil {
		return ErrNilRecord
	}
	// The RETURN path is part of the same frozen ABI: reject recursively retained unknown fields, as
	// the record/frame/capability/lane-open boundaries do. Otherwise an older peer silently ignores a
	// future qualifier it cannot understand.
	if hasUnknownFields(a) {
		return ErrUnknownFields
	}
	if err := ValidateLaneOpen(req); err != nil {
		return err
	}
	if !bytes.Equal(a.GetSpoolId(), req.GetSpoolId()) || !bytes.Equal(a.GetSessionNonce(), req.GetSessionNonce()) {
		return ErrAckBinding
	}
	if a.GetRouteProfile() != req.GetRouteProfile() || a.GetTrafficClass() != req.GetTrafficClass() {
		return ErrSessionMismatch
	}
	if a.GetGrantedByteCredits() == 0 || a.GetGrantedByteCredits() > req.GetRequestedByteCredits() ||
		a.GetGrantedFrameCredits() == 0 || a.GetGrantedFrameCredits() > req.GetRequestedFrameCredits() {
		return ErrLaneCredits
	}
	return nil
}

// Session is the negotiated lane a frame/ack must match. NextSequence is the
// lowest not-yet-sent sequence; HighestSent is the highest transmitted sequence.
// ResolvedThrough is the sender's prior cumulative watermark. SentEvents maps
// each transmitted sequence to the event_id the sender put on the wire, so an ack
// disposition can be checked against what was actually sent -- reclamation is
// never driven by HighestSent alone.
type Session struct {
	RouteProfile edgev1.EdgeRecordRouteProfile
	TrafficClass edgev1.EdgeRecordTrafficClass
	SpoolID      []byte
	Nonce        []byte
	// FirstUnresolved is the lowest sequence the sender may still (re)transmit;
	// NextSequence is the next never-sent sequence to allocate. A reconnect may
	// replay [FirstUnresolved, HighestSent] AND send the next new sequence, so the
	// two states are represented separately (a retransmit of an unresolved frame
	// below NextSequence is legitimate, not a violation).
	FirstUnresolved uint64
	NextSequence    uint64
	HighestSent     uint64
	ResolvedThrough uint64
	SentEvents      map[uint64][]byte
}

// ValidateFrameForSession validates a delivery frame AND binds it to the
// negotiated lane: the frame's spool must match, its sequence must be in-window,
// and the enclosed record's route profile and traffic class must equal the
// session's.
func ValidateFrameForSession(f *edgev1.EdgeDeliveryFrameV1, s Session) error {
	if err := ValidateDeliveryFrame(f, false); err != nil {
		return err
	}
	if !bytes.Equal(f.GetSpoolId(), s.SpoolID) {
		return fmt.Errorf("%w: spool", ErrSessionMismatch)
	}
	// The legal set is a retransmit of an unresolved sequence
	// [FirstUnresolved, HighestSent] OR EXACTLY the next new sequence (NextSequence)
	// -- a never-sent gap strictly between HighestSent and NextSequence is refused.
	seq := f.GetSequence()
	if seq < s.FirstUnresolved || (seq > s.HighestSent && seq != s.NextSequence) {
		return fmt.Errorf("%w: sequence %d not in replay [%d,%d] nor next %d",
			ErrAckWindow, seq, s.FirstUnresolved, s.HighestSent, s.NextSequence)
	}
	record, err := DecodeRecord(f.GetRecordBytes())
	if err != nil {
		return err
	}
	if err := ValidateRecord(record); err != nil {
		return err
	}
	if record.GetRouteProfile() != s.RouteProfile || record.GetTrafficClass() != s.TrafficClass {
		return ErrSessionMismatch
	}
	return nil
}

// ValidateAck fail-closes a cumulative ack under the EXPLICIT-disposition
// reclamation model. It requires session nonce/spool binding and a resolved_through
// in [ResolvedThrough, HighestSent]. The dispositions are a CONTIGUOUS ascending
// run starting at the first unresolved sequence (ResolvedThrough+1). A present
// event_id MUST equal the event the sender transmitted for that sequence
// (SentEvents); an absent event_id is allowed ONLY for a rejection made before
// record decode (an oversize/undecodable frame, which yields no inner id) and binds
// solely to the authenticated session/spool/sequence. The leading
// RESOLVING prefix -- accepted-authoritative, accepted-audit-only,
// accepted-quarantine, or rejected-permanent, each after its destination PubAck --
// determines resolved_through, which MUST equal ResolvedThrough + that prefix
// length. A rejected-retryable outcome does NOT resolve: it caps the prefix, so
// every disposition after it MUST also be retryable (a retryable sequence leaves
// every higher sequence unresolved). Accepts carry no code; both rejections carry a
// bounded machine-token code. An empty list accompanies zero progress and can never
// silently reclaim a window. Total count and bytes are bounded.
func ValidateAck(a *edgev1.EdgeDeliveryAckV1, s Session, maxDispositions, maxDispositionBytes int) error {
	if a == nil {
		return ErrNilRecord
	}
	// Frozen-ABI unknown-field rejection, recursively (so a nested EdgeRecordDisposition is covered
	// too). This matters most for a CUMULATIVE ack: without it an older sender reclaims spool state
	// while silently ignoring a future/unsupported qualifier it never evaluated.
	if hasUnknownFields(a) {
		return ErrUnknownFields
	}
	if !bytes.Equal(a.GetSpoolId(), s.SpoolID) || !bytes.Equal(a.GetSessionNonce(), s.Nonce) {
		return ErrAckBinding
	}
	rt := a.GetResolvedThroughSequence()
	if rt < s.ResolvedThrough || rt > s.HighestSent {
		return ErrAckWindow
	}
	if maxDispositions <= 0 {
		maxDispositions = DefaultMaxDispositions
	}
	if maxDispositionBytes <= 0 {
		maxDispositionBytes = DefaultMaxDispositionBytes
	}
	disps := a.GetDispositions()
	if len(disps) > maxDispositions {
		return ErrDisposition
	}
	// Byte budget uses the CANONICAL encoded size (proto.Size), which bounds the
	// semantic message. NOTE: this is NOT the received-wire size -- protobuf
	// unmarshal collapses duplicate/non-minimal fields -- so the transport MUST
	// separately enforce a hard inbound limit BEFORE decode. DecodeAck composes
	// that raw guard with this decoded validator in the required order.
	if proto.Size(a) > maxDispositionBytes {
		return fmt.Errorf("%w: canonical ack %d exceeds byte budget %d", ErrDisposition, proto.Size(a), maxDispositionBytes)
	}
	// Fail-closed at sequence exhaustion: a spool MUST roll over before its uint64
	// sequence counter wraps. If the resolved watermark is already at the maximum, no
	// further sequence can exist and ResolvedThrough+1 below would wrap to zero;
	// reject any nonempty ack (an exhausted spool requires a rollover, not more acks).
	if len(disps) > 0 && s.ResolvedThrough == ^uint64(0) {
		return fmt.Errorf("%w: spool sequence space exhausted; a rollover is required", ErrDisposition)
	}
	// Dispositions are a contiguous ascending run from the first unresolved sequence;
	// the run may not extend past the highest sent sequence. Bound with SUBTRACTION
	// (HighestSent >= ResolvedThrough from the watermark-window check above) so the
	// count check cannot itself overflow. Given this bound and the exhaustion guard,
	// every ResolvedThrough+1+i and ResolvedThrough+resolvedPrefix below stays <=
	// HighestSent and never wraps.
	if s.HighestSent < s.ResolvedThrough || uint64(len(disps)) > s.HighestSent-s.ResolvedThrough {
		return fmt.Errorf("%w: dispositions run past the highest sent sequence", ErrDisposition)
	}
	resolvedPrefix := uint64(0)
	retryableTail := false
	for i, d := range disps {
		seq := s.ResolvedThrough + 1 + uint64(i)
		if d.GetSequence() != seq {
			return fmt.Errorf("%w: disposition sequence %d is not the contiguous %d", ErrDisposition, d.GetSequence(), seq)
		}
		resolving, err := validateDispositionKind(d)
		if err != nil {
			return err
		}
		// event_id binding. A PRESENT id MUST equal the event the sender transmitted
		// for this sequence, so a valid-looking disposition for the wrong event cannot
		// drive reclamation. An ABSENT id is permitted ONLY for a rejection the gateway
		// made BEFORE record decode (an oversize/undecodable frame): it cannot read the
		// inner event id, so that disposition binds solely to the authenticated
		// session/spool/sequence. Accepts always decoded the record, so they MUST carry
		// the id.
		switch len(d.GetEventId()) {
		case uuidLen:
			sent, ok := s.SentEvents[seq]
			if !ok || !bytes.Equal(sent, d.GetEventId()) {
				return fmt.Errorf("%w: sequence %d event id does not match sent state", ErrDisposition, seq)
			}
		case 0:
			if k := d.GetKind(); k != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT &&
				k != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE {
				return fmt.Errorf("%w: sequence %d disposition without an event id is only valid for a pre-decode rejection", ErrDisposition, seq)
			}
		default:
			return fmt.Errorf("%w: sequence %d malformed event id", ErrDisposition, seq)
		}
		if resolving {
			// A resolving outcome after a retryable one is impossible: the retryable
			// sequence already left every higher sequence unresolved.
			if retryableTail {
				return fmt.Errorf("%w: resolving disposition after a retryable one", ErrDisposition)
			}
			resolvedPrefix++
		} else {
			retryableTail = true
		}
	}
	// resolved_through advances ONLY across the leading resolving prefix; a
	// retryable outcome caps it and every higher sequence stays unresolved.
	if rt != s.ResolvedThrough+resolvedPrefix {
		return fmt.Errorf("%w: resolved_through %d does not match the resolving prefix %d",
			ErrDisposition, rt, s.ResolvedThrough+resolvedPrefix)
	}
	return nil
}

// MaxRejectionCodeLen bounds a disposition's machine-token rejection code.
const MaxRejectionCodeLen = 64

// validateDispositionKind fail-closes one disposition's kind + rejection-code rule
// and reports whether the kind RESOLVES the spool slot. The four resolving kinds
// (accepted-authoritative/audit-only/quarantine and rejected-permanent) advance the
// resolved prefix; rejected-retryable does not; UNSPECIFIED and any unknown kind
// are rejected. Accepts carry no code; both rejections carry a bounded machine
// token (rejection_code is annotation, never keys the watermark -- kind alone does).
func validateDispositionKind(d *edgev1.EdgeRecordDisposition) (resolving bool, err error) {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch d.GetKind() {
	case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
		edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
		edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE:
		if d.GetRejectionCode() != "" {
			return false, fmt.Errorf("%w: accepted disposition carries a rejection code", ErrDisposition)
		}
		return true, nil
	case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT:
		if err := validateRejectionCode(d.GetRejectionCode()); err != nil {
			return false, err
		}
		return true, nil
	case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE:
		if err := validateRejectionCode(d.GetRejectionCode()); err != nil {
			return false, err
		}
		return false, nil
	default:
		return false, fmt.Errorf("%w: unspecified or unknown disposition kind", ErrDisposition)
	}
}

// validateRejectionCode requires a bounded machine token ([A-Z0-9_], length
// 1..MaxRejectionCodeLen): a stable code a consumer can branch on (e.g.
// WOULD_BLOCK), never free text.
func validateRejectionCode(code string) error {
	if code == "" {
		return fmt.Errorf("%w: rejection without a code", ErrDisposition)
	}
	if len(code) > MaxRejectionCodeLen {
		return fmt.Errorf("%w: rejection code exceeds %d bytes", ErrDisposition, MaxRejectionCodeLen)
	}
	for i := 0; i < len(code); i++ {
		if c := code[i]; (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != '_' {
			return fmt.Errorf("%w: rejection code %q is not a machine token", ErrDisposition, code)
		}
	}
	return nil
}

// ValidateAckRawSize enforces the hard INBOUND wire limit on raw ACK bytes
// BEFORE decode. Use DecodeAck to compose it with decode and validation. proto.Size on the decoded message cannot see duplicate /
// non-minimal fields that inflate the received bytes, so this pre-decode guard (or
// the equivalent gRPC receive-message-size limit) is what actually bounds parse
// cost. A non-positive limit applies the hard default.
func ValidateAckRawSize(raw []byte, maxWireBytes int) error {
	if maxWireBytes <= 0 {
		maxWireBytes = DefaultMaxDispositionBytes
	}
	if len(raw) > maxWireBytes {
		return fmt.Errorf("%w: raw ack %d exceeds wire limit %d", ErrDisposition, len(raw), maxWireBytes)
	}
	return nil
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func validateUUIDv7Field(b []byte) error {
	if len(b) != uuidLen {
		return ErrInvalidUUIDv7
	}
	return ValidateUUIDv7(b)
}

func validateContract(c *edgev1.EdgeOutputContractRef) error {
	if c == nil || c.GetContractId() == "" {
		return ErrContract
	}
	if c.GetContractVersion() == 0 {
		return fmt.Errorf("%w: contract_version must be >= 1", ErrContract)
	}
	if len(c.GetContractBundleSha256()) != sha256Len {
		return fmt.Errorf("%w: contract_bundle_sha256 not 32 bytes", ErrContract)
	}
	if c.GetRegistryEpoch() == 0 {
		return fmt.Errorf("%w: registry_epoch must be >= 1", ErrContract)
	}
	if len(c.GetRegistrySnapshotSha256()) != sha256Len {
		return fmt.Errorf("%w: registry_snapshot_sha256 not 32 bytes", ErrContract)
	}
	if len(c.GetEffectiveGrantSha256()) != sha256Len {
		return fmt.Errorf("%w: effective_grant_sha256 not 32 bytes", ErrContract)
	}
	return nil
}

func validateProducerContext(p *edgev1.EdgeProducerContext) error {
	if p == nil {
		return ErrProducerContext
	}
	if !knownOriginKind(p.GetOriginKind()) {
		return ErrOrigin
	}
	if len(p.GetProducerInstanceId()) == 0 {
		return fmt.Errorf("%w: missing producer instance", ErrProducerContext)
	}
	// origin_principal_id is the authenticated component-id principal: a bounded ASCII
	// token ([A-Za-z0-9_-], 1..128), NOT a UUID. Every typed claim binds this exact value
	// (checked byte-for-byte above), and it is the same value the transport
	// publication-identity headers commit (#4710 decision 5).
	if err := ValidateAuthenticatedPrincipal(p.GetOriginPrincipalId()); err != nil {
		return fmt.Errorf("%w: origin principal: %w", ErrProducerContext, err)
	}
	// Canonical (non-nil, versioned) UUID namespaces -- an all-zero id is rejected.
	if ValidateCanonicalUUID(p.GetProducerAssignmentId()) != nil || ValidateCanonicalUUID(p.GetRunId()) != nil ||
		ValidateCanonicalUUID(p.GetScopeId()) != nil {
		return fmt.Errorf("%w: malformed assignment/run/scope id", ErrProducerContext)
	}
	if len(p.GetScopeSha256()) != sha256Len {
		return fmt.Errorf("%w: malformed producer scope digest", ErrProducerContext)
	}
	// The fence generation MUST be present (a scalar-zero claim cannot silently
	// match an absent producer epoch).
	if p.AuthorityEpoch == nil {
		return fmt.Errorf("%w: authority epoch (fence) required", ErrProducerContext)
	}
	if p.GetPackageId() == "" || len(p.GetPackageSha256()) != sha256Len {
		return fmt.Errorf("%w: missing/malformed package identity", ErrProducerContext)
	}
	return nil
}

// knownOriginKind is the single authority for which origin kinds are accepted. It is used by
// production validation AND by the cross-runtime enum-policy manifest, so a policy edit cannot
// leave the manifest (and therefore the Elixir parity assertion) silently stale.
// knownCompression is the single authority for accepted compression codecs: it mirrors the arms of
// the payload switch below, whose default returns ErrCompression. Shared with the enum-policy
// manifest so a codec change cannot leave the cross-runtime parity fixture stale.
func knownCompression(v edgev1.EdgeRecordCompression) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch v {
	case edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE,
		edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD:
		return true
	default:
		return false
	}
}

func knownOriginKind(v edgev1.EdgeOriginKind) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch v {
	case edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
		edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_CLUSTER_SERVICE:
		return true
	default:
		return false
	}
}

func knownPayloadFamily(v edgev1.EdgeRecordPayloadFamily) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch v {
	case edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_TERMINAL_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1:
		return true
	default:
		return false
	}
}

func knownRouteProfile(v edgev1.EdgeRecordRouteProfile) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch v {
	case edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1,
		edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1:
		return true
	default:
		return false
	}
}

func knownTrafficClass(v edgev1.EdgeRecordTrafficClass) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch v {
	case edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE:
		return true
	default:
		return false
	}
}

func knownSourceAuthKind(v edgev1.EdgeSourceAuthorizationKind) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch v {
	case edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL:
		return true
	default:
		return false
	}
}
