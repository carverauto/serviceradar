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
	"errors"
	"fmt"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Production-time late admission (openspec add-edge-production-time-admission).
//
// Live admission (ValidateRecordSigned) asks whether a record's authority is
// current NOW, which is right for new work. A record that was already captured
// under authority valid WHEN IT WAS PRODUCED, and that outlived it before it was
// admitted to a lane (an upgrade left it in an older layout, or its grant lapsed
// in a producer queue), has no admissible path under that rule. Late admission
// asks the second question instead, from evidence the record already carries:
//
//   - produced_at is the UUIDv7 time of event_id, which ValidateRecord already
//     binds inside the signed production window (and any source collection
//     window), so a record cannot claim a time core never signed for;
//   - the production and source signatures verify against retained key history
//     at the pinned trust epoch, evaluated with the capability's own signed
//     window as evidence;
//   - the fence epoch the record names is NOT judged here. Only core holds the
//     authority history that says whether that epoch was live at produced_at; the
//     late grant carries core's decision (Decision 3, checks 6-9).
//
// Late admission never re-signs, re-wraps or widens a record, and never feeds the
// live lane: a late record lives in a late generation, delivered on a LATE session.

// RejectionLateAdmissionRequired is the rejection code of the resolving live
// disposition a gateway sends, only on a lane whose lane_open advertised
// late_admission_protocol_version >= 1, for a record whose fence is stale or
// missing. The agent appends the exact bytes to its late generation (or a
// foreign-origin hold) BEFORE it persists that resolution, and never copies the
// record into the evicting local rejection quarantine: it has been relocated.
const RejectionLateAdmissionRequired = "LATE_ADMISSION_REQUIRED"

// LateAdmissionProtocolVersion is the late-admission protocol this code implements.
const LateAdmissionProtocolVersion uint32 = 1

// LateOutcome classifies a record that ValidateRecordProduced admitted. The zero
// value is not an admission.
type LateOutcome uint8

const (
	// LateOutcomeUnspecified is the zero value: not admitted.
	LateOutcomeUnspecified LateOutcome = iota
	// LateAdmissible -- every signature resolved VALID; core decides PRIMARY or AUDIT.
	LateAdmissible
	// LateAdmissibleSecurity -- a production or source key is COMPROMISE-revoked. The
	// record still leaves the edge (it must never strand), but only to security
	// quarantine: it can never be projected, whatever grant it later meets.
	LateAdmissibleSecurity
)

var (
	// ErrLateNotAdmissible refuses a record that has no production-time meaning: a
	// recovery-control record is bound to one live recovery operation, never late data.
	ErrLateNotAdmissible = errors.New("edgerecord: record kind is never admissible late")
	// ErrLateAdmissionGrantRequired is RETRYABLE: a LATE-session frame whose keys are
	// valid needs core's production-time decision (a late-admission grant) before it
	// can publish. It is withheld, never rejected, for want of one.
	ErrLateAdmissionGrantRequired = errors.New("edgerecord: late session frame requires a current late-admission grant")
	// ErrLateAdmissionGrantMismatch rejects a late-admission grant whose decision does
	// not name this record's production time and fence epoch, or one presented where
	// a renewal/rollover belongs (a LIVE session).
	ErrLateAdmissionGrantMismatch = errors.New("edgerecord: late-admission grant does not bind this record's production authority")
)

// ProducedAtUnixNano is the production time a record asserts: the UUIDv7 time of
// its event_id. ValidateRecord binds it inside the signed production window.
func ProducedAtUnixNano(r *edgev1.EdgeRecordV1) (int64, error) {
	ns, err := UUIDv7Nanos(r.GetEventId())
	if err != nil {
		return 0, ErrIdentityTime
	}
	return ns, nil
}

// ValidateRecordProduced is the agent-side production-time admission rule
// (design Decision 3, agent checks). It returns LateAdmissible or
// LateAdmissibleSecurity with a nil error, or an error:
//
//   - RETRYABLE, and the only refusals that stop an ordered legacy handoff: no
//     trust snapshot (ErrTrustMissing / ErrTrustEpochUnset) and an UNAVAILABLE key
//     lookup (ErrKeyUnavailable). Both clear when connectivity returns.
//   - PERMANENT: a structural or typed-body failure, or an INVALID key
//     (ErrCapabilityKeyUnresolved / ErrCapabilitySignatureInvalid). Only these
//     become rejection evidence.
//
// Everything else is core's to judge with its own clock and authority history, so
// none of it blocks the edge: production authority need not be current now, the
// fence may be current, stale, absent or ahead of what this agent knows, and
// produced_at may be ahead of the local clock. The maximum late age is core's
// bound as well. A compromise-revoked key is admitted as LateAdmissibleSecurity:
// it must still leave the edge, but only ever to security quarantine.
func ValidateRecordProduced(r *edgev1.EdgeRecordV1, policy AuthorizationPolicy) (LateOutcome, error) {
	if isNilTrust(policy.Trust) {
		return LateOutcomeUnspecified, ErrTrustMissing
	}
	if policy.TrustPolicyEpoch == 0 {
		return LateOutcomeUnspecified, ErrTrustEpochUnset
	}
	if err := policy.validateClockTolerance(); err != nil {
		return LateOutcomeUnspecified, err
	}
	if err := ValidateRecord(r); err != nil {
		return LateOutcomeUnspecified, err
	}
	worst, err := verifyRecordKeys(r, policy)
	if err != nil {
		return LateOutcomeUnspecified, err
	}
	if worst == KeyHistoricallyRevoked {
		return LateAdmissibleSecurity, nil
	}
	return LateAdmissible, nil
}

// verifyRecordKeys verifies the production and any source signature under the
// pinned trust epoch and returns the worst verified status. INVALID and
// UNAVAILABLE are errors (permanent and retryable respectively).
func verifyRecordKeys(r *edgev1.EdgeRecordV1, policy AuthorizationPolicy) (KeyStatus, error) {
	worst, err := VerifyCapabilityWithTrust(r.GetProductionCapability(),
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
	if err != nil {
		return KeyUnavailable, fmt.Errorf("production_capability: %w", err)
	}
	if sa := r.GetSourceAuthorization(); sa != nil {
		srcStatus, srcErr := VerifyCapabilityWithTrust(sa.GetCapability(),
			edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
		if srcErr != nil {
			return KeyUnavailable, fmt.Errorf("source_authorization: %w", srcErr)
		}
		worst = worseKeyStatus(worst, srcStatus)
	}
	return worst, nil
}

// RecordLateAttribution is the late-admission peer of RecordRecoveryAttribution: the
// same registered typed body validators and the same attribution, under the
// production-time rule instead of the current-time rule. A recovery-control record
// is never late (ErrLateNotAdmissible).
func RecordLateAttribution(raw []byte, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) (ValidatedAttribution, LateOutcome, error) {
	r, err := DecodeRecord(raw)
	if err != nil {
		return ValidatedAttribution{}, LateOutcomeUnspecified, err
	}
	if err = dispatchContract(r, expected); err != nil {
		return ValidatedAttribution{}, LateOutcomeUnspecified, err
	}
	if r.GetOutputContract().GetContractVersion() != 1 {
		return ValidatedAttribution{}, LateOutcomeUnspecified, ErrContractDispatch
	}
	var (
		active   bool
		rangeSHA []byte
	)
	switch id := r.GetOutputContract().GetContractId(); id {
	case "serviceradar.edge.recovery_control":
		return ValidatedAttribution{}, LateOutcomeUnspecified, ErrLateNotAdmissible
	case SweepObservationContractID:
		batch, bodyErr := validateSweepBody(r, expected)
		if bodyErr != nil {
			return ValidatedAttribution{}, LateOutcomeUnspecified, bodyErr
		}
		active, rangeSHA = true, batch.GetTargetRangeSha256()
	default:
		validate := standingAttributionValidator(id)
		if validate == nil {
			return ValidatedAttribution{}, LateOutcomeUnspecified, ErrContractDispatch
		}
		if err = validate(r); err != nil {
			return ValidatedAttribution{}, LateOutcomeUnspecified, err
		}
	}
	outcome, err := ValidateRecordProduced(r, policy)
	if err != nil {
		return ValidatedAttribution{}, LateOutcomeUnspecified, err
	}
	validated, err := validatedRecoveryAttribution(raw, r, active, rangeSHA)
	if err != nil {
		return ValidatedAttribution{}, LateOutcomeUnspecified, err
	}
	return validated, outcome, nil
}

// ValidateLateFrameSigned is the gateway decision for a frame on a LATE session (Go
// oracle of the gateway's late path). It always verifies the enclosed record and
// its signatures. A compromise-revoked key, a foreign origin principal, or a
// terminal authority interval publishes to SECURITY QUARANTINE with no grant.
// Otherwise the frame needs a current late-admission grant whose decision
// names this record's production time and fence epoch; the publication is the
// grant's (PRIMARY or AUDIT), never the current fence's. A frame without one is
// withheld (ErrLateAdmissionGrantRequired), and a renewal or rollover grant is
// refused here.
func ValidateLateFrameSigned(f *edgev1.EdgeDeliveryFrameV1, authenticatedPrincipal []byte, policy AuthorizationPolicy) (FrameDecision, error) {
	if isNilTrust(policy.Trust) {
		return FrameDecision{}, ErrTrustMissing
	}
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
	worst, err := verifyRecordKeys(record, policy)
	if err != nil {
		return FrameDecision{}, err
	}
	// The three security-quarantine classes come first, before any grant is
	// considered: a compromise-revoked key, a record whose origin is not the
	// authenticated presenter (a revoked or superseded predecessor's bytes), and a
	// record naming a terminal (certificate_revoked / revoked_cause_unknown)
	// authority interval -- even when an already-issued grant is attached.
	foreign := !bytes.Equal(record.GetProducerContext().GetOriginPrincipalId(), authenticatedPrincipal)
	if worst == KeyHistoricallyRevoked || foreign || policy.TerminalAuthority {
		return FrameDecision{
			Publication:     FramePublicationSecurityQuarantine,
			DeliveryMode:    FrameDeliveryModeLateAdmission,
			GrantTransition: FrameGrantNone,
		}, nil
	}
	dc := f.GetDeliveryCapability()
	if dc == nil {
		return FrameDecision{}, ErrLateAdmissionGrantRequired
	}
	late, err := verifyLateAdmissionGrant(dc, record, policy)
	if err != nil {
		return FrameDecision{}, err
	}
	publication := FramePublicationPrimary
	if late.GetPublication() == edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_AUDIT {
		publication = FramePublicationAudit
	}
	return FrameDecision{Publication: publication, DeliveryMode: FrameDeliveryModeLateAdmission, GrantTransition: FrameGrantLateAdmission}, nil
}

// verifyLateAdmissionGrant verifies a delivery capability carrying a late-admission
// decision: a currently VALID delivery key, a current window, well-formed claims,
// and a decision that names exactly this record's production time and fence epoch.
func verifyLateAdmissionGrant(dc *edgev1.EdgeSignedCapabilityV1, record *edgev1.EdgeRecordV1, policy AuthorizationPolicy) (*edgev1.EdgeDeliveryLateAdmissionV1, error) {
	status, err := VerifyCapabilityWithTrust(dc,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY, policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
	if err != nil {
		return nil, fmt.Errorf("delivery_capability: %w", err)
	}
	if status != KeyValid {
		return nil, fmt.Errorf("delivery_capability: %w", ErrKeyHistoricallyRevoked)
	}
	claims := dc.GetDelivery()
	if err := validateDeliveryClaims(claims); err != nil {
		return nil, fmt.Errorf("delivery_capability: %w", err)
	}
	if !policy.currentAt(dc.GetNotBeforeUnixNano(), dc.GetExpiresAtUnixNano()) {
		return nil, fmt.Errorf("delivery_capability: %w", ErrAuthorityExpired)
	}
	late := claims.GetLateAdmission()
	if late == nil {
		return nil, fmt.Errorf("delivery_capability: %w: late session requires a late-admission transition", ErrLateAdmissionGrantMismatch)
	}
	producedAt, err := ProducedAtUnixNano(record)
	if err != nil {
		return nil, err
	}
	if late.GetProducedAtUnixNano() != producedAt ||
		late.GetAuthorityEpoch() != record.GetProducerContext().GetAuthorityEpoch() {
		return nil, fmt.Errorf("delivery_capability: %w", ErrLateAdmissionGrantMismatch)
	}
	return late, nil
}

// knownLatePublication and knownLateDecisionReason are the closed sets a
// late-admission decision may carry.
func knownLatePublication(p edgev1.EdgeLatePublication) bool {
	return p == edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY || p == edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_AUDIT
}

func knownLateDecisionReason(r edgev1.EdgeLateDecisionReason) bool {
	switch r {
	case edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED,
		edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION,
		edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN,
		edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_COMPROMISE_ENDED,
		edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_BEYOND_LATE_WINDOW,
		edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_CONTRACT_RETIRED,
		edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_LEDGER_PRUNED:
		return true
	case edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_UNSPECIFIED:
		return false
	default:
		return false
	}
}

// validateLateAdmissionClaims checks a late-admission transition's own shape: a
// positive production time, a decided publication, and a reason consistent with it
// (ADMITTED pairs only with PRIMARY; every other reason only with AUDIT).
func validateLateAdmissionClaims(late *edgev1.EdgeDeliveryLateAdmissionV1) error {
	if late.GetProducedAtUnixNano() <= 0 {
		return fmt.Errorf("%w: late_admission produced_at", ErrDeliveryClaims)
	}
	if !knownLatePublication(late.GetPublication()) || !knownLateDecisionReason(late.GetReason()) {
		return fmt.Errorf("%w: late_admission publication/reason", ErrDeliveryClaims)
	}
	switch late.GetPublication() {
	case edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY:
		if late.GetReason() != edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED {
			return fmt.Errorf("%w: late_admission PRIMARY requires reason ADMITTED", ErrDeliveryClaims)
		}
	case edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_AUDIT:
		switch late.GetReason() {
		case edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION,
			edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN,
			edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_COMPROMISE_ENDED,
			edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_BEYOND_LATE_WINDOW,
			edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_CONTRACT_RETIRED,
			edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_LEDGER_PRUNED:
		case edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_UNSPECIFIED,
			edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED:
			return fmt.Errorf("%w: late_admission AUDIT requires an audit reason", ErrDeliveryClaims)
		default:
			return fmt.Errorf("%w: late_admission AUDIT requires an audit reason", ErrDeliveryClaims)
		}
	case edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_UNSPECIFIED:
		return fmt.Errorf("%w: late_admission publication", ErrDeliveryClaims)
	default:
		return fmt.Errorf("%w: late_admission publication", ErrDeliveryClaims)
	}
	return nil
}
