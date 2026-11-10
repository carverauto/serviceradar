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

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// LocalBindingVersion owns the on-disk attribution grammar, independently of wire digests.
const LocalBindingVersion uint64 = 1

var (
	ErrLocalBindingVersion = errors.New("edgerecord: unsupported local binding version")
	ErrLocalBinding        = errors.New("edgerecord: invalid local binding")
	ErrAttributionJoin     = errors.New("edgerecord: attribution does not describe the record")
)

// RecoveryAttribution describes a record's provenance, independently of source presence.
// Passive attribution has no RangeSHA256. Identity uses the frozen recovery span tuple.
type RecoveryAttribution struct {
	Active      bool
	Identity    *edgev1.EdgeAttributedSpanIdentityV1
	RangeSHA256 []byte
}

// LocalBindingCoordinates identify the physical slot and its authenticated generation.
type LocalBindingCoordinates struct {
	NetworkScopeID       []byte
	AuthenticatedAgentID []byte
	LaneRouteProfile     edgev1.EdgeRecordRouteProfile
	LaneTrafficClass     edgev1.EdgeRecordTrafficClass
	SpoolGenerationID    []byte
	Sequence             uint64
	EventID              []byte
	RecordSHA256         []byte
}

// LocalBindingDigest validates and hashes the frozen local_binding.v1 transcript.
// It verifies stored evidence; it does not prove that attribution came from a record.
// Append owners must obtain that proof from a ValidatedAttribution constructor.
func LocalBindingDigest(version uint64, c LocalBindingCoordinates, a RecoveryAttribution) ([]byte, error) {
	if version != LocalBindingVersion {
		return nil, ErrLocalBindingVersion
	}
	if err := validateLocalBinding(c, a); err != nil {
		return nil, err
	}
	d := newDigest()
	d.str("serviceradar.edge.recovery.local_binding.v1")
	d.u64(version)
	d.bytes(c.NetworkScopeID)
	d.bytes(c.AuthenticatedAgentID)
	d.u64(uint64(c.LaneRouteProfile))
	d.u64(uint64(c.LaneTrafficClass))
	d.bytes(c.SpoolGenerationID)
	d.u64(c.Sequence)
	d.bytes(c.EventID)
	d.bytes(c.RecordSHA256)
	d.present(a.Active)
	i := a.Identity
	d.bytes(i.GetContractBundleSha256())
	d.bytes(i.GetProducerAssignmentId())
	d.bytes(i.GetRunId())
	d.u64(uint64(i.GetRunShard()))
	d.u64(i.GetAuthorityEpoch())
	d.bytes(i.GetProductionScopeId())
	d.bytes(i.GetScopeSha256())
	s := i.GetSource()
	d.present(s != nil)
	if s != nil {
		d.u64(uint64(s.GetKind()))
		d.bytes(s.GetContextId())
		d.bytes(s.GetSourceScopeId())
		d.bytes(s.GetSourceScopeSha256())
	}
	if a.Active {
		d.bytes(a.RangeSHA256)
	}
	return d.finish(), nil
}

func validateLocalBinding(c LocalBindingCoordinates, a RecoveryAttribution) error {
	if ValidateCanonicalUUID(c.NetworkScopeID) != nil || ValidateUUIDv7(c.SpoolGenerationID) != nil ||
		ValidateUUIDv7(c.EventID) != nil || c.Sequence == 0 || len(c.RecordSHA256) != sha256Len {
		return ErrLocalBinding
	}
	if err := ValidateAuthenticatedPrincipal(c.AuthenticatedAgentID); err != nil {
		return ErrLocalBinding
	}
	if !knownRouteProfile(c.LaneRouteProfile) || !knownTrafficClass(c.LaneTrafficClass) {
		return ErrLocalBinding
	}
	if a.Identity == nil || hasUnknownFields(a.Identity) || validateSpanIdentity(a.Identity) != nil {
		return ErrLocalBinding
	}
	if (a.Active && len(a.RangeSHA256) != sha256Len) || (!a.Active && len(a.RangeSHA256) != 0) {
		return ErrLocalBinding
	}
	return nil
}

func (a RecoveryAttribution) clone() RecoveryAttribution {
	copy := a
	if a.Identity != nil {
		copy.Identity = proto.Clone(a.Identity).(*edgev1.EdgeAttributedSpanIdentityV1)
	}
	copy.RangeSHA256 = bytes.Clone(a.RangeSHA256)
	return copy
}
