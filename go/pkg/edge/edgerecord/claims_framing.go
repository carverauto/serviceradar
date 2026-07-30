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
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Field-by-field framing of every nested message that participates in a
// signing/digest preimage, per #4710 Appendix A. This replaces the previous
// whole-message proto.Marshal(): protobuf-go emits a message's oneof member out
// of field order and elides different absent/default states differently than
// protobuf-elixir, so no proto.Marshal output may appear in any preimage at any
// depth. Each framer writes its fields in the frozen order using the digestWriter
// primitives (8-byte big-endian ints, 8-byte length-prefixed bytes/str, 1-byte
// presence, u64 oneof discriminant = the set member's proto field number).

// outputContract frames EdgeOutputContractRef (Appendix A grammar 1).
func (d *digestWriter) outputContract(c *edgev1.EdgeOutputContractRef, present bool) {
	d.present(present)
	if !present || c == nil {
		return
	}
	d.str(c.GetContractId())
	d.u64(uint64(c.GetContractVersion()))
	d.bytes(c.GetContractBundleSha256())
	d.u64(c.GetRegistryEpoch())
	d.bytes(c.GetRegistrySnapshotSha256())
	d.bytes(c.GetEffectiveGrantSha256())
}

// claimsFramed writes the capability's `claims` oneof: a u64 discriminant equal
// to the set member's proto FIELD NUMBER -- currently 7 (production), 8 (source),
// 9 (delivery), 11 (collection) or 12 (assignment_execution), or 0 for none -- followed by the
// selected claim message framed field-by-field. Used by BOTH the semantic-envelope
// capability() sub-frame AND CapabilitySigningBytes so the two bind the claims
// identically (task 1.13 unification).
func (d *digestWriter) claimsFramed(c *edgev1.EdgeSignedCapabilityV1) {
	switch cl := c.GetClaims().(type) {
	case *edgev1.EdgeSignedCapabilityV1_Production:
		d.u64(7)
		d.productionClaims(cl.Production)
	case *edgev1.EdgeSignedCapabilityV1_Source:
		d.u64(8)
		d.sourceClaims(cl.Source)
	case *edgev1.EdgeSignedCapabilityV1_Delivery:
		d.u64(9)
		d.deliveryClaims(cl.Delivery)
	case *edgev1.EdgeSignedCapabilityV1_Collection:
		// The discriminant is the member's PROTO FIELD NUMBER, which is 11 -- not its
		// position in this switch. Collection was added after `signature` took 10.
		d.u64(11)
		d.collectionClaims(cl.Collection)
	case *edgev1.EdgeSignedCapabilityV1_AssignmentExecution:
		// Field number 12, again NOT the switch position.
		d.u64(12)
		d.executionGrantClaims(cl.AssignmentExecution)
	default:
		d.u64(0)
	}
}

// collectionClaims frames EdgeCollectionClaimsV1 (fields 1-11, in field order).
//
// `compiled_assignment_body_sha256` is the load-bearing member: it commits every compiled
// fact, so this claim signs config generation, result format, check set and validity
// window TRANSITIVELY without restating any of them. It is the BODY digest, not the
// artifact address -- the artifact address covers this capability, so signing it would
// require the signature to cover itself.
func (d *digestWriter) collectionClaims(c *edgev1.EdgeCollectionClaimsV1) {
	d.u64(uint64(c.GetPurpose()))
	d.bytes(c.GetNetworkScopeId())
	d.bytes(c.GetAuthenticatedAgentId())
	d.bytes(c.GetExecutionPlanId())
	d.bytes(c.GetTargetRangeId())
	d.u64(uint64(c.GetExecutionShard()))
	d.u64(c.GetAssignmentEpoch())
	d.bytes(c.GetCompiledAssignmentBodySha256())
	d.u64(uint64(c.GetTrafficClass()))
	d.bytes(c.GetProducerAssignmentId())
	d.bytes(c.GetExecutionId())
}

// productionClaims frames EdgeProductionClaimsV1 (fields 1-23, in field order).
func (d *digestWriter) productionClaims(c *edgev1.EdgeProductionClaimsV1) {
	d.str(c.GetContractId())
	d.u64(uint64(c.GetContractVersion()))
	d.bytes(c.GetContractBundleSha256())
	d.u64(c.GetRegistryEpoch())
	d.bytes(c.GetNetworkScopeId())
	d.bytes(c.GetProducerAssignmentId())
	d.u64(uint64(c.GetTrafficClass()))
	d.u64(uint64(c.GetRouteProfile()))
	d.u64(uint64(c.GetOriginKind()))
	d.bytes(c.GetOriginPrincipalId())
	d.bytes(c.GetProducerInstanceId())
	d.bytes(c.GetRunId())
	d.u64(uint64(c.GetRunShard()))
	d.u64(c.GetAuthorityEpoch())
	d.bytes(c.GetScopeId())
	d.bytes(c.GetScopeSha256())
	d.bytes(c.GetPackageSha256())
	d.bytes(c.GetRegistrySnapshotSha256())
	d.bytes(c.GetEffectiveGrantSha256())
	d.u64(uint64(c.GetMaxProjectedRowCount()))
	d.u64(c.GetMaxProjectedWriteBytes())
	d.u64(uint64(c.GetCostModelVersion()))
	d.str(c.GetPackageId())
}

// sourceClaims frames EdgeSourceClaimsV1 (fields 1-18, in field order).
func (d *digestWriter) sourceClaims(c *edgev1.EdgeSourceClaimsV1) {
	d.u64(uint64(c.GetKind()))
	d.bytes(c.GetContextId())
	d.bytes(c.GetScopeId())
	d.bytes(c.GetScopeSha256())
	d.bytes(c.GetNetworkScopeId())
	d.i64(c.GetCollectionNotBeforeUnixNano())
	d.i64(c.GetCollectionExpiresUnixNano())
	d.bytes(c.GetOriginPrincipalId())
	d.bytes(c.GetProducerInstanceId())
	d.bytes(c.GetProducerAssignmentId())
	d.bytes(c.GetRunId())
	d.u64(uint64(c.GetRunShard()))
	d.u64(c.GetAuthorityEpoch())
	d.u64(uint64(c.GetTrafficClass()))
	d.u64(uint64(c.GetRouteProfile()))
	d.bytes(c.GetExecutionPlanSha256())
	d.bytes(c.GetTargetRangeSha256())
	d.u64(uint64(c.GetOriginKind()))
}

// deliveryClaims frames EdgeDeliveryClaimsV1 (fields 1-4 + the transition oneof).
// The transition oneof is field-framed (u64 discriminant 5=renewal / 6=rollover /
// 0=none, then the framed member) instead of proto.Marshal -- EdgeDeliveryClaimsV1
// DOES carry a oneof, so a whole-message marshal is NOT cross-language stable.
func (d *digestWriter) deliveryClaims(c *edgev1.EdgeDeliveryClaimsV1) {
	d.bytes(c.GetEventId())
	d.bytes(c.GetRecordSha256())
	d.bytes(c.GetSpoolId())
	d.u64(c.GetSequence())
	switch t := c.GetTransition().(type) {
	case *edgev1.EdgeDeliveryClaimsV1_Renewal:
		d.u64(5)
		d.i64(t.Renewal.GetRenewedNotBeforeUnixNano())
		d.i64(t.Renewal.GetRenewedExpiresUnixNano())
	case *edgev1.EdgeDeliveryClaimsV1_Rollover:
		d.u64(6)
		d.bytes(t.Rollover.GetRecoveryId())
		d.bytes(t.Rollover.GetPriorSpoolId())
		d.u64(t.Rollover.GetPriorSequence())
	default:
		d.u64(0)
	}
}

// executionGrantClaims frames EdgeAssignmentExecutionClaimsV1 (fields 1-19, in field
// order). The nested source identity is framed with an explicit presence marker followed
// by its members. The marker is NOT what separates absent from present-with-zeros -- this
// message has a fixed member list, so those two already frame to different lengths. It is
// kept for CONVENTION and for cross-runtime agreement: the committed signing-preimage
// vector includes it, so removing it is an ABI break even where it is redundant.
func (d *digestWriter) executionGrantClaims(c *edgev1.EdgeAssignmentExecutionClaimsV1) {
	d.u64(uint64(c.GetPurpose()))
	d.bytes(c.GetNetworkScopeId())
	d.bytes(c.GetAuthenticatedAgentId())
	d.bytes(c.GetProducerAssignmentId())
	d.bytes(c.GetExecutionId())
	d.bytes(c.GetRunId())
	d.u64(uint64(c.GetRunShard()))
	d.u64(c.GetAuthorityEpoch())
	d.bytes(c.GetProductionScopeId())
	d.bytes(c.GetScopeSha256())
	d.bytes(c.GetContractBundleSha256())
	d.bytes(c.GetExecutionPlanSha256())
	d.bytes(c.GetTargetRangeSha256())
	d.u64(uint64(c.GetTrafficClass()))
	d.i64(c.GetCollectionNotBeforeUnixNano())
	d.i64(c.GetCollectionExpiresUnixNano())
	id := c.GetSourceIdentity()
	// An explicit presence marker, matching every other grammar in this package. With this
	// message's fixed member list an absent identity and a present-but-empty one already frame
	// differently, so the marker is not what separates them. Deleting it nonetheless breaks the
	// COMMITTED signing-preimage vector in //proto/edge/v1 -- the ABI freeze doing its job -- so
	// it is load-bearing for cross-runtime agreement even where it is redundant here.
	d.present(id != nil)
	if id != nil {
		d.u64(uint64(id.GetKind()))
		d.bytes(id.GetContextId())
		d.bytes(id.GetSourceScopeId())
		d.bytes(id.GetSourceScopeSha256())
	}
	d.bytes(c.GetCompiledAssignmentId())
	d.bytes(c.GetCompiledAssignmentSha256())
}
