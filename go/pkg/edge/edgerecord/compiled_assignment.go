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
	"reflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// CompiledAssignmentDigestVersion is the frozen canonical digest grammar for
// CompiledSweepAssignmentV1.
const CompiledAssignmentDigestVersion = 1

// compiledAssignmentBodyDomain is the leading string domain tag for the SIGNED BODY
// digest, so it can never equal a plan, range or recovery digest by field-structure
// coincidence.
const compiledAssignmentBodyDomain = "serviceradar.edge.assignment.compiled.body.v1"

// compiledAssignmentArtifactDomain tags the ARTIFACT digest. It is a SEPARATE domain
// from the body: the two digests cover different things and must never be
// interchangeable, or a body digest could be presented where a content address is
// required.
const compiledAssignmentArtifactDomain = "serviceradar.edge.assignment.compiled.artifact.v1"

// MaxCompiledAssignmentBytes is the hard ceiling on ONE encoded
// CompiledSweepAssignmentV1, enforced on the EXACT RECEIVED BYTES before decoding.
//
// A decoded-struct check cannot serve as this bound: protobuf permits repeating a
// known non-repeated field, and the decoder keeps only the last occurrence, so an
// arbitrarily large encoding collapses to a small struct. The carrier is reachable as
// a standalone artifact (it is fetched by digest, not only read inline), so it needs
// its own received-byte ceiling rather than inheriting a containing record's.
const MaxCompiledAssignmentBytes = 64 * 1024

// MaxExecutionGrantBytes bounds ONE encoded EdgeSignedCapabilityV1 carrying an
// ASSIGNMENT_EXECUTION grant on RECEIVED BYTES. The grant travels standalone, so it needs
// its own ceiling; a grant read out of a containing message inherits that message's bound,
// but this one does not arrive that way.
const MaxExecutionGrantBytes = 16 * 1024

var (
	ErrCompiledAssignment           = errors.New("edgerecord: compiled sweep assignment invalid")
	ErrCompiledAssignmentDigest     = errors.New("edgerecord: compiled sweep assignment digest mismatch")
	ErrCompiledAssignmentCapability = errors.New("edgerecord: compiled sweep assignment capability invalid")
	// ErrCompiledAssignmentBinding fires when a carrier and the assignment record that
	// references it are each internally valid but describe different work.
	ErrCompiledAssignmentBinding = errors.New("edgerecord: compiled assignment does not match the assignment record")
	// ErrExecutionGrantTooLarge is a PERMANENT rejection for an oversize standalone grant.
	ErrExecutionGrantTooLarge = errors.New("edgerecord: encoded assignment execution grant exceeds 16 KiB bound")
	// ErrCompiledAssignmentTooLarge is a PERMANENT rejection: an oversize carrier is
	// unbounded input, not a transient condition.
	ErrCompiledAssignmentTooLarge = errors.New("edgerecord: encoded compiled assignment exceeds 64 KiB bound")
	// ErrCompiledAssignmentLease fires when a carrier's window extends beyond the lease of the
	// assignment that references it.
	ErrCompiledAssignmentLease = errors.New("edgerecord: compiled assignment window exceeds the assignment lease")
	// ErrCollectionNotAuthorized is the CURRENT-EXECUTION answer, deliberately distinct
	// from any signature-verification error: a correctly signed carrier is still not
	// authorization to collect right now.
	ErrCollectionNotAuthorized = errors.New("edgerecord: collection not authorized at the evaluated instant")
	// ErrAssignmentAuthorityUnavailable is RETRYABLE: the authoritative-record lookup could
	// not answer. Distinct from a refusal, because an outage is not a decision.
	ErrAssignmentAuthorityUnavailable = errors.New("edgerecord: authoritative assignment unavailable (retryable)")
	// ErrAssignmentAuthorityUnknown is PERMANENT: no such assignment exists.
	ErrAssignmentAuthorityUnknown = errors.New("edgerecord: authoritative assignment unknown")
	// ErrAssignmentExecutionGrantBinding fires when a HOST's execution grant does not permit
	// exactly the record and carrier presented with it -- a wrong scope, attempt, plan, range,
	// traffic class, window or carrier revision.
	ErrAssignmentExecutionGrantBinding = errors.New("edgerecord: assignment execution grant does not permit this record and carrier")
)

// knownCapabilityPurpose is ENUM ADMISSION only: is this a declared purpose? Which
// purpose a given claims variant REQUIRES is a semantic rule, enforced where that
// variant is validated -- keeping the two separate is what lets the evolution guard
// stay meaningful, since a field policy that admitted exactly one member could never
// notice the enum growing.
func knownCapabilityPurpose(p edgev1.EdgeCapabilityPurpose) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch p {
	case edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION:
		return true
	default:
		return false
	}
}

func knownResultFormat(f edgev1.SweepResultFormat) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch f {
	case edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1:
		return true
	default:
		return false
	}
}

// CompiledAssignmentBodyDigest computes the digest the capability SIGNS: every
// CompiledSweepAssignmentV1 BODY field, excluding both digest fields and the
// capability.
//
// The capability is excluded because it signs this value; a signature cannot cover
// itself. Everything else is covered, which is what lets one signature authenticate
// every compiled fact -- including config generation, result format and check set,
// which no pre-existing claim signed.
func CompiledAssignmentBodyDigest(c *edgev1.CompiledSweepAssignmentV1) []byte {
	d := newDigest()
	d.str(compiledAssignmentBodyDomain)
	d.u64(uint64(c.GetDigestVersion()))
	d.bytes(c.GetCompiledAssignmentId())
	d.bytes(c.GetProducerAssignmentId())
	d.bytes(c.GetExecutionId())
	d.bytes(c.GetExecutionPlanId())
	d.bytes(c.GetExecutionPlanSha256())
	d.bytes(c.GetTargetRangeId())
	d.bytes(c.GetTargetRangeSha256())
	d.bytes(c.GetNetworkScopeId())
	d.bytes(c.GetAuthenticatedAgentId())
	d.u64(uint64(c.GetExecutionShard()))
	d.u64(c.GetAssignmentEpoch())
	d.u64(c.GetConfigGeneration())
	d.u64(uint64(c.GetResultFormat()))
	d.bytes(c.GetCheckSetSha256())
	d.u64(uint64(c.GetTrafficClass()))
	d.i64(c.GetNotBeforeUnixNano())
	d.i64(c.GetExpiresAtUnixNano())
	return d.finish()
}

// CompiledAssignmentArtifactDigest computes the carrier's CONTENT ADDRESS: the body
// digest PLUS the attached authority.
//
// A body digest alone is not a content address for this artifact. Two carriers with
// identical bodies and different capabilities -- a valid one and one signed by a
// revoked or attacker-held key -- share a body digest, so a reference pinning only
// the body would not pin WHICH authority it accepted. The capability is folded in via
// its frozen signing preimage plus its signature, so the address covers the issuer,
// key id, algorithm, window, claims and the signature bytes themselves.
func CompiledAssignmentArtifactDigest(c *edgev1.CompiledSweepAssignmentV1) []byte {
	d := newDigest()
	d.str(compiledAssignmentArtifactDomain)
	d.u64(uint64(c.GetDigestVersion()))
	d.bytes(CompiledAssignmentBodyDigest(c))
	cap := c.GetCollectionCapability()
	// An explicit 1-byte presence marker, the same convention every other grammar in
	// this package uses, so "no capability" cannot collide with some present
	// capability's framing. NOT a u64: a divergent width here would be an exception the
	// Elixir peer has to know about, for no benefit.
	d.present(cap != nil)
	if cap == nil {
		return d.finish()
	}
	d.bytes(CapabilitySigningBytes(cap))
	d.bytes(cap.GetSignature())
	return d.finish()
}

// ValidateCompiledSweepAssignmentBytes enforces MaxCompiledAssignmentBytes on the
// EXACT RECEIVED BYTES, then decodes and validates. This is the authoritative entry
// point for a carrier that arrived as a standalone artifact.
func ValidateCompiledSweepAssignmentBytes(raw []byte) (*edgev1.CompiledSweepAssignmentV1, error) {
	if len(raw) > MaxCompiledAssignmentBytes {
		return nil, ErrCompiledAssignmentTooLarge
	}
	var c edgev1.CompiledSweepAssignmentV1
	if err := proto.Unmarshal(raw, &c); err != nil {
		return nil, ErrCompiledAssignment
	}
	if err := ValidateCompiledSweepAssignment(&c); err != nil {
		return nil, err
	}
	return &c, nil
}

// ValidateCompiledSweepAssignment fail-closes one immutable compiled assignment: its
// identity, every compiled fact's domain, its self-digest, and the scheduler's
// COLLECTION capability over that digest.
func ValidateCompiledSweepAssignment(c *edgev1.CompiledSweepAssignmentV1) error {
	if c == nil {
		return ErrNilRecord
	}
	if hasUnknownFields(c) {
		return ErrUnknownFields
	}
	if ValidateUUIDv7(c.GetCompiledAssignmentId()) != nil {
		return ErrCompiledAssignment
	}
	if c.GetDigestVersion() != CompiledAssignmentDigestVersion {
		return ErrCompiledAssignment
	}
	// The SPECIFIC attempt. Without these the carrier's attestation covers only a
	// (plan, range, shard, epoch) tuple, and a capability issued for one attempt would verify
	// against another sharing that tuple.
	if ValidateCanonicalUUID(c.GetProducerAssignmentId()) != nil ||
		ValidateCanonicalUUID(c.GetExecutionId()) != nil {
		return ErrCompiledAssignment
	}
	if ValidateUUIDv7(c.GetExecutionPlanId()) != nil ||
		ValidateCanonicalUUID(c.GetTargetRangeId()) != nil ||
		ValidateCanonicalUUID(c.GetNetworkScopeId()) != nil ||
		ValidateCanonicalUUID(c.GetAuthenticatedAgentId()) != nil {
		return ErrCompiledAssignment
	}
	if len(c.GetExecutionPlanSha256()) != sha256Len ||
		len(c.GetTargetRangeSha256()) != sha256Len ||
		len(c.GetCheckSetSha256()) != sha256Len {
		return ErrCompiledAssignment
	}
	// config_generation starts at 1: 0 is the proto default, so accepting it would let
	// an unset field pose as the first generation.
	if c.GetConfigGeneration() == 0 {
		return ErrCompiledAssignment
	}
	if !knownResultFormat(c.GetResultFormat()) {
		return ErrCompiledAssignment
	}
	if !knownTrafficClass(c.GetTrafficClass()) {
		return ErrCompiledAssignment
	}
	// A validity window that is empty or inverted constrains nothing.
	if c.GetNotBeforeUnixNano() <= 0 || c.GetExpiresAtUnixNano() <= c.GetNotBeforeUnixNano() {
		return ErrCompiledAssignment
	}
	if len(c.GetCompiledAssignmentBodySha256()) != sha256Len ||
		!bytes.Equal(CompiledAssignmentBodyDigest(c), c.GetCompiledAssignmentBodySha256()) {
		return ErrCompiledAssignmentDigest
	}
	if err := validateCollectionCapability(c); err != nil {
		return err
	}
	// The artifact address is checked LAST because it covers the capability: it is only
	// meaningful once that capability has been validated.
	if len(c.GetCompiledAssignmentSha256()) != sha256Len ||
		!bytes.Equal(CompiledAssignmentArtifactDigest(c), c.GetCompiledAssignmentSha256()) {
		return ErrCompiledAssignmentDigest
	}
	return nil
}

// validateCollectionCapability checks the STRUCTURAL BINDING between the carrier and the
// scheduler ATTESTATION attached to it. It does NOT authenticate anything: no signature is
// verified here, because this layer has no key material. A carrier that passes is well-formed
// and self-consistent, never "attested" -- VerifyCompiledAssignmentWithTrust answers that, and
// AuthorizeCollectionNow answers whether a HOST may proceed.
//
// What IS frozen here is the binding: a capability that verifies but attests different work
// is the failure this exists to catch.
func validateCollectionCapability(c *edgev1.CompiledSweepAssignmentV1) error {
	cap := c.GetCollectionCapability()
	if cap == nil {
		// An unattested carrier is a set of facts nobody stands behind.
		return ErrCompiledAssignmentCapability
	}
	// The OFFICIAL capability validator, not a local re-implementation: version, issuer,
	// algorithm, window, purpose-matches-variant, signature presence and recursive
	// unknown-field rejection are frozen there, and a second copy of those rules here
	// would be free to drift out of agreement with every other capability position.
	if err := ValidateCapability(cap, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION); err != nil {
		return err
	}
	claims := cap.GetCollection()
	if claims == nil {
		// Unreachable while ValidateCapability enforces the purpose, but the nil deref it
		// prevents is worth being explicit about.
		return ErrCompiledAssignmentCapability
	}
	// The enum field must agree with the variant. ValidateCapability derives purpose from
	// the VARIANT; this catches a claims body whose own purpose field says something else.
	if claims.GetPurpose() != edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION {
		return ErrCompiledAssignmentCapability
	}
	if cap.GetNotBeforeUnixNano() <= 0 {
		return ErrCompiledAssignmentCapability
	}
	// The capability MUST cover the carrier's window. A capability that expires first
	// would leave the tail of the window unattested while the carrier still claims it.
	if cap.GetNotBeforeUnixNano() > c.GetNotBeforeUnixNano() ||
		cap.GetExpiresAtUnixNano() < c.GetExpiresAtUnixNano() {
		return ErrCompiledAssignmentCapability
	}
	// The claim binds THIS carrier, by digest, and the same work it describes.
	if !bytes.Equal(claims.GetCompiledAssignmentBodySha256(), c.GetCompiledAssignmentBodySha256()) ||
		!bytes.Equal(claims.GetProducerAssignmentId(), c.GetProducerAssignmentId()) ||
		!bytes.Equal(claims.GetExecutionId(), c.GetExecutionId()) ||
		!bytes.Equal(claims.GetNetworkScopeId(), c.GetNetworkScopeId()) ||
		!bytes.Equal(claims.GetAuthenticatedAgentId(), c.GetAuthenticatedAgentId()) ||
		!bytes.Equal(claims.GetExecutionPlanId(), c.GetExecutionPlanId()) ||
		!bytes.Equal(claims.GetTargetRangeId(), c.GetTargetRangeId()) ||
		claims.GetExecutionShard() != c.GetExecutionShard() ||
		claims.GetAssignmentEpoch() != c.GetAssignmentEpoch() ||
		claims.GetTrafficClass() != c.GetTrafficClass() {
		return ErrCompiledAssignmentCapability
	}
	return nil
}

// ValidateAssignmentAgainstCompiled proves the record/carrier RELATION. Each is
// validated on its own terms first, then every fact they BOTH carry must agree --
// otherwise a valid record could reference a valid carrier that describes a
// different plan, range, scope, agent, shard or epoch.
func ValidateAssignmentAgainstCompiled(
	r *edgev1.SweepAssignmentRecordV1,
	c *edgev1.CompiledSweepAssignmentV1,
) error {
	if err := ValidateSweepAssignmentRecord(r); err != nil {
		return err
	}
	if err := ValidateCompiledSweepAssignment(c); err != nil {
		return err
	}
	// The reference must name THIS carrier: id AND digest. An id alone names a carrier
	// without pinning which revision of it was attested.
	if !bytes.Equal(r.GetCompiledAssignmentId(), c.GetCompiledAssignmentId()) ||
		!bytes.Equal(r.GetCompiledAssignmentSha256(), c.GetCompiledAssignmentSha256()) {
		return ErrCompiledAssignmentBinding
	}
	// ASSIGNMENT IDENTITY. Without this pair the relation binds a (plan, range, shard,
	// epoch) tuple: another record for a different attempt on the same tuple would
	// satisfy it, so the signature would not be authenticating THIS assignment.
	if !bytes.Equal(r.GetProducerAssignmentId(), c.GetProducerAssignmentId()) ||
		!bytes.Equal(r.GetExecutionId(), c.GetExecutionId()) {
		return ErrCompiledAssignmentBinding
	}
	if !bytes.Equal(r.GetExecutionPlanId(), c.GetExecutionPlanId()) ||
		!bytes.Equal(r.GetExecutionPlanSha256(), c.GetExecutionPlanSha256()) ||
		!bytes.Equal(r.GetTargetRangeId(), c.GetTargetRangeId()) ||
		!bytes.Equal(r.GetTargetRangeSha256(), c.GetTargetRangeSha256()) ||
		!bytes.Equal(r.GetNetworkScopeId(), c.GetNetworkScopeId()) ||
		!bytes.Equal(r.GetAuthenticatedAgentId(), c.GetAuthenticatedAgentId()) ||
		r.GetExecutionShard() != c.GetExecutionShard() ||
		r.GetAssignmentEpoch() != c.GetAssignmentEpoch() ||
		!bytes.Equal(r.GetCheckSetSha256(), c.GetCheckSetSha256()) {
		return ErrCompiledAssignmentBinding
	}
	// COLLECTION IS CONSTRAINED TO THE LEASE. The carrier's window and the assignment's
	// lease are otherwise unrelated quantities: a carrier whose window is 100..200 attached
	// to a record whose lease expires at 2 would let an agent keep collecting long after
	// the fence it holds has lapsed. The lease is the shorter-lived, revocable fact, so the
	// carrier's window must not extend past it.
	if c.GetExpiresAtUnixNano() > r.GetLeaseExpiresAtUnixNano() {
		return ErrCompiledAssignmentLease
	}
	return nil
}

// VerifyCompiledAssignmentWithTrust answers the HISTORICAL question: was this carrier's
// collection capability validly issued? It runs structural validation, then Ed25519
// verification against a resolved issuer key with revocation/rotation status from `trust`.
//
// It is NOT an admission path and must not be used as one. It deliberately does not check
// current freshness, current state, the caller, or authoritative record position -- which
// is what makes it usable on an archived record long after collection could occur.
// AuthorizeCollectionNow is the current-authority boundary.
//
// ValidateCompiledSweepAssignment deliberately stops at "a signature is present and
// binds this carrier" -- it cannot verify one, having no key material. Nothing may
// treat that as authentication; this function is what turns a well-formed carrier into
// an authenticated one.
//
// `trustNowUnixNano` is the CURRENT instant at which the key's rotation/compromise state is
// asked about -- NOT the capability's own validity time, and NOT "was this key trusted then". A
// key used validly inside its window and compromise-revoked afterwards resolves
// KeyHistoricallyRevoked when asked at a later instant, which is what makes a revocation
// discovered after the fact actionable. The SIGNED EVIDENCE INTERVAL is separate and comes from
// the capability itself, so it is not a parameter.
//
// A nil error here is NOT permission to collect now -- see AuthorizeCollectionNow.
func VerifyCompiledAssignmentWithTrust(
	c *edgev1.CompiledSweepAssignmentV1,
	trust CapabilityTrust,
	trustNowUnixNano int64,
	trustEpoch uint64,
) (KeyStatus, error) {
	if err := ValidateCompiledSweepAssignment(c); err != nil {
		// KeyUnavailable is the zero value and never yields a valid verification; a structural
		// failure must not surface as a key VERDICT, which KeyInvalid would imply.
		return KeyUnavailable, err
	}
	return VerifyCapabilityWithTrust(
		c.GetCollectionCapability(),
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION,
		trust, trustNowUnixNano, trustEpoch,
	)
}

// AssignmentAuthorityStatus is the typed lifecycle of an authoritative-assignment
// lookup. The ZERO value is UNAVAILABLE, so a resolver that forgets to answer -- or a
// zero-value AuthoritativeAssignment -- NEVER authorizes.
type AssignmentAuthorityStatus uint8

const (
	// AssignmentAuthorityUnavailable -- the lookup could not answer. RETRYABLE.
	AssignmentAuthorityUnavailable AssignmentAuthorityStatus = iota
	// AssignmentAuthorityResolved -- the authoritative record for this key is returned.
	AssignmentAuthorityResolved
	// AssignmentAuthorityUnknown -- no such assignment exists. PERMANENT rejection.
	AssignmentAuthorityUnknown
)

// clone returns a deep copy, so an object handed to a resolver shares no storage with the
// expectation it will be compared against.
func (k AssignmentKey) clone() AssignmentKey {
	return AssignmentKey{
		NetworkScopeID:       cloneBytes(k.NetworkScopeID),
		AuthenticatedAgentID: cloneBytes(k.AuthenticatedAgentID),
		ProducerAssignmentID: cloneBytes(k.ProducerAssignmentID),
	}
}

// AssignmentKey identifies ONE assignment series. It is the FROZEN STRUCTURED TUPLE
// (network_scope_id, authenticated_agent_id, producer_assignment_id), and it is DERIVED
// from the record inside the boundary -- never supplied by a caller.
//
// An opaque caller-chosen namespace was not a key: arbitrary bytes are not checkable, so
// a caller could name any namespace whose authority happened to answer conveniently. The
// tuple's members are the same ones the carrier, capabilities and record all bind, so the
// lookup is scoped by facts that are themselves authenticated elsewhere.
type AssignmentKey struct {
	NetworkScopeID       []byte
	AuthenticatedAgentID []byte
	ProducerAssignmentID []byte
}

// assignmentKeyFor derives the lookup key from the record. Unexported: the whole point is
// that the key is not a caller input.
func assignmentKeyFor(r *edgev1.SweepAssignmentRecordV1) AssignmentKey {
	// Copies rather than the message's own slices. The ENFORCING step is the clone at the
	// resolver handoff (expected.clone()); this is belt-and-braces so a future caller of
	// this helper does not inherit an aliasing key, and is not claimed to be individually
	// load-bearing while that handoff clone is in place.
	return AssignmentKey{
		NetworkScopeID:       cloneBytes(r.GetNetworkScopeId()),
		AuthenticatedAgentID: cloneBytes(r.GetAuthenticatedAgentId()),
		ProducerAssignmentID: cloneBytes(r.GetProducerAssignmentId()),
	}
}

func (k AssignmentKey) equal(o AssignmentKey) bool {
	return bytes.Equal(k.NetworkScopeID, o.NetworkScopeID) &&
		bytes.Equal(k.AuthenticatedAgentID, o.AuthenticatedAgentID) &&
		bytes.Equal(k.ProducerAssignmentID, o.ProducerAssignmentID)
}

// AuthoritativeAssignment is the resolved CURRENT truth for one assignment series.
//
// It carries the COMPLETE authoritative record plus the COMMITTED PLAN it was compiled
// from -- not a projection of selected fields. A projection cannot be a sufficient
// authority: any field it omits is unconstrained, so a presented record differing only in
// availability_policy_id, mtr_expectation, authored_at -- or in a field added later --
// passes. Comparing whole messages is total by construction and stays total as the ABI
// grows.
//
// Key MUST ECHO the requested AssignmentKey, exactly as KeyResolution echoes the trust
// policy epoch: the echo binds the RESPONSE to the REQUEST, so a cross-assignment,
// cross-agent or cross-scope reply is detected rather than trusted.
type AuthoritativeAssignment struct {
	Status AssignmentAuthorityStatus
	Key    AssignmentKey
	// Record is the authoritative record IN FULL.
	Record *edgev1.SweepAssignmentRecordV1
	// PlanHeaderRaw and PlanPagesRaw are the COMMITTED plan. Without them the boundary cannot
	// tell whether the range every other artifact agrees on actually exists in the plan.
	//
	// The pages are RAW BYTES, not decoded messages, because MaxPlanPageBytes is a physical
	// bound that only exists on received bytes: a re-marshal of a decoded page collapses
	// duplicate known fields, so decoded pages cannot establish it. Returning raw bytes lets
	// the boundary run the authoritative raw path itself rather than trusting an unstated
	// guarantee that someone else already did.
	// BOTH are raw bytes. Returning a decoded header beside raw pages split the contract:
	// MaxPlanHeaderBytes is physical, so a decoded header cannot establish it, and Go
	// accepted a 512 KiB + 1 header that Elixir's raw boundary rejected.
	PlanHeaderRaw []byte
	PlanPagesRaw  [][]byte
}

// AssignmentAuthority resolves the authoritative current record for an assignment series.
// Implementations MUST distinguish an unresolvable lookup (retryable) from a genuinely
// unknown assignment (permanent), and MUST echo the requested key.
type AssignmentAuthority interface {
	ResolveAssignment(key AssignmentKey) AuthoritativeAssignment
}

// CallerVerdict is a SessionAuthority's answer about the transport-authenticated peer.
// The ZERO value is UNATTESTED, so a session that cannot answer never authorizes.
type CallerVerdict uint8

const (
	// CallerUnattested -- no authenticated peer identity is available.
	CallerUnattested CallerVerdict = iota
	// CallerMatches -- the authenticated peer IS this (network scope, agent).
	CallerMatches
	// CallerMismatch -- an authenticated peer exists and is someone else.
	CallerMismatch
)

// SessionAuthority answers whether the TRANSPORT-authenticated peer on this session is a
// given agent. It is implemented by the transport that performed the authentication.
//
// It is deliberately a QUESTION rather than a value, because an exported constructor
// taking raw ids let any caller mint a "transport-attested" identity out of the record it
// was already holding. Asking cannot be satisfied by restating the input.
//
// This is TRUSTED DEPENDENCY INJECTION, not type-level unforgeability: Go cannot prevent a
// caller from supplying a lying implementation, exactly as it cannot for CapabilityTrust.
// What the shape buys is that the lie must be an explicit, locatable transport
// implementation rather than a struct field filled in at the call site.
type SessionAuthority interface {
	AuthorizeAgent(networkScopeID, agentID []byte) CallerVerdict
}

// CollectionAuthority is the evaluation context a CURRENT collection decision is made
// against.
//
// Every field is REQUIRED and its zero value refuses: a nil (or typed-nil) Trust,
// Assignments or Session, and an absent ExecutionGrantRaw, are each independently
// disqualifying. There is no optional member -- the conditional part is the source identity
// INSIDE the execution grant's claim, not a second capability the caller may omit.
type CollectionAuthority struct {
	// Trust resolves issuer keys.
	Trust CapabilityTrust
	// Assignments resolves the authoritative record, its committed plan, and the RAW
	// committed page bytes.
	Assignments AssignmentAuthority
	// Session answers who the transport authenticated.
	Session SessionAuthority
	// NowUnixNano is the trusted evaluation instant.
	NowUnixNano int64
	// TrustEpoch is the trust-policy snapshot the resolvers must echo.
	TrustEpoch uint64
	// ExecutionGrantRaw is the HOST's permission to execute this exact carrier, as RAW
	// BYTES: it travels standalone and has a physical ceiling. Validated COMPLETELY.
	ExecutionGrantRaw []byte
}

// AuthorizeCollectionNow is the ONE current-authority boundary: may this caller collect
// for this assignment, right now?
//
// It works on a DEEP-CLONED SNAPSHOT of both inputs. Every authority it consults is an
// interface implemented by someone else, and the byte slices in a protobuf message alias
// its backing storage -- so handing a callback a slice from the validated message let a
// resolver overwrite the very fields whose signatures had just been checked, then return a
// record matching the mutation. Cloning at entry makes the checked bytes unreachable from
// any callback, and every argument handed out is itself a copy.
//
// It answers a strictly NARROWER question than VerifyCompiledAssignmentWithTrust, which
// stays separate: that one asks whether a signature was validly issued, which remains
// answerable FOR AS LONG AS THE ISSUING KEY'S EVIDENCE IS RETAINED -- that is what lets an
// archived record be re-verified, and it is a RETENTION property, not a permanent one. This
// one asks whether work may happen now, which stops being true on its own schedule.
func AuthorizeCollectionNow(
	r *edgev1.SweepAssignmentRecordV1,
	rawCarrier []byte,
	auth CollectionAuthority,
) error {
	snapR, okR := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	if !okR {
		return ErrCollectionNotAuthorized
	}
	// RAW CARRIER BYTES, not a decoded message. Taking a decoded carrier let the exact-byte
	// ceiling be bypassed entirely: a 65 537-byte carrier that
	// ValidateCompiledSweepAssignmentBytes rejects decodes to a struct this boundary
	// happily accepted. The physical bound only exists on received bytes, so the boundary
	// has to be the one holding them.
	snapC, err := ValidateCompiledSweepAssignmentBytes(rawCarrier)
	if err != nil {
		return err
	}
	if err := ValidateAssignmentAgainstCompiled(snapR, snapC); err != nil {
		return err
	}
	if isNilTrust(auth.Trust) || isNilIface(auth.Assignments) || isNilIface(auth.Session) {
		return ErrCollectionNotAuthorized
	}
	// SCHEDULER ATTESTATION of the carrier. EXACTLY KeyValid: KeyHistoricallyRevoked
	// verifies -- the signature WAS valid when made -- but a compromise-revoked key must
	// never authorize new work; it is reachable only as audit/quarantine evidence.
	status, err := VerifyCompiledAssignmentWithTrust(snapC, auth.Trust, auth.NowUnixNano, auth.TrustEpoch)
	if err != nil {
		return err
	}
	if status != KeyValid {
		return ErrCollectionNotAuthorized
	}
	// HOST EXECUTION PERMISSION for this exact carrier, validated in full and fresh at this
	// instant. Signed by an authority over the host, NOT by the scheduler whose authority is
	// the carrier's own collection capability.
	// The PRIVATE path, because snapC already came from the raw validator: re-entering the
	// public API would decode the same bytes twice.
	grantStatus, grant, err := verifyExecutionGrantSignature(snapR, snapC, auth.ExecutionGrantRaw,
		auth.Trust, auth.NowUnixNano, auth.TrustEpoch)
	if err != nil {
		return err
	}
	if grantStatus != KeyValid {
		return ErrCollectionNotAuthorized
	}
	if err := executionGrantFresh(grant, auth.NowUnixNano); err != nil {
		return err
	}
	// THE CALLER, asked of the transport with COPIED bytes.
	if auth.Session.AuthorizeAgent(
		cloneBytes(snapR.GetNetworkScopeId()), cloneBytes(snapR.GetAuthenticatedAgentId()),
	) != CallerMatches {
		return ErrCollectionNotAuthorized
	}
	// THE AUTHORITATIVE RECORD AND ITS COMMITTED PLAN.
	if err := authorizeAgainstAuthority(snapR, auth); err != nil {
		return err
	}
	// Only now the carrier clock. The NARROWEST window governs, so all three are checked
	// rather than a precomputed intersection that would have to be trusted.
	cap := snapC.GetCollectionCapability()
	if !withinWindow(auth.NowUnixNano, snapC.GetNotBeforeUnixNano(), snapC.GetExpiresAtUnixNano()) ||
		!withinWindow(auth.NowUnixNano, cap.GetNotBeforeUnixNano(), cap.GetExpiresAtUnixNano()) ||
		auth.NowUnixNano >= snapR.GetLeaseExpiresAtUnixNano() {
		return ErrCollectionNotAuthorized
	}
	return nil
}

// withinWindow reports whether now lies in [notBefore, expires) -- half-open, so an
// instant exactly at expiry is already outside.
func withinWindow(now, notBefore, expires int64) bool {
	return now >= notBefore && now < expires
}

func cloneBytes(b []byte) []byte {
	if b == nil {
		return nil
	}
	return append(make([]byte, 0, len(b)), b...)
}

// authorizeAgainstAuthority resolves the authoritative record, its committed plan and the
// RAW committed page bytes, then requires the presented record to be indistinguishable
// from authority IN FULL.
func authorizeAgainstAuthority(r *edgev1.SweepAssignmentRecordV1, auth CollectionAuthority) error {
	// The EXPECTED key is kept independent of the object handed to the resolver, so
	// mutating the request cannot move the expectation with it.
	expected := assignmentKeyFor(r)
	got := auth.Assignments.ResolveAssignment(expected.clone())
	// THE ECHO IS CHECKED BEFORE THE STATUS. A response carrying a different key is not
	// evidence about the assignment we asked for -- so reading its status first would let a
	// cross-key reply prove the requested assignment is ABSENT, a permanent rejection
	// derived from an answer to another question. A mismatched echo is unauthoritative,
	// therefore retryable.
	if !got.Key.equal(expected) {
		return ErrAssignmentAuthorityUnavailable
	}
	switch got.Status {
	case AssignmentAuthorityResolved:
	case AssignmentAuthorityUnavailable:
		// RETRYABLE, and distinct: collapsing it into "not authorized" would turn a lookup
		// outage into a permanent refusal.
		return ErrAssignmentAuthorityUnavailable
	case AssignmentAuthorityUnknown:
		return ErrAssignmentAuthorityUnknown
	default:
		return ErrAssignmentAuthorityUnavailable
	}
	// Collection is authorized only while the series is still OPEN.
	if got.Record.GetState() != edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_OPEN {
		return ErrCollectionNotAuthorized
	}
	// THE WHOLE RECORD. Total equality, so no field -- present or future -- is left
	// unconstrained by a projection that happened to omit it.
	if !proto.Equal(r, got.Record) {
		return ErrCollectionNotAuthorized
	}
	// THE COMMITTED PLAN, from RAW page bytes. ValidateAssignmentAgainstPlan takes decoded
	// pages and so cannot establish the physical MaxPlanPageBytes ceiling -- a re-marshal
	// collapses duplicate known fields. The raw path is therefore authoritative for the
	// bound, and the decoded relation runs on pages parsed from those same bytes.
	// ONE call returns BOTH the header and the DECODED PAGES it validated. Re-decoding the
	// authority's raw slices here would be a check/use gap: the bytes validated and the bytes
	// used would be two separate decodes of storage the authority still owns. An empty page set
	// needs no local guard -- the raw boundary rejects it, and a pre-check would imply otherwise.
	header, pages, err := ValidatePlanFromRaw(got.PlanHeaderRaw, got.PlanPagesRaw)
	if err != nil {
		return err
	}
	return ValidateAssignmentAgainstPlan(got.Record, header, pages)
}

// isNilIface reports whether an interface value is unusable -- either a nil interface OR a
// TYPED NIL (a non-nil interface boxing a nil pointer), which a bare `== nil` misses.
func isNilIface(v any) bool {
	if v == nil {
		return true
	}
	rv := reflect.ValueOf(v)
	//nolint:exhaustive // only the nil-able kinds can be a typed nil; every other kind is a
	// non-nil concrete value, so the default arm correctly reports it as usable.
	switch rv.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return rv.IsNil()
	default:
		return false
	}
}

// VerifyAssignmentExecutionGrant is the CURRENT PERMISSION check: is this host permitted to
// execute this exact compiled assignment, at this instant?
//
// A nil error means PERMITTED. Every non-KeyValid status is an error here, so a caller that
// inspects only the error cannot fail open; the status is still returned so a caller can
// distinguish retryable from permanent.
//
// It validates the carrier and the record/carrier relation ITSELF. An earlier revision took
// both as opaque parameters and checked neither, so a "carrier" carrying nothing but a
// traffic class satisfied it.
//
// `rawGrant` is raw bytes because the grant travels standalone and MaxExecutionGrantBytes is
// a physical bound.
func VerifyAssignmentExecutionGrant(
	r *edgev1.SweepAssignmentRecordV1,
	rawCarrier []byte,
	rawGrant []byte,
	trust CapabilityTrust,
	evalNowUnixNano int64,
	trustEpoch uint64,
) (KeyStatus, error) {
	c, err := ValidateCompiledSweepAssignmentBytes(rawCarrier)
	if err != nil {
		return KeyUnavailable, err
	}
	status, grant, err := verifyExecutionGrantSignature(r, c, rawGrant, trust, evalNowUnixNano, trustEpoch)
	if err != nil {
		return status, err
	}
	// EXACTLY KeyValid. This function's question is "is execution permitted now", so returning
	// (KeyHistoricallyRevoked, nil) made an error-only caller fail OPEN -- a compromise-revoked
	// key reading as permission. A revoked key is reachable as audit evidence via the HISTORICAL
	// verifier, which is where a caller that wants the status without the permission goes.
	if status != KeyValid {
		return status, ErrCollectionNotAuthorized
	}
	if err := executionGrantFresh(grant, evalNowUnixNano); err != nil {
		return status, err
	}
	return status, nil
}

// executionGrantFresh is the CURRENT freshness check, which signature verification
// deliberately does not establish. Both windows are checked; containment is enforced when the
// claim is validated, so the inner window is the narrower of the two by construction.
func executionGrantFresh(grant *edgev1.EdgeSignedCapabilityV1, now int64) error {
	if !withinWindow(now, grant.GetNotBeforeUnixNano(), grant.GetExpiresAtUnixNano()) {
		return ErrAssignmentExecutionGrantBinding
	}
	j := grant.GetAssignmentExecution()
	if !withinWindow(now, j.GetCollectionNotBeforeUnixNano(), j.GetCollectionExpiresUnixNano()) {
		return ErrAssignmentExecutionGrantBinding
	}
	return nil
}

// VerifyAssignmentExecutionGrantHistorical answers the TIMELESS question: was this grant
// validly issued, and what is the CURRENT compromise status of the key that issued it?
//
// It exists so an expired grant can still be re-evaluated without a caller pretending the
// old timestamp is "now".
//
// `trustNowUnixNano` is the CURRENT instant at which the key's rotation/compromise state is
// being asked about -- NOT the grant's old validity time. The EVIDENCE INTERVAL is not a
// parameter because the signed grant already carries it: KeyEvidence's
// NotBeforeUnixNano/ExpiresUnixNano come from the capability itself. An earlier revision
// documented two times but accepted one and spent it as the evaluation time, so a caller
// following the documentation passed the old evidence time and a time-sensitive resolver
// answered KeyValid for a key compromised since.
//
// Freshness of the grant is deliberately NOT checked -- that is what makes this usable after
// expiry.
func VerifyAssignmentExecutionGrantHistorical(
	r *edgev1.SweepAssignmentRecordV1,
	rawCarrier []byte,
	rawGrant []byte,
	trust CapabilityTrust,
	trustNowUnixNano int64,
	trustEpoch uint64,
) (KeyStatus, error) {
	c, err := ValidateCompiledSweepAssignmentBytes(rawCarrier)
	if err != nil {
		return KeyUnavailable, err
	}
	status, _, err := verifyExecutionGrantSignature(r, c, rawGrant, trust, trustNowUnixNano, trustEpoch)
	return status, err
}

// verifyExecutionGrantSignature is the shared, TIMELESS part: bounds, structure, complete
// claim interpretation, the carrier and its relation to the record, then the signature.
// The carrier is a DECODED message here because this is unexported: every public entry point
// obtains it from ValidateCompiledSweepAssignmentBytes, so the exact-byte ceiling cannot be
// bypassed by decoding first. Keeping the decoded form private is what makes that hold.
func verifyExecutionGrantSignature(
	r *edgev1.SweepAssignmentRecordV1,
	c *edgev1.CompiledSweepAssignmentV1,
	rawGrant []byte,
	trust CapabilityTrust,
	trustNowUnixNano int64,
	trustEpoch uint64,
) (KeyStatus, *edgev1.EdgeSignedCapabilityV1, error) {
	if len(rawGrant) > MaxExecutionGrantBytes {
		return KeyUnavailable, nil, ErrExecutionGrantTooLarge
	}
	// THE CARRIER AND THE RELATION, validated here rather than trusted from the caller.
	if err := ValidateAssignmentAgainstCompiled(r, c); err != nil {
		return KeyUnavailable, nil, err
	}
	if isNilTrust(trust) {
		return KeyUnavailable, nil, ErrAssignmentExecutionGrantBinding
	}
	var grant edgev1.EdgeSignedCapabilityV1
	if err := proto.Unmarshal(rawGrant, &grant); err != nil {
		return KeyUnavailable, nil, ErrAssignmentExecutionGrantBinding
	}
	// The ROLE first. Deriving purpose only inspects which oneof member is set -- no framing,
	// no hashing -- so it costs nothing to answer before anything else and keeps a
	// wrong-role capability reported as exactly that rather than as a malformed claim.
	if CapabilityPurpose(&grant) != edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION {
		return KeyUnavailable, nil, ErrCapabilityPurpose
	}
	// STRUCTURE BEFORE HASHING. The signing preimage frames fixed-width members, so every
	// one of them must be checked before any framing or verification touches them --
	// otherwise a malformed member is hashed and only rejected afterwards, if at all.
	if err := validateExecutionGrantClaims(r, c, grant.GetAssignmentExecution(),
		grant.GetNotBeforeUnixNano(), grant.GetExpiresAtUnixNano()); err != nil {
		return KeyUnavailable, nil, err
	}
	status, err := VerifyCapabilityWithTrust(
		&grant, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
		trust, trustNowUnixNano, trustEpoch,
	)
	if err != nil {
		// The grant's OWN typed status, not a flattened one: KeyInvalid (unauthorized,
		// permanent) and KeyUnavailable (retryable) demand different handling upstream.
		return status, nil, err
	}
	return status, &grant, nil
}

// validateExecutionGrantClaims interprets EVERY member of the grant's claim. A member that is
// read but not compared, or not read at all, would be a fact the signature covers and
// nothing enforces.
//
// One branch per claim member: the completeness this asserts is only auditable while the
// members stay in a single list.
//
//nolint:gocyclo // one branch per claim member; see above
func validateExecutionGrantClaims(
	r *edgev1.SweepAssignmentRecordV1,
	c *edgev1.CompiledSweepAssignmentV1,
	j *edgev1.EdgeAssignmentExecutionClaimsV1,
	envelopeNotBefore, envelopeExpires int64,
) error {
	if j == nil {
		return ErrAssignmentExecutionGrantBinding
	}
	if j.GetPurpose() != edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION {
		return ErrAssignmentExecutionGrantBinding
	}
	// PRODUCER KEY. execution_shard / assignment_epoch are the sole wire representation of
	// run_shard / authority_epoch, so the grant is compared across that naming.
	if !bytes.Equal(j.GetNetworkScopeId(), r.GetNetworkScopeId()) ||
		!bytes.Equal(j.GetAuthenticatedAgentId(), r.GetAuthenticatedAgentId()) ||
		!bytes.Equal(j.GetProducerAssignmentId(), r.GetProducerAssignmentId()) ||
		!bytes.Equal(j.GetExecutionId(), r.GetExecutionId()) ||
		!bytes.Equal(j.GetRunId(), r.GetRunId()) ||
		j.GetRunShard() != r.GetExecutionShard() ||
		j.GetAuthorityEpoch() != r.GetAssignmentEpoch() {
		return ErrAssignmentExecutionGrantBinding
	}
	// PRODUCTION FACTS no scheduler carrier covers.
	if !bytes.Equal(j.GetProductionScopeId(), r.GetProductionScopeId()) ||
		!bytes.Equal(j.GetScopeSha256(), r.GetScopeSha256()) ||
		!bytes.Equal(j.GetContractBundleSha256(), r.GetContractBundleSha256()) {
		return ErrAssignmentExecutionGrantBinding
	}
	// PLAN / RANGE. Required lengths, so absence cannot read as "no constraint".
	if len(j.GetExecutionPlanSha256()) != sha256Len || len(j.GetTargetRangeSha256()) != sha256Len ||
		!bytes.Equal(j.GetExecutionPlanSha256(), r.GetExecutionPlanSha256()) ||
		!bytes.Equal(j.GetTargetRangeSha256(), r.GetTargetRangeSha256()) {
		return ErrAssignmentExecutionGrantBinding
	}
	// TRAFFIC CLASS must equal the carrier's immutable class.
	if !knownTrafficClass(j.GetTrafficClass()) || j.GetTrafficClass() != c.GetTrafficClass() {
		return ErrAssignmentExecutionGrantBinding
	}
	// COLLECTION WINDOW: a real grant, and current. 0 is the proto default, so an unset
	// bound must not pose as one.
	if j.GetCollectionNotBeforeUnixNano() <= 0 ||
		j.GetCollectionExpiresUnixNano() <= j.GetCollectionNotBeforeUnixNano() {
		return ErrAssignmentExecutionGrantBinding
	}
	// CONTAINMENT, not merely "a window". Calling the inner grant tighter does not make it so:
	// an inner window reaching outside the envelope would authorize instants the envelope never
	// covered, so a grant wider than the capability carrying it is rejected outright rather
	// than silently intersected.
	if j.GetCollectionNotBeforeUnixNano() < envelopeNotBefore ||
		j.GetCollectionExpiresUnixNano() > envelopeExpires {
		return ErrAssignmentExecutionGrantBinding
	}
	// THE EXACT CARRIER. Both members, so the grant cannot float across recompilations: an
	// id alone names a carrier without pinning which revision of it was permitted.
	if len(j.GetCompiledAssignmentSha256()) != sha256Len ||
		!bytes.Equal(j.GetCompiledAssignmentId(), c.GetCompiledAssignmentId()) ||
		!bytes.Equal(j.GetCompiledAssignmentSha256(), c.GetCompiledAssignmentSha256()) {
		return ErrAssignmentExecutionGrantBinding
	}
	// SOURCE IDENTITY: present EXACTLY WHEN the record carries one, checked in both
	// directions so neither absence can skip a comparison.
	id, claimed := r.GetSourceIdentity(), j.GetSourceIdentity()
	if (id == nil) != (claimed == nil) {
		return ErrAssignmentExecutionGrantBinding
	}
	if id == nil {
		return nil
	}
	if claimed.GetKind() != id.GetKind() ||
		!bytes.Equal(claimed.GetContextId(), id.GetContextId()) ||
		!bytes.Equal(claimed.GetSourceScopeId(), id.GetSourceScopeId()) ||
		!bytes.Equal(claimed.GetSourceScopeSha256(), id.GetSourceScopeSha256()) {
		return ErrAssignmentExecutionGrantBinding
	}
	return nil
}
