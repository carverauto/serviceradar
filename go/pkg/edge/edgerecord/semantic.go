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
	"crypto/sha256"
	"encoding/binary"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// semanticDigestVersion is the versioned tag for the canonical signing-byte
// layout. Any change to which fields are covered, or their order, is a new
// version. Version 3 frames the signed capability and source authorization
// field-by-field instead of by whole-message marshal: protobuf-go emits a
// message's oneof member after higher-numbered scalar fields, while other
// language runtimes emit strict ascending field order, so a whole-message
// marshal of any message containing the capability oneof is NOT byte-identical
// across languages. Field-by-field framing in a fixed canonical order is.
const semanticDigestVersion = 3

// digestWriter accumulates canonical signing bytes with explicit length framing
// and presence markers, so absent, present-zero, and present-nonzero optional
// fields never collide.
type digestWriter struct {
	buf []byte
}

func newDigest() *digestWriter { return &digestWriter{} }

func (d *digestWriter) u64(v uint64) {
	var n [8]byte
	binary.BigEndian.PutUint64(n[:], v)
	d.buf = append(d.buf, n[:]...)
}

func (d *digestWriter) i64(v int64) { d.u64(uint64(v)) }

func (d *digestWriter) bytes(b []byte) {
	d.u64(uint64(len(b)))
	d.buf = append(d.buf, b...)
}

func (d *digestWriter) str(s string) { d.bytes([]byte(s)) }

// present writes a 1-byte presence marker.
func (d *digestWriter) present(p bool) {
	if p {
		d.buf = append(d.buf, 1)
	} else {
		d.buf = append(d.buf, 0)
	}
}

// optU64 writes presence + value for a proto3 optional uint64.
func (d *digestWriter) optU64(v uint64, present bool) {
	d.present(present)
	d.u64(v)
}

// producerContext frames the producer context as one helper, byte-for-byte as the root framed it
// inline. Extracted to match the Elixir peer, which already had a `producer_context/1` clause, so
// the two implementations are shaped alike.
//
// THIS CREATES NO TRANSCRIPT BOUNDARY, and nothing in the test suite may assume it does. The
// helper appends to the SAME buffer with no length prefix and no intermediate hash, so the
// preimage stays one flat, untagged concatenation and every write in it still coexists with
// every other. Only length-framing or hashing a child block would make it opaque, and either
// would change the ABI. Separating the positions inside it from the root's own writes is the
// FIXTURES' job -- see semRecordVariants -- not this function's.
func (d *digestWriter) producerContext(p *edgev1.EdgeProducerContext, present bool) {
	d.present(present)

	if !present || p == nil {
		return
	}

	d.u64(uint64(p.GetOriginKind()))
	d.bytes(p.GetOriginPrincipalId())
	d.bytes(p.GetProducerInstanceId())
	d.bytes(p.GetProducerAssignmentId())
	d.bytes(p.GetRunId())
	d.u64(uint64(p.GetRunShard()))
	d.optU64(p.GetAuthorityEpoch(), p.AuthorityEpoch != nil)
	d.bytes(p.GetScopeId())
	d.bytes(p.GetScopeSha256())
	d.str(p.GetPackageId())
	d.bytes(p.GetPackageSha256())
}

// capability frames a signed capability field-by-field in canonical ascending
// field order. The oneof claim is written via claimsFramed as an explicit u64
// discriminant (the set member's proto field number) followed by the inner claim
// message framed field-by-field -- no proto.Marshal at any depth, so the framing
// is byte-identical across protobuf-go and protobuf-elixir.
func (d *digestWriter) capability(c *edgev1.EdgeSignedCapabilityV1, present bool) {
	d.present(present)
	if !present || c == nil {
		return
	}
	d.u64(uint64(c.GetCapabilityVersion()))
	d.bytes(c.GetIssuerId())
	d.bytes(c.GetIssuerKeyId())
	d.str(c.GetAlgorithm())
	d.i64(c.GetNotBeforeUnixNano())
	d.i64(c.GetExpiresAtUnixNano())
	d.claimsFramed(c)
	d.bytes(c.GetSignature())
}

// sourceAuth frames the source authorization field-by-field; its nested
// capability is framed via capability (above) rather than whole-message marshal.
func (d *digestWriter) sourceAuth(sa *edgev1.EdgeSourceAuthorizationV1, present bool) {
	d.present(present)
	if !present || sa == nil {
		return
	}
	d.u64(uint64(sa.GetKind()))
	sc := sa.GetCapability()
	d.capability(sc, sc != nil)
	d.bytes(sa.GetContextId())
	d.bytes(sa.GetScopeId())
	d.bytes(sa.GetScopeSha256())
}

func (d *digestWriter) finish() []byte {
	s := sha256.Sum256(d.buf)
	return s[:]
}

// SemanticEnvelopeDigest computes the immutable semantic-envelope digest of a
// record: a SHA-256 over the versioned field-framed signing transcript covering
// every semantic/trust field plus the exact payload digest, and EXCLUDING the
// semantic_envelope_sha256 field itself and all delivery state. Optional fields
// carry explicit presence markers; nested capability/authorization/contract
// messages are framed FIELD-BY-FIELD (no proto.Marshal at any depth), so the
// transcript is byte-identical across protobuf-go and protobuf-elixir.
func SemanticEnvelopeDigest(r *edgev1.EdgeRecordV1) []byte {
	return semanticEnvelopeDigestWithVersion(r, semanticDigestVersion)
}

// semanticEnvelopeDigestWithVersion is SemanticEnvelopeDigest with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func semanticEnvelopeDigestWithVersion(r *edgev1.EdgeRecordV1, version uint64) []byte {
	d := newDigest()
	d.u64(version)
	d.bytes(r.GetEventId())
	d.u64(uint64(r.GetPayloadFamily()))
	d.u64(uint64(r.GetCompression()))
	d.u64(uint64(r.GetEncodedSize()))
	d.u64(uint64(r.GetUncompressedSize()))
	d.bytes(r.GetPayloadSha256())

	c := r.GetOutputContract()
	d.outputContract(c, c != nil)

	p := r.GetProducerContext()
	d.producerContext(p, p != nil)

	d.u64(uint64(r.GetRouteProfile()))
	d.u64(uint64(r.GetTrafficClass()))
	d.bytes(r.GetNetworkScopeId())

	pc := r.GetProductionCapability()
	d.capability(pc, pc != nil)

	sa := r.GetSourceAuthorization()
	d.sourceAuth(sa, sa != nil)

	d.u64(uint64(r.GetProjectedRowCount()))
	d.u64(r.GetProjectedWriteBytes())
	d.u64(uint64(r.GetCostModelVersion()))
	return d.finish()
}
