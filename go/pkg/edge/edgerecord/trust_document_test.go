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
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func recordTrustDocument(r *edgev1.EdgeRecordV1) trustDocument {
	producer := r.GetProducerContext()
	capability := r.GetProductionCapability()
	shard, epoch := producer.GetRunShard(), producer.GetAuthorityEpoch()
	key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x39}, ed25519.SeedSize))
	return trustDocument{
		Keys:   []trustDocumentKey{{IssuerID: capability.IssuerId, KeyID: capability.IssuerKeyId, Public: key.Public().(ed25519.PublicKey), Purposes: []string{"production", "source", "delivery"}, Status: "valid"}},
		Fences: []trustDocumentFence{{Scope: r.NetworkScopeId, Assignment: producer.ProducerAssignmentId, Shard: &shard, Epoch: &epoch}},
		Scopes: []trustDocumentScope{{AgentID: string(producer.OriginPrincipalId), Scopes: [][]byte{r.NetworkScopeId}}},
	}
}

func parseRecordTrust(t *testing.T, r *edgev1.EdgeRecordV1, doc trustDocument, epoch uint64) *TrustSnapshot {
	t.Helper()
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := ParseTrustDocument(raw, r.ProducerContext.OriginPrincipalId, epoch)
	if err != nil {
		t.Fatal(err)
	}
	// The document and input buffer are not ownership transferred to the snapshot.
	for i := range raw {
		raw[i] = 0
	}
	return snapshot
}

func TestTrustDocumentGovernsSignedAttribution(t *testing.T) {
	r := metricBatchRecord(t, 1, 1)
	raw, originalPolicy := signBindingRecord(t, r)
	cases := []struct {
		name   string
		change func(*trustDocument)
		want   error
	}{
		{"current", func(*trustDocument) {}, nil},
		{"compromise_revoked", func(d *trustDocument) { d.Keys[0].Status = "historically_revoked" }, ErrKeyHistoricallyRevoked},
		{"wrong_purpose", func(d *trustDocument) { d.Keys[0].Purposes = []string{"delivery"} }, ErrCapabilityKeyUnresolved},
		{"missing_key", func(d *trustDocument) { d.Keys[0].KeyID = []byte("different-synthetic-key") }, ErrCapabilityKeyUnresolved},
		{"missing_fence", func(d *trustDocument) { d.Fences = nil }, ErrFenceNotReady},
		{"stale_assignment", func(d *trustDocument) { *d.Fences[0].Epoch += 1 }, ErrFenceStale},
		{"different_shard", func(d *trustDocument) { *d.Fences[0].Shard += 1 }, ErrFenceNotReady},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc := recordTrustDocument(r)
			tc.change(&doc)
			snapshot := parseRecordTrust(t, r, doc, 7)
			policy, err := snapshot.PolicyFor(r, originalPolicy.NowUnixNano)
			if err != nil {
				t.Fatal(err)
			}
			_, err = RecordRecoveryAttribution(raw, r.OutputContract, policy)
			if !errors.Is(err, tc.want) {
				t.Fatalf("signed attribution: got %v want %v", err, tc.want)
			}
		})
	}
}

func TestTrustDocumentReplacementPreservesHistoricalStatusesAndSnapshot(t *testing.T) {
	r := metricBatchRecord(t, 1, 1)
	_, originalPolicy := signBindingRecord(t, r)
	doc := recordTrustDocument(r)
	old := parseRecordTrust(t, r, doc, 11)
	doc.Keys[0].Status = "historically_revoked"
	rotated := doc.Keys[0]
	rotated.KeyID = []byte("synthetic-next-key")
	rotated.Status = "valid"
	doc.Keys = append(doc.Keys, rotated)
	next := parseRecordTrust(t, r, doc, 12)
	oldPolicy, _ := old.PolicyFor(r, originalPolicy.NowUnixNano)
	nextPolicy, _ := next.PolicyFor(r, originalPolicy.NowUnixNano)
	if err := ValidateRecordSigned(r, oldPolicy); err != nil {
		t.Fatalf("later install mutated pinned decision: %v", err)
	}
	if err := ValidateRecordSigned(r, nextPolicy); !errors.Is(err, ErrKeyHistoricallyRevoked) {
		t.Fatalf("historical compromise lost: %v", err)
	}
	capability := r.ProductionCapability
	evidence := KeyEvidence{Purpose: edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, TrustPolicyEpoch: 12}
	resolved := next.ResolveKey(capability.IssuerId, capability.IssuerKeyId, evidence)
	resolved.Public[0] ^= 1
	if err := ValidateRecordSigned(r, nextPolicy); !errors.Is(err, ErrKeyHistoricallyRevoked) {
		t.Fatalf("caller mutated installed key: %v", err)
	}
	evidence.TrustPolicyEpoch = 11
	if next.ResolveKey(capability.IssuerId, capability.IssuerKeyId, evidence).Status != KeyUnavailable {
		t.Fatal("mixed snapshot epochs authorized")
	}
}

func TestTrustDocumentRefusesCrossAgentAndPartialAuthority(t *testing.T) {
	r := metricBatchRecord(t, 1, 1)
	cases := []struct {
		name   string
		change func(*trustDocument)
	}{
		{"other_agent", func(d *trustDocument) { d.Scopes[0].AgentID = "other-synthetic-agent" }},
		{"scope_outside_binding", func(d *trustDocument) { d.Fences[0].Scope = fixedUUIDv7(0x71) }},
		{"missing_epoch", func(d *trustDocument) { d.Fences[0].Epoch = nil }},
		{"missing_shard", func(d *trustDocument) { d.Fences[0].Shard = nil }},
		{"duplicate_key", func(d *trustDocument) { d.Keys = append(d.Keys, d.Keys[0]) }},
		{"duplicate_fence", func(d *trustDocument) { d.Fences = append(d.Fences, d.Fences[0]) }},
		{"oversized_fence_list", func(d *trustDocument) { d.Fences = make([]trustDocumentFence, maxTrustFences+1) }},
		{"unknown_key_status", func(d *trustDocument) { d.Keys[0].Status = "synthetic-unknown" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc := recordTrustDocument(r)
			tc.change(&doc)
			raw, err := json.Marshal(doc)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = ParseTrustDocument(raw, r.ProducerContext.OriginPrincipalId, 1); !errors.Is(err, ErrTrustDocument) {
				t.Fatalf("partial policy accepted: %v", err)
			}
		})
	}
	for _, raw := range [][]byte{nil, []byte("null"), bytes.Repeat([]byte{' '}, MaxTrustDocumentBytes+1)} {
		if _, err := ParseTrustDocument(raw, r.ProducerContext.OriginPrincipalId, 1); !errors.Is(err, ErrTrustDocument) {
			t.Fatalf("missing/oversized document accepted: %v", err)
		}
	}
}
