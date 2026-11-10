// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package edgerecord

import (
	"bytes"
	"crypto/ed25519"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func resolutionReceipt() (*edgev1.RecoveryResolvedV1, *edgev1.EdgeSignedCapabilityV1, AuthorizationPolicy) {
	id := []byte{0, 0, 0, 0, 0, 1, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 1}
	rv := &edgev1.RecoveryResolvedV1{RecoveryId: id, ManifestRootSha256: bytes.Repeat([]byte{17}, 32), AppliedThroughSequence: 10, ResolvedAtUnixNano: 1500}
	private := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{23}, ed25519.SeedSize))
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("synthetic-core"), IssuerKeyId: []byte("synthetic-key"), Algorithm: "ed25519",
		NotBeforeUnixNano: 1000, ExpiresAtUnixNano: 2000,
		Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{
			Kind:           edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
			NetworkScopeId: bytes.Repeat([]byte{31}, 16), OriginPrincipalId: []byte("synthetic-agent"),
			ContextId: bytes.Clone(id), ScopeId: bytes.Clone(id), ScopeSha256: ResolvedScopeDigest(rv),
		}},
	}
	SignCapability(cap, private)
	return rv, cap, AuthorizationPolicy{Trust: statusTrust{status: KeyValid, public: private.Public().(ed25519.PublicKey)}, NowUnixNano: 3000, TrustPolicyEpoch: 1}
}

func TestHistoricalRecoveryResolutionRetainsImmutableEvidence(t *testing.T) {
	rv, cap, policy := resolutionReceipt()
	verified, err := ValidateRecoveryResolution(rv, cap, cap.GetSource().NetworkScopeId, cap.GetSource().OriginPrincipalId, policy)
	if err != nil {
		t.Fatal(err)
	}
	// The production window has elapsed. This remains evidence of a historical
	// consumer commit, while every returned value is detached from caller memory.
	rv.AppliedThroughSequence = 99
	cap.GetSource().OriginPrincipalId[0] = 'x'
	first, proof, err := verified.Snapshot()
	if err != nil || first.AppliedThroughSequence != 10 || string(proof.GetSource().OriginPrincipalId) != "synthetic-agent" {
		t.Fatalf("receipt changed: %v %v", first, err)
	}
	first.ManifestRootSha256[0] = 99
	second, _, err := verified.Snapshot()
	if err != nil || second.ManifestRootSha256[0] != 17 {
		t.Fatal("snapshot aliases verified evidence")
	}
	if _, _, err := new(ValidatedRecoveryResolution).Snapshot(); err == nil {
		t.Fatal("zero value acquired completion authority")
	}
}

func TestRecoveryResolutionCannotSubstituteStateOrNamespace(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*edgev1.RecoveryResolvedV1, *edgev1.EdgeSignedCapabilityV1, *AuthorizationPolicy, *[]byte, *[]byte)
	}{
		{"prefix", func(r *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, _, _ *[]byte) {
			r.AppliedThroughSequence++
		}},
		{"root", func(r *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, _, _ *[]byte) {
			r.ManifestRootSha256[0]++
		}},
		{"recovery", func(r *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, _, _ *[]byte) {
			r.RecoveryId[15]++
		}},
		{"scope", func(_ *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, s, _ *[]byte) {
			(*s)[0]++
		}},
		{"agent", func(_ *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, _, a *[]byte) {
			*a = []byte("different-agent")
		}},
		{"signature", func(_ *edgev1.RecoveryResolvedV1, c *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, _, _ *[]byte) {
			c.Signature[0]++
		}},
		{"unknown body", func(r *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, _ *AuthorizationPolicy, _, _ *[]byte) {
			r.ProtoReflect().SetUnknown([]byte{0xa0, 0x06, 1})
		}},
		{"compromised", func(_ *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, p *AuthorizationPolicy, _, _ *[]byte) {
			tr := p.Trust.(statusTrust)
			tr.status = KeyHistoricallyRevoked
			p.Trust = tr
		}},
		{"unavailable", func(_ *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSignedCapabilityV1, p *AuthorizationPolicy, _, _ *[]byte) {
			p.Trust = statusTrust{status: KeyUnavailable}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rv, cap, policy := resolutionReceipt()
			scope, agent := bytes.Clone(cap.GetSource().NetworkScopeId), bytes.Clone(cap.GetSource().OriginPrincipalId)
			tc.change(rv, cap, &policy, &scope, &agent)
			if _, err := ValidateRecoveryResolution(rv, cap, scope, agent, policy); err == nil {
				t.Fatal("substitution authorized journal release")
			}
		})
	}
	// Timestamp is intentionally outside the frozen scope digest. It is retained
	// from the issuer, but changing it alone cannot assert different applied state.
	rv, cap, policy := resolutionReceipt()
	changed := proto.Clone(rv).(*edgev1.RecoveryResolvedV1)
	changed.ResolvedAtUnixNano++
	if _, err := ValidateRecoveryResolution(changed, cap, cap.GetSource().NetworkScopeId, cap.GetSource().OriginPrincipalId, policy); err != nil {
		t.Fatal(err)
	}
}
