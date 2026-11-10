// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package edgerecord

import (
	"bytes"
	"errors"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

var ErrRecoveryResolution = errors.New("invalid recovery resolution evidence")

// ValidatedRecoveryResolution is a historical consumer completion receipt, not
// permission to produce records. Storage must additionally join its recovery ID,
// root and applied prefix to the frozen journal before releasing evidence.
type ValidatedRecoveryResolution struct {
	resolved   *edgev1.RecoveryResolvedV1
	capability *edgev1.EdgeSignedCapabilityV1
}

// ValidateRecoveryResolution verifies the original signed completion against the
// current retained key policy and authenticated namespace. The signed validity
// window is evidence for key history, not a deadline for collecting a completed
// recovery: ordinary production freshness/fences do not apply to this receipt.
// Compromise revocation still refuses it. The frozen scope digest binds applied
// state, not resolved_at; storage retains the issuer's first completion timestamp.
func ValidateRecoveryResolution(resolved *edgev1.RecoveryResolvedV1, capability *edgev1.EdgeSignedCapabilityV1,
	networkScopeID, authenticatedAgentID []byte, policy AuthorizationPolicy) (*ValidatedRecoveryResolution, error) {
	if resolved == nil || capability == nil || len(networkScopeID) != 16 || len(authenticatedAgentID) == 0 {
		return nil, ErrRecoveryResolution
	}
	rv := proto.Clone(resolved).(*edgev1.RecoveryResolvedV1)
	cap := proto.Clone(capability).(*edgev1.EdgeSignedCapabilityV1)
	if hasUnknownFields(rv) || rv.GetResolvedAtUnixNano() <= 0 {
		return nil, ErrRecoveryResolution
	}
	_, digest, err := recoveryControlBody(&edgev1.EdgeRecoveryControlPayloadV1{
		Body: &edgev1.EdgeRecoveryControlPayloadV1_Resolved{Resolved: rv},
	})
	if err != nil {
		return nil, err
	}
	status, err := VerifyCapabilityWithTrust(cap, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE,
		policy.Trust, policy.NowUnixNano, policy.TrustPolicyEpoch)
	if err != nil {
		return nil, err
	}
	if status != KeyValid {
		return nil, ErrRecoveryResolution
	}
	claims := cap.GetSource()
	if claims == nil || claims.GetKind() != edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL ||
		!bytes.Equal(claims.GetNetworkScopeId(), networkScopeID) ||
		!bytes.Equal(claims.GetOriginPrincipalId(), authenticatedAgentID) ||
		!bytes.Equal(claims.GetContextId(), rv.GetRecoveryId()) ||
		!bytes.Equal(claims.GetScopeId(), rv.GetRecoveryId()) ||
		!bytes.Equal(claims.GetScopeSha256(), digest) {
		return nil, ErrRecoveryResolution
	}
	return &ValidatedRecoveryResolution{resolved: rv, capability: cap}, nil
}

// Snapshot returns detached originals; a zero value is not verified evidence.
func (v *ValidatedRecoveryResolution) Snapshot() (*edgev1.RecoveryResolvedV1, *edgev1.EdgeSignedCapabilityV1, error) {
	if v == nil || v.resolved == nil || v.capability == nil {
		return nil, nil, ErrRecoveryResolution
	}
	return proto.Clone(v.resolved).(*edgev1.RecoveryResolvedV1), proto.Clone(v.capability).(*edgev1.EdgeSignedCapabilityV1), nil
}
