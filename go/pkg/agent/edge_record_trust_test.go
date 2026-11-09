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

package agent

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestConfigTrustReplacementAndNotModified(t *testing.T) {
	loop := NewPushLoop(&Server{config: &ServerConfig{AgentID: "synthetic-trust-agent"}}, nil, time.Second, logger.NewTestLogger())
	document := func(status string) []byte {
		raw, err := json.Marshal(map[string]any{"keys": []any{map[string]any{
			"issuer_id": []byte("synthetic-issuer"), "issuer_key_id": []byte("synthetic-key"),
			"public_key": bytes.Repeat([]byte{0x27}, 32), "purposes": []string{"production"}, "status": status,
		}}, "scopes": []any{}, "fences": []any{}})
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	first := &proto.AgentConfigResponse{ConfigVersion: "synthetic-trust-v1", EdgeRecordTrustDocument: document("valid")}
	if !loop.applyConfigResponse(t.Context(), first, "control") {
		t.Fatal("initial configuration refused")
	}
	initial := loop.EdgeRecordTrustSnapshot()
	if initial == nil {
		t.Fatal("authenticated config did not install trust")
	}
	if !loop.applyConfigResponse(t.Context(), &proto.AgentConfigResponse{ConfigVersion: first.ConfigVersion, NotModified: true}, "poll") || loop.EdgeRecordTrustSnapshot() != initial {
		t.Fatal("not_modified discarded installed policy")
	}
	revoked := &proto.AgentConfigResponse{ConfigVersion: "synthetic-trust-v2", EdgeRecordTrustDocument: document("historically_revoked")}
	if !loop.applyConfigResponse(t.Context(), revoked, "control") {
		t.Fatal("revoked configuration refused")
	}
	next := loop.EdgeRecordTrustSnapshot()
	if next == nil || next == initial {
		t.Fatal("full config merged or retained old snapshot")
	}
	// Each policy echo uses its own local install sequence; the original decision
	// remains immutable while the next config carries compromise revocation.
	purpose := edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION
	oldKey := initial.ResolveKey([]byte("synthetic-issuer"), []byte("synthetic-key"), edgerecord.KeyEvidence{Purpose: purpose, TrustPolicyEpoch: 1})
	nextKey := next.ResolveKey([]byte("synthetic-issuer"), []byte("synthetic-key"), edgerecord.KeyEvidence{Purpose: purpose, TrustPolicyEpoch: 3})
	if oldKey.Status != edgerecord.KeyValid || nextKey.Status != edgerecord.KeyHistoricallyRevoked {
		t.Fatalf("config status lost: old=%v new=%v", oldKey.Status, nextKey.Status)
	}
	if !loop.applyConfigResponse(t.Context(), &proto.AgentConfigResponse{ConfigVersion: "synthetic-trust-unavailable"}, "control") {
		t.Fatal("unavailable policy withheld unrelated config")
	}
	if loop.EdgeRecordTrustSnapshot() != nil {
		t.Fatal("empty full config retained stale trust")
	}
}
