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
	"errors"
	"reflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// isNilTrust reports whether a CapabilityTrust is unusable -- either a nil interface
// OR a non-nil interface value that boxes a nil pointer (or other nil-able kind): a
// "typed nil". A plain `trust == nil` catches only the first case, so a `var t *T = nil`
// stored in the interface would slip past and panic inside ResolveKey. Every
// authorization entry gates on this instead of a bare nil comparison.
func isNilTrust(trust CapabilityTrust) bool {
	if trust == nil {
		return true
	}
	rv := reflect.ValueOf(trust)
	//nolint:exhaustive // only the nil-able kinds can be a typed nil; every other kind is a
	// non-nil concrete value, so the default arm correctly reports it as usable.
	switch rv.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return rv.IsNil()
	default:
		return false
	}
}

// CapabilitySigningDomain is the frozen protocol-domain tag prefixed into every
// capability signing preimage. Domain separation means a signature the same
// issuer key produced for a different framed protocol can never be replayed as an
// edge capability even if the remaining bytes were made to collide.
const CapabilitySigningDomain = "serviceradar.edge.capability.v1"

// knownAlgorithms is the closed, IMMUTABLE set of accepted signature algorithms.
// It is unexported so an importing package cannot widen what ValidateCapability
// accepts at runtime.
//
//nolint:gochecknoglobals // immutable closed accept-set
var knownAlgorithms = map[string]struct{}{
	"ed25519": {},
}

// knownCapabilityVersions is the closed set of accepted capability versions.
//
//nolint:gochecknoglobals // immutable closed accept-set
var knownCapabilityVersions = map[uint32]struct{}{
	1: {},
}

// IsKnownCapabilityAlgorithm reports whether an algorithm is accepted. It is a
// read-only accessor; the underlying set cannot be mutated by callers.
func IsKnownCapabilityAlgorithm(alg string) bool {
	_, ok := knownAlgorithms[alg]
	return ok
}

var (
	ErrCapabilityMissing   = errors.New("edgerecord: required signed capability missing")
	ErrCapabilityVersion   = errors.New("edgerecord: capability version unknown")
	ErrCapabilityIssuer    = errors.New("edgerecord: capability issuer/key id missing")
	ErrCapabilityAlgorithm = errors.New("edgerecord: capability algorithm unknown")
	ErrCapabilityWindow    = errors.New("edgerecord: capability validity window invalid")
	ErrCapabilitySignature = errors.New("edgerecord: capability signature missing")
	ErrCapabilityPurpose   = errors.New("edgerecord: capability purpose does not match its position")
	ErrCapabilityClaims    = errors.New("edgerecord: capability claims missing/invalid")
)

// CapabilityPurpose returns the role a capability fills, derived from which typed
// claims variant is set.
func CapabilityPurpose(c *edgev1.EdgeSignedCapabilityV1) edgev1.EdgeCapabilityPurpose {
	switch c.GetClaims().(type) {
	case *edgev1.EdgeSignedCapabilityV1_Production:
		return edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION
	case *edgev1.EdgeSignedCapabilityV1_Source:
		return edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE
	case *edgev1.EdgeSignedCapabilityV1_Delivery:
		return edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY
	case *edgev1.EdgeSignedCapabilityV1_Collection:
		return edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION
	case *edgev1.EdgeSignedCapabilityV1_AssignmentExecution:
		return edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION
	default:
		return edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_UNSPECIFIED
	}
}

// CapabilitySigningBytes returns the signing preimage a capability's signature
// covers: domain || version || issuer_id || issuer_key_id || algorithm || purpose
// || not_before || expires || claims. The claims are framed by claimsFramed -- a
// u64 oneof discriminant (the set member's proto field number) followed by that
// claim message framed FIELD-BY-FIELD -- NOT a proto.Marshal, so the preimage is
// byte-identical across protobuf-go and protobuf-elixir. The frozen domain tag
// (CapabilitySigningDomain) provides protocol separation and the purpose (role) is
// bound in, so a production grant's signature cannot verify in a source or delivery
// position nor be replayed from another protocol. Go and Elixir agree on this
// framing (see ServiceRadar.Edge.CapabilitySigning + ClaimsFraming).
func CapabilitySigningBytes(c *edgev1.EdgeSignedCapabilityV1) []byte {
	d := newDigest()
	d.str(CapabilitySigningDomain)
	d.u64(uint64(c.GetCapabilityVersion()))
	d.bytes(c.GetIssuerId())
	d.bytes(c.GetIssuerKeyId())
	d.str(c.GetAlgorithm())
	d.u64(uint64(CapabilityPurpose(c)))
	d.i64(c.GetNotBeforeUnixNano())
	d.i64(c.GetExpiresAtUnixNano())
	d.claimsFramed(c)
	return d.buf
}

// ValidateCapability fail-closes a signed capability's structure and role: a
// known version, present issuer + key id, a known algorithm, a forward validity
// window, a typed claims variant that equals expectedPurpose, and a non-empty
// signature. Cryptographic signature verification against the resolved issuer
// key is layered separately; this establishes everything the signature must have
// covered.
func ValidateCapability(c *edgev1.EdgeSignedCapabilityV1, expectedPurpose edgev1.EdgeCapabilityPurpose) error {
	if c == nil {
		return ErrCapabilityMissing
	}
	// Retained unknown fields on the capability or its nested claims are outside the
	// field-framed signature, so a later reader could reinterpret a signed claim;
	// reject them recursively before trusting any field.
	if hasUnknownFields(c) {
		return ErrUnknownFields
	}
	if _, ok := knownCapabilityVersions[c.GetCapabilityVersion()]; !ok {
		return ErrCapabilityVersion
	}
	if len(c.GetIssuerId()) == 0 || len(c.GetIssuerKeyId()) == 0 {
		return ErrCapabilityIssuer
	}
	if _, ok := knownAlgorithms[c.GetAlgorithm()]; !ok {
		return ErrCapabilityAlgorithm
	}
	if c.GetExpiresAtUnixNano() <= c.GetNotBeforeUnixNano() {
		return ErrCapabilityWindow
	}
	if CapabilityPurpose(c) == edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_UNSPECIFIED {
		return ErrCapabilityClaims
	}
	if CapabilityPurpose(c) != expectedPurpose {
		return ErrCapabilityPurpose
	}
	if len(c.GetSignature()) == 0 {
		return ErrCapabilitySignature
	}
	return nil
}

// ErrCapabilitySignatureInvalid is returned when a capability's signature does
// not verify against the resolved issuer public key.
var ErrCapabilitySignatureInvalid = errors.New("edgerecord: capability signature does not verify")

// SignCapability sets c.signature to the Ed25519 signature over
// CapabilitySigningBytes(c). The caller supplies the private key resolved for
// c.issuer_key_id. It is the deterministic signer used by the cross-language
// fixtures and the reference issuer.
func SignCapability(c *edgev1.EdgeSignedCapabilityV1, priv ed25519.PrivateKey) {
	c.Signature = ed25519.Sign(priv, CapabilitySigningBytes(c))
}

// KeyStatus is the lifecycle classification a trust resolver returns for an (issuer, key) pair at a
// given evidence interval. It maps to the normative four-value historical-collection-proof result
// (valid / invalid / historically_revoked / unavailable). Collapsing these is unsafe -- and the
// distinctions are NOT the intuitive ones: NORMAL key expiry/rotation stays VALID (retained key
// history still validates records signed in the key's window), COMPROMISE revocation is
// historically_revoked (REACHABLE as ledger_only/audit + security quarantine, never a silent
// authoritative apply AND never a permanent reject), an unknown/unauthorized key is INVALID (permanent
// reject), and an unresolvable lookup is UNAVAILABLE (retryable). The ZERO value is KeyUnavailable, so
// a resolver that forgets to answer -- or a zero-value KeyResolution -- NEVER authorizes.
type KeyStatus uint8

const (
	// KeyUnavailable -- the resolver could not answer (lookup down/timeout). RETRYABLE
	// (retryable_rejection): leave the record unresolved, never authorize or permanently reject.
	KeyUnavailable KeyStatus = iota
	// KeyValid -- the capability was validly signed by a trusted key over the evidence interval,
	// INCLUDING a key normally expired or rotated out of active issuance: retained key history still
	// validates records signed within the key's window. Eligible for authoritative_apply.
	KeyValid
	// KeyHistoricallyRevoked -- the signing key was COMPROMISE-revoked. The signature verifies (it was
	// valid at signing), but trust is DELIBERATELY invalidated: the record is REACHABLE as
	// ledger_only/audit publication + security quarantine, NEVER silently authoritative_apply and NEVER
	// a permanent reject.
	KeyHistoricallyRevoked
	// KeyInvalid -- unknown / never-issued / not validly signed by any trusted key (unauthorized).
	// PERMANENT rejection.
	KeyInvalid
)

// KeyResolution is the typed result of CapabilityTrust.ResolveKey. Public is the Ed25519 verifying
// key, set for KeyValid and KeyHistoricallyRevoked (both must verify the historical signature) and
// nil otherwise. TrustPolicyEpoch MUST ECHO the requested KeyEvidence.TrustPolicyEpoch -- it binds the
// RESPONSE to the request snapshot, so a stale or cross-snapshot resolver reply (a revocation race) is
// detected and rejected rather than trusted. A zero or mismatched echo is treated as UNAVAILABLE.
//
// Purpose MUST ECHO the requested KeyEvidence.Purpose. The echo is RESPONSE CORRELATION ONLY --
// it proves the answer belongs to the question that was asked, exactly as the epoch echo does,
// and an UNSPECIFIED or mismatched echo is UNAVAILABLE. It does NOT and cannot establish that
// the key is authorized for that role: an echoing resolver that ignores roles still returns
// KeyValid, and the committed tests state that plainly.
//
// AUTHORIZING (issuer, key, purpose) is therefore a CONTRACT OBLIGATION on the implementation:
// ResolveKey MUST return KeyInvalid when the named key is not authorized to issue the requested
// role, because only the resolver holds that knowledge. A resolver that skips this check lets
// one role's key validate another -- a scheduler key minting a host execution grant.
type KeyResolution struct {
	Status           KeyStatus
	Public           ed25519.PublicKey
	TrustPolicyEpoch uint64
	Purpose          edgev1.EdgeCapabilityPurpose
}

// KeyEvidence is the interval + trust-policy context ResolveKey needs to judge historical key validity
// rather than only "valid right now". NotBeforeUnixNano/ExpiresUnixNano are the capability's signed
// validity window -- the evidence interval the historical signature covers -- so a resolver can confirm
// the key was validly issued and non-compromised OVER that window (rejecting BACKDATED authority whose
// window predates the key) using retained history.
//
// EvalNowUnixNano is the CURRENT trusted instant, and it decides CURRENT rotation/compromise
// state -- not "was this key trusted back then". A key validly used inside its window and
// compromise-revoked afterwards MUST resolve KeyHistoricallyRevoked when asked at a later
// EvalNowUnixNano, which is what makes a revocation discovered after the fact actionable.
type KeyEvidence struct {
	NotBeforeUnixNano int64
	ExpiresUnixNano   int64
	EvalNowUnixNano   int64
	// Purpose is the ROLE the capability is being resolved for. A key trusted to issue one
	// role must not silently validate another, and only the resolver knows which roles a key
	// is authorized for -- so the request states the role rather than leaving the resolver to
	// guess it from the issuer name.
	Purpose edgev1.EdgeCapabilityPurpose
	// TrustPolicyEpoch pins the single, immutable trust-policy snapshot for the WHOLE authorization
	// decision. Every capability (production, source, delivery) in one frame/record decision resolves at
	// the SAME nonzero epoch, so a mid-decision revocation cannot mix snapshots across the keys of one
	// frame. Zero is INVALID (the caller MUST fail closed before resolving).
	TrustPolicyEpoch uint64
}

// CapabilityTrust resolves an issuer's verifying key for a capability and applies
// deployment key-rotation / revocation / fence policy. Implementations resolve
// the EXACT (issuer_id, issuer_key_id) pair (rotation) and return a TYPED
// KeyResolution. It is injected so the crypto boundary is explicit and testable,
// and never hardcoded in this package.
type CapabilityTrust interface {
	// ResolveKey returns the typed lifecycle resolution of (issuerID, issuerKeyID, evidence.Purpose)
	// over the evidence interval.
	//
	// It MUST authorize the ROLE: a key that exists but is not authorized to issue
	// evidence.Purpose MUST resolve KeyInvalid. The verifier cannot check this -- only the
	// resolver knows which roles a key may issue -- and the purpose echo proves only that this
	// response answers this request.
	//
	// It MUST distinguish NORMAL rotation/expiry (KeyValid via retained history) from
	// COMPROMISE revocation (KeyHistoricallyRevoked), from an unknown/unauthorized key (KeyInvalid), and
	// from an unresolvable lookup (KeyUnavailable) -- never collapsing retryable into permanent, nor
	// compromise into a silent valid, nor a normally-rotated key into unknown.
	ResolveKey(issuerID, issuerKeyID []byte, evidence KeyEvidence) KeyResolution
}

// capabilityEvidence builds the KeyEvidence for a capability: its signed validity window is the
// evidence interval, evaluated at evalNow under the pinned trust-policy epoch.
func capabilityEvidence(
	c *edgev1.EdgeSignedCapabilityV1,
	purpose edgev1.EdgeCapabilityPurpose,
	evalNow int64,
	trustEpoch uint64,
) KeyEvidence {
	return KeyEvidence{
		NotBeforeUnixNano: c.GetNotBeforeUnixNano(),
		ExpiresUnixNano:   c.GetExpiresAtUnixNano(),
		EvalNowUnixNano:   evalNow,
		TrustPolicyEpoch:  trustEpoch,
		Purpose:           purpose,
	}
}

// worseKeyStatus returns the more-restrictive of two SUCCESSFULLY-VERIFIED key statuses (KeyValid or
// KeyHistoricallyRevoked). KeyHistoricallyRevoked (compromise -> ledger_only/audit) dominates KeyValid,
// so a compromised SOURCE capability downgrades the whole record to audit even when production is valid.
func worseKeyStatus(a, b KeyStatus) KeyStatus {
	if a == KeyHistoricallyRevoked || b == KeyHistoricallyRevoked {
		return KeyHistoricallyRevoked
	}
	return KeyValid
}

// ErrCapabilityKeyUnresolved is returned when the trust context resolves a
// capability's (issuer_id, issuer_key_id) to an INVALID key: unknown / never
// issued / not validly signed by any trusted key. This is a PERMANENT rejection.
var ErrCapabilityKeyUnresolved = errors.New("edgerecord: capability issuer key unresolved/unauthorized")

// ErrKeyUnavailable is returned when the trust context cannot currently resolve a
// capability's key (lookup unavailable). It is RETRYABLE: the caller MUST leave the
// record unresolved (not-ready), never authorize or permanently reject.
var ErrKeyUnavailable = errors.New("edgerecord: capability issuer key temporarily unavailable (retryable)")

// ErrKeyHistoricallyRevoked is returned when a capability's signing key was
// COMPROMISE-revoked. The record is REACHABLE as ledger_only/audit + security
// quarantine: it can never authoritative_apply, but it is NOT a permanent reject.
var ErrKeyHistoricallyRevoked = errors.New("edgerecord: capability issuer key compromise-revoked (ledger_only/audit, reachable)")

// ErrTrustMissing is returned when no trust/policy resolver is configured.
var ErrTrustMissing = errors.New("edgerecord: authorization trust/policy not configured")

// VerifyCapabilityWithTrust resolves the issuer key via trust over the capability's evidence interval
// (evaluated at evalNowUnixNano) and verifies the capability's signature for the expected purpose. It
// returns the resolved KeyStatus so the caller can distinguish a fresh authority (KeyValid, incl. a
// normally-rotated key valid via retained history) from compromise-revoked historical evidence
// (KeyHistoricallyRevoked, reachable as ledger_only/audit); a nil error means the signature verified
// under a KeyValid OR KeyHistoricallyRevoked key. A KeyUnavailable resolution returns ErrKeyUnavailable
// (RETRYABLE) and a KeyInvalid resolution returns ErrCapabilityKeyUnresolved (PERMANENT) -- never merged.
func VerifyCapabilityWithTrust(c *edgev1.EdgeSignedCapabilityV1, expectedPurpose edgev1.EdgeCapabilityPurpose, trust CapabilityTrust, evalNowUnixNano int64, trustEpoch uint64) (KeyStatus, error) {
	// Fail closed on a missing/typed-nil resolver rather than panicking at the
	// authorization boundary. isNilTrust also catches a nil pointer boxed in the
	// interface, which a bare `trust == nil` would let reach ResolveKey.
	if isNilTrust(trust) {
		return KeyUnavailable, ErrTrustMissing
	}
	// A ZERO requested trust-policy epoch is a CONFIGURATION error, not a transient one: fail closed
	// with ErrTrustEpochUnset BEFORE reaching the resolver, so it is never converted into a retryable
	// ErrKeyUnavailable (which would mask an unpinned policy as a transient lookup failure).
	if trustEpoch == 0 {
		return KeyUnavailable, ErrTrustEpochUnset
	}
	// An IMMUTABLE SNAPSHOT. The resolver below is someone else's code, and a protobuf bytes
	// field aliases its backing storage -- so passing the caller's message meant a resolver
	// could rewrite issuer_id / issuer_key_id AFTER any digest that pinned them and BEFORE
	// the signature was computed over them. An artifact pinned as one issuer then verified
	// as another. Everything from here on reads the snapshot, and the resolver receives
	// COPIES of the identifiers it is asked about.
	snap, ok := proto.Clone(c).(*edgev1.EdgeSignedCapabilityV1)
	if !ok {
		return KeyUnavailable, ErrCapabilityMissing
	}
	if err := ValidateCapability(snap, expectedPurpose); err != nil {
		return KeyUnavailable, err
	}
	res := trust.ResolveKey(
		cloneBytes(snap.GetIssuerId()), cloneBytes(snap.GetIssuerKeyId()),
		capabilityEvidence(snap, expectedPurpose, evalNowUnixNano, trustEpoch),
	)
	// Response-bind the resolution to the request snapshot: the resolver MUST echo the requested
	// trust-policy epoch. A ZERO echo (unset) or a MISMATCH (a stale/cross-snapshot reply from a
	// revocation race) is not authoritative -- treat it as UNAVAILABLE (retryable), never authorize.
	if res.TrustPolicyEpoch == 0 || res.TrustPolicyEpoch != trustEpoch {
		return KeyUnavailable, ErrKeyUnavailable
	}
	// PURPOSE is response-bound exactly as the epoch is. A resolver that does not echo the
	// requested role has not answered the question that was asked, so its verdict cannot be
	// spent on this role.
	if res.Purpose != expectedPurpose {
		return KeyUnavailable, ErrKeyUnavailable
	}
	switch res.Status {
	case KeyValid, KeyHistoricallyRevoked:
		if err := VerifyCapabilitySignature(snap, expectedPurpose, res.Public); err != nil {
			return res.Status, err
		}
		return res.Status, nil
	case KeyUnavailable:
		return KeyUnavailable, ErrKeyUnavailable
	case KeyInvalid:
		return KeyInvalid, ErrCapabilityKeyUnresolved
	}
	// Unknown status value: fail closed as unavailable (retryable), never authorize.
	return KeyUnavailable, ErrKeyUnavailable
}

// VerifyCapabilitySignature fail-closes cryptographic verification: it runs the
// structural ValidateCapability, requires the ed25519 algorithm, and verifies
// c.signature over CapabilitySigningBytes(c) with the resolved issuer public key.
// pub is the key selected by c.issuer_key_id (rotation), resolved out of band.
func VerifyCapabilitySignature(c *edgev1.EdgeSignedCapabilityV1, expectedPurpose edgev1.EdgeCapabilityPurpose, pub ed25519.PublicKey) error {
	if err := ValidateCapability(c, expectedPurpose); err != nil {
		return err
	}
	if c.GetAlgorithm() != "ed25519" {
		return ErrCapabilityAlgorithm
	}
	if len(pub) != ed25519.PublicKeySize || len(c.GetSignature()) != ed25519.SignatureSize {
		return ErrCapabilitySignatureInvalid
	}
	if !ed25519.Verify(pub, CapabilitySigningBytes(c), c.GetSignature()) {
		return ErrCapabilitySignatureInvalid
	}
	return nil
}
