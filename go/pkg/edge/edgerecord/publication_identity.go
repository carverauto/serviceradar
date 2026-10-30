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
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Publication-identity grammars (#4710 Appendix A grammars 6-8): the transport headers a
// gateway derives when publishing a record to JetStream. They are PROJECT-OWNED, field-framed
// codecs (NOT a protobuf message): each transcript leads with a string domain tag, a u64
// version, then length-framed / fixed-width fields, so Go and Elixir
// (ServiceRadar.Edge.PublicationIdentity) produce byte-identical output. Nats-Msg-Id and
// Sr-Edge-Delivery-Id are base64url(no-pad) of the SHA-256 of the transcript; Sr-Edge-
// Transport-Provenance is base64url(no-pad) of the framed envelope itself (not a digest).
//
// spool_id is the persistent UUIDv7 for one delivery lane, so there is NO lane_id anywhere.
// The encoders VALIDATE their inputs and fail closed; DecodeTransportProvenance is the strict
// decoder EventWriter uses; ValidateHeaderSet recomputes and cross-checks the whole header set.

const (
	MsgIDVersion               uint64 = 1
	DeliveryIDVersion          uint64 = 1
	TransportProvenanceVersion uint64 = 1

	// MaxTransportProvenanceHeaderBytes bounds the base64url header (ASCII).
	MaxTransportProvenanceHeaderBytes = 512

	digestLen = 32
)

const (
	msgIDDomain               = "serviceradar.edge.msgid"
	msgIDServiceDomain        = "serviceradar.edge.msgid.service"
	deliveryIDDomain          = "serviceradar.edge.delivery-id"
	deliveryIDServiceDomain   = "serviceradar.edge.delivery-id.service"
	transportProvenanceDomain = "serviceradar.edge.transport-provenance"
)

// Slot-kind discriminant (0 UNSPECIFIED is never emitted and is rejected on decode).
const (
	provenanceSlotUnspecified uint64 = 0
	provenanceSlotEdge        uint64 = 1
	provenanceSlotService     uint64 = 2
)

// DeliveryMode is the gateway-attested transport disposition (replaces the old source_kind).
const (
	DeliveryModeUnspecified uint64 = 0
	DeliveryModeFresh       uint64 = 1
	DeliveryModeRenewal     uint64 = 2
	DeliveryModeRollover    uint64 = 3
	DeliveryModeLateFenced  uint64 = 4
)

var (
	// ErrPublicationIdentity covers a malformed publication-identity input or a decoded
	// header that fails the strict boundary.
	ErrPublicationIdentity = errors.New("edgerecord: invalid publication identity")
	// ErrTransportProvenance is a malformed transport-provenance envelope.
	ErrTransportProvenance = errors.New("edgerecord: invalid transport-provenance envelope")
)

// EdgeSlot is the frozen delivery-slot coordinate: (network_scope_id, authenticated_agent_id,
// spool_id, sequence). spool_id is the persistent per-lane UUIDv7; AuthenticatedAgentID is the
// ASCII authenticated principal and MUST equal producer_context.origin_principal_id.
type EdgeSlot struct {
	NetworkScopeID       []byte
	AuthenticatedAgentID []byte
	SpoolID              []byte
	Sequence             uint64
}

func (s EdgeSlot) validate() error {
	if err := ValidateAuthenticatedPrincipal(s.AuthenticatedAgentID); err != nil {
		return fmt.Errorf("%w: agent principal: %w", ErrPublicationIdentity, err)
	}
	// network_scope_id is a canonical UUID (any version); spool_id is a UUIDv7 -- validate UUID
	// SEMANTICS (version/variant), not merely 16-byte shape.
	if err := ValidateCanonicalUUID(s.NetworkScopeID); err != nil {
		return fmt.Errorf("%w: network_scope_id: %w", ErrPublicationIdentity, err)
	}
	if err := ValidateUUIDv7(s.SpoolID); err != nil {
		return fmt.Errorf("%w: spool_id: %w", ErrPublicationIdentity, err)
	}
	if s.Sequence == 0 {
		return fmt.Errorf("%w: sequence must be >= 1", ErrPublicationIdentity)
	}
	return nil
}

// ServiceSlot is the domain-separated service-ingress slot variant.
type ServiceSlot struct {
	NetworkScopeID         []byte
	AuthenticatedServiceID []byte
	PublicationLaneID      []byte
	PublicationSequence    uint64
}

func (s ServiceSlot) validate() error {
	if err := ValidateAuthenticatedPrincipal(s.AuthenticatedServiceID); err != nil {
		return fmt.Errorf("%w: service principal: %w", ErrPublicationIdentity, err)
	}
	if err := ValidateCanonicalUUID(s.NetworkScopeID); err != nil {
		return fmt.Errorf("%w: network_scope_id: %w", ErrPublicationIdentity, err)
	}
	if err := ValidateUUIDv7(s.PublicationLaneID); err != nil {
		return fmt.Errorf("%w: publication_lane_id: %w", ErrPublicationIdentity, err)
	}
	if s.PublicationSequence == 0 {
		return fmt.Errorf("%w: publication_sequence must be >= 1", ErrPublicationIdentity)
	}
	return nil
}

func requireDigest(b []byte, name string) error {
	if len(b) != digestLen {
		return fmt.Errorf("%w: %s must be a 32-byte digest", ErrPublicationIdentity, name)
	}
	return nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// --- grammar 6: Nats-Msg-Id ---

// NatsMsgIDPreimage returns the frozen 6-field grammar-6 transcript (the raw preimage, before
// SHA-256). Validates all inputs.
func NatsMsgIDPreimage(slot EdgeSlot, semanticEnvelopeSha256, recordSha256 []byte) ([]byte, error) {
	if err := slot.validate(); err != nil {
		return nil, err
	}
	if err := requireDigest(semanticEnvelopeSha256, "semantic_envelope_sha256"); err != nil {
		return nil, err
	}
	if err := requireDigest(recordSha256, "record_sha256"); err != nil {
		return nil, err
	}
	d := newDigest()
	d.str(msgIDDomain)
	d.u64(MsgIDVersion)
	d.bytes(slot.AuthenticatedAgentID)
	d.bytes(slot.NetworkScopeID)
	d.bytes(slot.SpoolID)
	d.u64(slot.Sequence)
	d.bytes(semanticEnvelopeSha256)
	d.bytes(recordSha256)
	return d.buf, nil
}

// NatsMsgID is the base64url(no-pad) SHA-256 of the grammar-6 transcript.
func NatsMsgID(slot EdgeSlot, semanticEnvelopeSha256, recordSha256 []byte) (string, error) {
	pre, err := NatsMsgIDPreimage(slot, semanticEnvelopeSha256, recordSha256)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(pre)
	return b64url(sum[:]), nil
}

// ServiceNatsMsgIDPreimage / ServiceNatsMsgID are the service-ingress variant.
func ServiceNatsMsgIDPreimage(slot ServiceSlot, semanticEnvelopeSha256, recordSha256 []byte) ([]byte, error) {
	if err := slot.validate(); err != nil {
		return nil, err
	}
	if err := requireDigest(semanticEnvelopeSha256, "semantic_envelope_sha256"); err != nil {
		return nil, err
	}
	if err := requireDigest(recordSha256, "record_sha256"); err != nil {
		return nil, err
	}
	d := newDigest()
	d.str(msgIDServiceDomain)
	d.u64(MsgIDVersion)
	d.bytes(slot.AuthenticatedServiceID)
	d.bytes(slot.NetworkScopeID)
	d.bytes(slot.PublicationLaneID)
	d.u64(slot.PublicationSequence)
	d.bytes(semanticEnvelopeSha256)
	d.bytes(recordSha256)
	return d.buf, nil
}

func ServiceNatsMsgID(slot ServiceSlot, semanticEnvelopeSha256, recordSha256 []byte) (string, error) {
	pre, err := ServiceNatsMsgIDPreimage(slot, semanticEnvelopeSha256, recordSha256)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(pre)
	return b64url(sum[:]), nil
}

// --- grammar 7: Sr-Edge-Delivery-Id ---

// DeliveryIDPreimage returns the raw grammar-7 transcript over the frozen edge_slot (no
// record_sha256 -- the slot binding stores record_sha256 as a compared value instead).
func DeliveryIDPreimage(slot EdgeSlot) ([]byte, error) {
	if err := slot.validate(); err != nil {
		return nil, err
	}
	d := newDigest()
	d.str(deliveryIDDomain)
	d.u64(DeliveryIDVersion)
	d.bytes(slot.NetworkScopeID)
	d.bytes(slot.AuthenticatedAgentID)
	d.bytes(slot.SpoolID)
	d.u64(slot.Sequence)
	return d.buf, nil
}

func DeliveryID(slot EdgeSlot) (string, error) {
	pre, err := DeliveryIDPreimage(slot)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(pre)
	return b64url(sum[:]), nil
}

func ServiceDeliveryIDPreimage(slot ServiceSlot) ([]byte, error) {
	if err := slot.validate(); err != nil {
		return nil, err
	}
	d := newDigest()
	d.str(deliveryIDServiceDomain)
	d.u64(DeliveryIDVersion)
	d.bytes(slot.NetworkScopeID)
	d.bytes(slot.AuthenticatedServiceID)
	d.bytes(slot.PublicationLaneID)
	d.u64(slot.PublicationSequence)
	return d.buf, nil
}

func ServiceDeliveryID(slot ServiceSlot) (string, error) {
	pre, err := ServiceDeliveryIDPreimage(slot)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(pre)
	return b64url(sum[:]), nil
}

// --- grammar 8: Sr-Edge-Transport-Provenance ---

// DeliveryProofDigest is the delivery_proof value for a RENEWAL/ROLLOVER/LATE_FENCED_DELIVERY
// record: SHA-256 (32 bytes) over the delivery capability's grammar-2 signing bytes. The
// capability MUST be a DELIVERY capability whose transition matches the claimed delivery_mode
// (RENEWAL -> renewal transition; ROLLOVER/LATE_FENCED_DELIVERY -> rollover), else it errors.
func DeliveryProofDigest(deliveryCap *edgev1.EdgeSignedCapabilityV1, mode uint64) ([]byte, error) {
	// Structurally validate the DELIVERY capability BEFORE hashing (version/issuer/algorithm/
	// window/purpose/signature-present) so a proof can never be minted over a malformed grant.
	if err := ValidateCapability(deliveryCap, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY); err != nil {
		return nil, fmt.Errorf("%w: delivery capability: %w", ErrTransportProvenance, err)
	}
	del := deliveryCap.GetDelivery()
	if del == nil {
		return nil, fmt.Errorf("%w: delivery proof requires a DELIVERY capability", ErrTransportProvenance)
	}
	// Reuse the COMPLETE delivery-claim validator (the same one frame admission uses): bound
	// event_id/spool_id/record_sha256/sequence AND a well-formed transition member (renewal window
	// well-ordered; rollover UUIDs + prior_sequence). A proof must never be minted over malformed
	// signed claims.
	if err := validateDeliveryClaims(del); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrTransportProvenance, err)
	}
	_, isRenewal := del.GetTransition().(*edgev1.EdgeDeliveryClaimsV1_Renewal)
	_, isRollover := del.GetTransition().(*edgev1.EdgeDeliveryClaimsV1_Rollover)
	switch mode {
	case DeliveryModeRenewal:
		if !isRenewal {
			return nil, fmt.Errorf("%w: RENEWAL proof requires a renewal transition", ErrTransportProvenance)
		}
	case DeliveryModeRollover:
		if !isRollover {
			return nil, fmt.Errorf("%w: ROLLOVER proof requires a rollover transition", ErrTransportProvenance)
		}
	case DeliveryModeLateFenced:
		// LATE_FENCED_DELIVERY is a FENCE outcome under a VALID delivery grant; that grant may be
		// a same-spool renewal OR a rollover (the spec does not pin the transition).
		if !isRenewal && !isRollover {
			return nil, fmt.Errorf("%w: late-fenced proof requires a renewal or rollover transition", ErrTransportProvenance)
		}
	default:
		return nil, fmt.Errorf("%w: delivery proof only for renewal/rollover/late-fenced", ErrTransportProvenance)
	}
	sum := sha256.Sum256(CapabilitySigningBytes(deliveryCap))
	return sum[:], nil
}

// TransportProvenanceInput carries the gateway-authenticated provenance fields. EXACTLY one of
// Edge/Service must be set. DeliveryMode is a DeliveryMode* constant (Unspecified rejected).
// DeliveryProof is nil for FRESH and EXACTLY 32 bytes otherwise. Service is FRESH-only in v1.
// RouteMapVersion must be nonzero.
type TransportProvenanceInput struct {
	Edge            *EdgeSlot
	Service         *ServiceSlot
	RecordSha256    []byte
	DeliveryMode    uint64
	DeliveryProof   []byte
	RouteMapVersion uint64
}

// TransportProvenancePreimage returns the raw framed grammar-8 envelope (before base64url),
// fail-closing on any invariant violation.
func TransportProvenancePreimage(in TransportProvenanceInput) ([]byte, error) {
	if (in.Edge == nil) == (in.Service == nil) {
		return nil, fmt.Errorf("%w: exactly one of edge/service slot required", ErrTransportProvenance)
	}
	switch in.DeliveryMode {
	case DeliveryModeFresh, DeliveryModeRenewal, DeliveryModeRollover, DeliveryModeLateFenced:
	default:
		return nil, fmt.Errorf("%w: unspecified or unknown delivery_mode", ErrTransportProvenance)
	}
	if in.RouteMapVersion == 0 {
		return nil, fmt.Errorf("%w: route_map_version must be nonzero", ErrTransportProvenance)
	}
	if err := requireDigest(in.RecordSha256, "record_sha256"); err != nil {
		return nil, err
	}
	if in.Service != nil && in.DeliveryMode != DeliveryModeFresh {
		return nil, fmt.Errorf("%w: service-ingress v1 is FRESH only", ErrTransportProvenance)
	}
	if in.DeliveryMode == DeliveryModeFresh {
		if in.DeliveryProof != nil {
			return nil, fmt.Errorf("%w: FRESH must carry no delivery proof", ErrTransportProvenance)
		}
	} else if err := requireDigest(in.DeliveryProof, "delivery_proof"); err != nil {
		return nil, err
	}

	d := newDigest()
	d.str(transportProvenanceDomain)
	d.u64(TransportProvenanceVersion)
	if in.Edge != nil {
		if err := in.Edge.validate(); err != nil {
			return nil, err
		}
		d.u64(provenanceSlotEdge)
		d.bytes(in.Edge.NetworkScopeID)
		d.bytes(in.Edge.AuthenticatedAgentID)
		d.bytes(in.Edge.SpoolID)
		d.u64(in.Edge.Sequence)
	} else {
		if err := in.Service.validate(); err != nil {
			return nil, err
		}
		d.u64(provenanceSlotService)
		d.bytes(in.Service.NetworkScopeID)
		d.bytes(in.Service.AuthenticatedServiceID)
		d.bytes(in.Service.PublicationLaneID)
		d.u64(in.Service.PublicationSequence)
	}
	d.bytes(in.RecordSha256)
	if in.DeliveryProof != nil {
		d.present(true)
		d.bytes(in.DeliveryProof)
	} else {
		d.present(false)
	}
	d.u64(in.DeliveryMode)
	d.u64(in.RouteMapVersion)
	return d.buf, nil
}

// TransportProvenance base64url(no-pad)-encodes the framed grammar-8 envelope (NOT a digest),
// enforcing the 512-byte header bound.
func TransportProvenance(in TransportProvenanceInput) (string, error) {
	pre, err := TransportProvenancePreimage(in)
	if err != nil {
		return "", err
	}
	header := b64url(pre)
	if len(header) > MaxTransportProvenanceHeaderBytes {
		return "", fmt.Errorf("%w: header exceeds 512 bytes", ErrTransportProvenance)
	}
	return header, nil
}

// DecodedProvenance is the strict-decoded transport-provenance envelope. Exactly one of
// Edge/Service is set.
type DecodedProvenance struct {
	Edge            *EdgeSlot
	Service         *ServiceSlot
	RecordSha256    []byte
	DeliveryMode    uint64
	DeliveryProof   []byte // nil when absent
	RouteMapVersion uint64
}

// provReader is a strict big-endian reader with bounded length prefixes and EOF checking.
type provReader struct {
	b   []byte
	pos int
}

func (r *provReader) u64() (uint64, error) {
	if r.pos+8 > len(r.b) {
		return 0, fmt.Errorf("%w: truncated u64", ErrTransportProvenance)
	}
	v := binary.BigEndian.Uint64(r.b[r.pos : r.pos+8])
	r.pos += 8
	return v, nil
}

func (r *provReader) bytesField() ([]byte, error) {
	n, err := r.u64()
	if err != nil {
		return nil, err
	}
	// Bounded length prefix: cannot exceed the remaining bytes.
	if n > uint64(len(r.b)-r.pos) {
		return nil, fmt.Errorf("%w: length prefix exceeds remaining bytes", ErrTransportProvenance)
	}
	out := r.b[r.pos : r.pos+int(n)]
	r.pos += int(n)
	return out, nil
}

func (r *provReader) present() (bool, error) {
	if r.pos+1 > len(r.b) {
		return false, fmt.Errorf("%w: truncated presence byte", ErrTransportProvenance)
	}
	c := r.b[r.pos]
	r.pos++
	switch c {
	case 0x00:
		return false, nil
	case 0x01:
		return true, nil
	default:
		return false, fmt.Errorf("%w: presence byte is not 0x00/0x01", ErrTransportProvenance)
	}
}

func (r *provReader) str(want string) error {
	got, err := r.bytesField()
	if err != nil {
		return err
	}
	if string(got) != want {
		return fmt.Errorf("%w: domain tag mismatch (want %q)", ErrTransportProvenance, want)
	}
	return nil
}

// DecodeTransportProvenance strictly decodes a base64url(no-pad) transport-provenance header:
// it requires CANONICAL base64url (no aliasing), the frozen domain/version, a known slot kind,
// bounded length prefixes, a 0x00/0x01 presence byte, a known delivery_mode, a nonzero
// route_map_version, the FRESH/proof invariant, and EXACT end-of-input (no trailing bytes).
//
//nolint:gocyclo // flat fail-closed strict decoder; each boundary rule is one sequential branch
func DecodeTransportProvenance(header string) (*DecodedProvenance, error) {
	if len(header) > MaxTransportProvenanceHeaderBytes {
		return nil, fmt.Errorf("%w: header exceeds 512 bytes", ErrTransportProvenance)
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(header)
	if err != nil {
		return nil, fmt.Errorf("%w: non-canonical base64url: %w", ErrTransportProvenance, err)
	}
	// Strict() rejects trailing-bit aliases but STILL SKIPS embedded CR/LF; require an exact
	// canonical round-trip so newline-laced (or any other non-canonical) input is rejected,
	// matching the Elixir peer's re-encode check.
	if b64url(raw) != header {
		return nil, fmt.Errorf("%w: non-canonical base64url encoding", ErrTransportProvenance)
	}
	r := &provReader{b: raw}
	if err := r.str(transportProvenanceDomain); err != nil {
		return nil, err
	}
	ver, err := r.u64()
	if err != nil {
		return nil, err
	}
	if ver != TransportProvenanceVersion {
		return nil, fmt.Errorf("%w: unknown version %d", ErrTransportProvenance, ver)
	}
	kind, err := r.u64()
	if err != nil {
		return nil, err
	}
	out := &DecodedProvenance{}
	switch kind {
	case provenanceSlotEdge:
		ns, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		agent, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		spool, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		seq, err := r.u64()
		if err != nil {
			return nil, err
		}
		slot := EdgeSlot{NetworkScopeID: clone(ns), AuthenticatedAgentID: clone(agent), SpoolID: clone(spool), Sequence: seq}
		if err := slot.validate(); err != nil {
			return nil, err
		}
		out.Edge = &slot
	case provenanceSlotService:
		ns, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		svc, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		lane, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		seq, err := r.u64()
		if err != nil {
			return nil, err
		}
		slot := ServiceSlot{NetworkScopeID: clone(ns), AuthenticatedServiceID: clone(svc), PublicationLaneID: clone(lane), PublicationSequence: seq}
		if err := slot.validate(); err != nil {
			return nil, err
		}
		out.Service = &slot
	case provenanceSlotUnspecified:
		return nil, fmt.Errorf("%w: slot kind is unspecified", ErrTransportProvenance)
	default:
		return nil, fmt.Errorf("%w: unknown slot kind %d", ErrTransportProvenance, kind)
	}

	recordSha, err := r.bytesField()
	if err != nil {
		return nil, err
	}
	if err := requireDigest(recordSha, "record_sha256"); err != nil {
		return nil, err
	}
	out.RecordSha256 = clone(recordSha)

	hasProof, err := r.present()
	if err != nil {
		return nil, err
	}
	if hasProof {
		proof, err := r.bytesField()
		if err != nil {
			return nil, err
		}
		if err := requireDigest(proof, "delivery_proof"); err != nil {
			return nil, err
		}
		out.DeliveryProof = clone(proof)
	}

	mode, err := r.u64()
	if err != nil {
		return nil, err
	}
	switch mode {
	case DeliveryModeFresh, DeliveryModeRenewal, DeliveryModeRollover, DeliveryModeLateFenced:
	default:
		return nil, fmt.Errorf("%w: unknown delivery_mode %d", ErrTransportProvenance, mode)
	}
	out.DeliveryMode = mode

	rmv, err := r.u64()
	if err != nil {
		return nil, err
	}
	if rmv == 0 {
		return nil, fmt.Errorf("%w: route_map_version must be nonzero", ErrTransportProvenance)
	}
	out.RouteMapVersion = rmv

	// EXACT end of input: no trailing bytes.
	if r.pos != len(r.b) {
		return nil, fmt.Errorf("%w: trailing bytes after envelope", ErrTransportProvenance)
	}
	// FRESH/proof invariant and service-FRESH-only, re-checked on the decoded values.
	if (out.DeliveryMode == DeliveryModeFresh) != (out.DeliveryProof == nil) {
		return nil, fmt.Errorf("%w: delivery-proof presence disagrees with FRESH mode", ErrTransportProvenance)
	}
	if out.Service != nil && out.DeliveryMode != DeliveryModeFresh {
		return nil, fmt.Errorf("%w: service-ingress v1 is FRESH only", ErrTransportProvenance)
	}
	return out, nil
}

func clone(b []byte) []byte {
	c := make([]byte, len(b))
	copy(c, b)
	return c
}

// PublisherClass is the authenticated publisher class a header set MUST bind to: an
// agent-origin edge record or a governed service-ingress record. It is derived from the
// authenticated publisher subject/credential AND from the record origin_kind, and MUST match the
// provenance slot kind.
type PublisherClass uint8

const (
	PublisherClassUnspecified PublisherClass = iota
	PublisherClassEdge
	PublisherClassService
)

// publisherClassForOriginKind maps an EdgeRecordV1 origin_kind to its publisher class.
func publisherClassForOriginKind(k edgev1.EdgeOriginKind) PublisherClass {
	//nolint:exhaustive // default maps UNSPECIFIED/unknown to PublisherClassUnspecified (rejected)
	switch k {
	case edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT:
		return PublisherClassEdge
	case edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_CLUSTER_SERVICE:
		return PublisherClassService
	default:
		return PublisherClassUnspecified
	}
}

// Required publication-identity header names (canonical spelling; matched CASE-INSENSITIVELY at
// the extraction boundary). There is NO Sr-Edge-Route-Map-Version header -- route_map_version
// travels ONLY inside the provenance envelope.
const (
	HeaderNatsMsgID  = "Nats-Msg-Id"
	HeaderDeliveryID = "Sr-Edge-Delivery-Id"
	HeaderProvenance = "Sr-Edge-Transport-Provenance"
)

// HeaderSet is the extracted publication-identity header triple (exactly one value each).
type HeaderSet struct {
	NatsMsgID  string
	DeliveryID string
	Provenance string
}

// ExtractHeaderSet pulls the three required publication-identity headers from a raw header
// multimap, matching names CASE-INSENSITIVELY and requiring EXACTLY ONE non-empty value for
// each. A missing header, an empty value, or a duplicate (the same header repeated under one key
// OR under case-variant keys) is rejected fail-closed -- the scalar validator cannot see
// duplicates, so this boundary is where duplicate/case-variant headers are caught.
func ExtractHeaderSet(headers map[string][]string) (HeaderSet, error) {
	byLower := map[string][]string{}
	for name, values := range headers {
		lower := strings.ToLower(name)
		byLower[lower] = append(byLower[lower], values...)
	}
	one := func(name string) (string, error) {
		vs := byLower[strings.ToLower(name)]
		switch {
		case len(vs) == 0:
			return "", fmt.Errorf("%w: missing required header %q", ErrPublicationIdentity, name)
		case len(vs) > 1:
			return "", fmt.Errorf("%w: duplicate header %q", ErrPublicationIdentity, name)
		case vs[0] == "":
			return "", fmt.Errorf("%w: empty header %q", ErrPublicationIdentity, name)
		default:
			return vs[0], nil
		}
	}
	msg, err := one(HeaderNatsMsgID)
	if err != nil {
		return HeaderSet{}, err
	}
	del, err := one(HeaderDeliveryID)
	if err != nil {
		return HeaderSet{}, err
	}
	prov, err := one(HeaderProvenance)
	if err != nil {
		return HeaderSet{}, err
	}
	return HeaderSet{NatsMsgID: msg, DeliveryID: del, Provenance: prov}, nil
}

// HeaderTrustContext carries the AUTHORITATIVE record-derived and credential-derived values a
// header set MUST bind to. RecordNetworkScopeID / RecordOriginKind / RecordPrincipal come from
// the decoded EdgeRecordV1; ExpectedPublisherClass comes from the authenticated publisher subject
// (edge=gateway class, service=governed service class); SemanticEnvelopeSha256 / RecordSha256 are
// the record's semantic digest and exact-bytes hash.
//
// TrustedPublisherPrincipal is the credential-derived publisher identity and is compared to the
// record principal ONLY on the SERVICE-INGRESS path (where the governed service IS the publisher).
// On the EDGE path the publisher is the gateway, whose credential identity differs from the agent
// principal by design, so this field is IGNORED for edge records.
type HeaderTrustContext struct {
	RecordNetworkScopeID      []byte
	RecordOriginKind          edgev1.EdgeOriginKind
	RecordPrincipal           []byte
	ExpectedPublisherClass    PublisherClass
	TrustedPublisherPrincipal []byte
	SemanticEnvelopeSha256    []byte
	RecordSha256              []byte
}

// ValidateHeaderSet is EventWriter's complete header-set validator: it strictly decodes the
// provenance envelope, recomputes Nats-Msg-Id and Sr-Edge-Delivery-Id from the decoded slot and
// the record's authoritative fields, and CROSS-CHECKS byte-for-byte the record hash, the network
// scope, the slot kind vs record origin_kind AND the authenticated publisher class, and the
// provenance principal vs the record origin_principal_id.
//
// The credential-derived publisher principal (ctx.TrustedPublisherPrincipal) equals the record
// principal ONLY on the SERVICE-INGRESS path, where the governed service IS the authenticated
// publisher. For EDGE records the publisher is the GATEWAY, whose per-class NATS credential
// identity is DIFFERENT from the originating agent by design; edge trust is the authenticated
// gateway publisher CLASS (ExpectedPublisherClass == Edge, checked here) plus the per-class subject
// isolation enforced at the transport layer, NOT a credential==agent comparison. Any disagreement
// fails closed, so a self-consistent header set can no longer bind a record to the wrong scope or
// ingress class.
func ValidateHeaderSet(hs HeaderSet, ctx HeaderTrustContext) error {
	dp, err := DecodeTransportProvenance(hs.Provenance)
	if err != nil {
		return err
	}
	if !bytes.Equal(dp.RecordSha256, ctx.RecordSha256) {
		return fmt.Errorf("%w: provenance record_sha256 != record", ErrPublicationIdentity)
	}

	recordClass := publisherClassForOriginKind(ctx.RecordOriginKind)
	if recordClass == PublisherClassUnspecified {
		return fmt.Errorf("%w: record origin_kind is unspecified/unknown", ErrPublicationIdentity)
	}
	if ctx.ExpectedPublisherClass != recordClass {
		return fmt.Errorf("%w: authenticated publisher class != record origin_kind", ErrPublicationIdentity)
	}

	var (
		slotScope, slotPrincipal []byte
		slotClass                PublisherClass
		wantMsg, wantDel         string
		isService                bool
	)
	switch {
	case dp.Edge != nil:
		slotClass, slotScope, slotPrincipal = PublisherClassEdge, dp.Edge.NetworkScopeID, dp.Edge.AuthenticatedAgentID
		if wantMsg, err = NatsMsgID(*dp.Edge, ctx.SemanticEnvelopeSha256, ctx.RecordSha256); err != nil {
			return err
		}
		if wantDel, err = DeliveryID(*dp.Edge); err != nil {
			return err
		}
	default:
		isService = true
		slotClass, slotScope, slotPrincipal = PublisherClassService, dp.Service.NetworkScopeID, dp.Service.AuthenticatedServiceID
		if wantMsg, err = ServiceNatsMsgID(*dp.Service, ctx.SemanticEnvelopeSha256, ctx.RecordSha256); err != nil {
			return err
		}
		if wantDel, err = ServiceDeliveryID(*dp.Service); err != nil {
			return err
		}
	}

	if slotClass != recordClass {
		return fmt.Errorf("%w: provenance slot kind != record origin_kind / publisher class", ErrPublicationIdentity)
	}
	if !bytes.Equal(slotScope, ctx.RecordNetworkScopeID) {
		return fmt.Errorf("%w: provenance network_scope_id != record network_scope_id", ErrPublicationIdentity)
	}
	if !bytes.Equal(slotPrincipal, ctx.RecordPrincipal) {
		return fmt.Errorf("%w: provenance principal != record origin_principal_id", ErrPublicationIdentity)
	}
	// SERVICE-ONLY: the governed service's credential resolves to its authenticated_service_id,
	// which MUST equal the record/provenance principal. NOT applied to edge (gateway credential).
	if isService && !bytes.Equal(slotPrincipal, ctx.TrustedPublisherPrincipal) {
		return fmt.Errorf("%w: service principal != credential-derived service identity", ErrPublicationIdentity)
	}
	if hs.NatsMsgID != wantMsg {
		return fmt.Errorf("%w: Nats-Msg-Id does not match the record/slot", ErrPublicationIdentity)
	}
	if hs.DeliveryID != wantDel {
		return fmt.Errorf("%w: Sr-Edge-Delivery-Id does not match the slot", ErrPublicationIdentity)
	}
	return nil
}
