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

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// ValidatedAttribution is the immutable output of a contract-owned record validator.
// Its zero value cannot authorize a binding. It retains no caller-owned protobufs.
type ValidatedAttribution struct {
	attribution RecoveryAttribution
	record      LocalBindingCoordinates
	valid       bool
}

// Attribution returns a copy suitable for independent durable storage.
func (v ValidatedAttribution) Attribution() RecoveryAttribution { return v.attribution.clone() }

// Bind joins the complete proposed attribution and physical record identity before
// hashing a destination slot. Generation and sequence may change during relocation;
// namespace, lane, event, exact record bytes and attribution may not.
func (v ValidatedAttribution) Bind(c LocalBindingCoordinates, a RecoveryAttribution) ([]byte, error) {
	if !v.valid || a.Active != v.attribution.Active ||
		!proto.Equal(a.Identity, v.attribution.Identity) || !bytes.Equal(a.RangeSHA256, v.attribution.RangeSHA256) ||
		!bytes.Equal(c.NetworkScopeID, v.record.NetworkScopeID) ||
		!bytes.Equal(c.AuthenticatedAgentID, v.record.AuthenticatedAgentID) ||
		c.LaneRouteProfile != v.record.LaneRouteProfile || c.LaneTrafficClass != v.record.LaneTrafficClass ||
		!bytes.Equal(c.EventID, v.record.EventID) || !bytes.Equal(c.RecordSHA256, v.record.RecordSHA256) {
		return nil, ErrAttributionJoin
	}
	return LocalBindingDigest(LocalBindingVersion, c, a)
}

// SweepRecoveryAttribution validates the signed sweep record and derives its range
// from the validated body. Existing correlation rules select the source operand;
// producer run_id is never interpreted as a scheduler execution id.
func SweepRecoveryAttribution(raw []byte, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) (ValidatedAttribution, error) {
	r, err := DecodeRecord(raw)
	if err != nil {
		return ValidatedAttribution{}, err
	}
	if err := ValidateSweepRecord(r, expected, policy); err != nil {
		return ValidatedAttribution{}, err
	}
	inner, err := innerPayload(r)
	if err != nil {
		return ValidatedAttribution{}, err
	}
	var body edgev1.SweepObservationBatchV1
	if err := unmarshalPayload(inner, &body); err != nil {
		return ValidatedAttribution{}, err
	}
	return validatedRecoveryAttribution(raw, r, true, body.GetTargetRangeSha256())
}

// ControlRecoveryAttribution preserves recovery's source identity while asserting
// no produced target range. Source presence does not imply ACTIVE attribution.
func ControlRecoveryAttribution(raw []byte, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) (ValidatedAttribution, error) {
	r, err := DecodeRecord(raw)
	if err != nil {
		return ValidatedAttribution{}, err
	}
	if err := ValidateRecoveryControl(r, expected, policy); err != nil {
		return ValidatedAttribution{}, err
	}
	return validatedRecoveryAttribution(raw, r, false, nil)
}

// MetricRecoveryAttribution composes the standing metrics contract with signature
// verification. Metrics do not assert a produced scheduler target range.
func MetricRecoveryAttribution(raw []byte, policy AuthorizationPolicy) (ValidatedAttribution, error) {
	r, err := DecodeRecord(raw)
	if err != nil {
		return ValidatedAttribution{}, err
	}
	if err := ValidateMetricBatchRecord(r); err != nil {
		return ValidatedAttribution{}, err
	}
	if err := ValidateRecordSigned(r, policy); err != nil {
		return ValidatedAttribution{}, err
	}
	return validatedRecoveryAttribution(raw, r, false, nil)
}

// Called only after a typed validator has proven the body/claim relation. Keeping
// this constructor private prevents an arbitrary range digest becoming evidence.
func validatedRecoveryAttribution(raw []byte, r *edgev1.EdgeRecordV1, active bool, rangeSHA []byte) (ValidatedAttribution, error) {
	p := r.GetProducerContext()
	if p.GetOriginKind() != edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT {
		return ValidatedAttribution{}, ErrAttributionJoin
	}
	id := &edgev1.EdgeAttributedSpanIdentityV1{
		ContractBundleSha256: bytes.Clone(r.GetOutputContract().GetContractBundleSha256()),
		ProducerAssignmentId: bytes.Clone(p.GetProducerAssignmentId()),
		RunId:                bytes.Clone(p.GetRunId()), RunShard: p.GetRunShard(), AuthorityEpoch: p.GetAuthorityEpoch(),
		ProductionScopeId: bytes.Clone(p.GetScopeId()), ScopeSha256: bytes.Clone(p.GetScopeSha256()),
	}
	if s := r.GetSourceAuthorization(); s != nil {
		id.Source = &edgev1.EdgeSourceSpanIdentityV1{
			Kind: s.GetKind(), ContextId: bytes.Clone(s.GetContextId()),
			SourceScopeId: bytes.Clone(s.GetScopeId()), SourceScopeSha256: bytes.Clone(s.GetScopeSha256()),
		}
	}
	a := RecoveryAttribution{Active: active, Identity: id, RangeSHA256: bytes.Clone(rangeSHA)}
	if validateSpanIdentity(id) != nil || (active && len(rangeSHA) != sha256Len) {
		return ValidatedAttribution{}, ErrAttributionJoin
	}
	hash := sha256.Sum256(raw)
	return ValidatedAttribution{
		attribution: a, valid: true,
		record: LocalBindingCoordinates{
			NetworkScopeID: bytes.Clone(r.GetNetworkScopeId()), AuthenticatedAgentID: bytes.Clone(p.GetOriginPrincipalId()),
			LaneRouteProfile: r.GetRouteProfile(), LaneTrafficClass: r.GetTrafficClass(),
			EventID: bytes.Clone(r.GetEventId()), RecordSHA256: hash[:],
		},
	}, nil
}
