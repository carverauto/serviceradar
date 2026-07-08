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

package cli

import (
	"strings"
	"testing"

	"github.com/nats-io/jwt/v2"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

// bootstrapTestAccount spins up an operator + account in-memory and returns
// the account seed used to sign per-agent user credentials. Mirrors the
// runtime path used by runNatsBootstrapLocal.
func bootstrapTestAccount(t *testing.T) string {
	t.Helper()

	operator, result, err := accounts.BootstrapOperator("acl-test", "", true)
	if err != nil {
		t.Fatalf("BootstrapOperator: %v", err)
	}
	if operator == nil || result == nil {
		t.Fatal("BootstrapOperator returned nil")
	}

	signer := accounts.NewAccountSigner(operator)
	acct, err := signer.CreateAccount("platform", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}

	return acct.AccountSeed
}

func decodeUserClaims(t *testing.T, credsContent string) *jwt.UserClaims {
	t.Helper()

	const begin = "-----BEGIN NATS USER JWT-----"
	const end = "------END NATS USER JWT------"

	begIdx := strings.Index(credsContent, begin)
	endIdx := strings.Index(credsContent, end)
	if begIdx < 0 || endIdx <= begIdx {
		t.Fatalf("could not locate JWT markers in creds:\n%s", credsContent)
	}

	token := strings.TrimSpace(credsContent[begIdx+len(begin) : endIdx])
	claims, err := jwt.DecodeUserClaims(token)
	if err != nil {
		t.Fatalf("decode user JWT: %v", err)
	}
	return claims
}

func TestGenerateAgentFlowCollectorCreds_ScopedToAgentSubject(t *testing.T) {
	seed := bootstrapTestAccount(t)

	creds, err := GenerateAgentFlowCollectorCreds("platform", seed, "agent-42", 0)
	if err != nil {
		t.Fatalf("GenerateAgentFlowCollectorCreds: %v", err)
	}

	claims := decodeUserClaims(t, creds.CredsFileContent)

	pubAllow := claims.Pub.Allow
	if !containsString(pubAllow, "flow.host-slice.agent-42") {
		t.Errorf("publish allow missing flow.host-slice.agent-42: %v", pubAllow)
	}
	for _, forbidden := range []string{
		"flow.host-slice.>",
		"flow.host-slice.agent-99",
		"flow.attributed.>",
	} {
		if containsString(pubAllow, forbidden) {
			t.Errorf("publish allow must not contain %q: %v", forbidden, pubAllow)
		}
	}

	if !containsString(claims.Pub.Deny, "$SYS.>") {
		t.Errorf("publish deny must contain $SYS.>: %v", claims.Pub.Deny)
	}
	if !containsString(claims.Pub.Deny, "flow.attributed.>") {
		t.Errorf("publish deny must contain flow.attributed.>: %v", claims.Pub.Deny)
	}

	subAllow := claims.Sub.Allow
	for _, forbidden := range []string{
		"flow.host-slice.>",
		"flow.host-slice.agent-42",
		"flow.attributed.>",
	} {
		if containsString(subAllow, forbidden) {
			t.Errorf("subscribe allow must not contain %q (agents are publish-only): %v", forbidden, subAllow)
		}
	}
	if !containsString(claims.Sub.Deny, "flow.host-slice.>") {
		t.Errorf("subscribe deny must contain flow.host-slice.>: %v", claims.Sub.Deny)
	}
	if !containsString(claims.Sub.Deny, "flow.attributed.>") {
		t.Errorf("subscribe deny must contain flow.attributed.>: %v", claims.Sub.Deny)
	}
}

func TestGeneratePlatformAccount_AllowsPluginObjectStoreSubjects(t *testing.T) {
	operator, result, err := accounts.BootstrapOperator("platform-bootstrap-test", "", true)
	if err != nil {
		t.Fatalf("BootstrapOperator: %v", err)
	}
	if operator == nil || result == nil {
		t.Fatal("BootstrapOperator returned nil")
	}

	account, credsContent, err := generatePlatformAccount(
		result.OperatorSeed,
		"platform-bootstrap-test",
		defaultPlatformAccount,
		result.SystemAccountPublicKey,
		defaultPlatformUser,
	)
	if err != nil {
		t.Fatalf("generatePlatformAccount: %v", err)
	}
	if account == nil {
		t.Fatal("generatePlatformAccount returned nil account")
	}

	claims := decodeUserClaims(t, credsContent)
	for _, required := range []string{
		"$O.serviceradar_plugins.>",
		"$JS.FC.OBJ_serviceradar_plugins.>",
	} {
		if !containsString(claims.Pub.Allow, required) {
			t.Errorf("platform publish allow missing %q: %v", required, claims.Pub.Allow)
		}
	}
	if !containsString(claims.Sub.Allow, "$O.serviceradar_plugins.>") {
		t.Errorf("platform subscribe allow missing object-store read subject: %v", claims.Sub.Allow)
	}
}

func TestGenerateAgentFlowCollectorCreds_RejectsUnsafeAgentID(t *testing.T) {
	seed := bootstrapTestAccount(t)

	cases := []string{
		"",
		"agent.with.dots",
		"agent>",
		"agent*",
		"agent space",
		"agent/slash",
	}
	for _, agentID := range cases {
		_, err := GenerateAgentFlowCollectorCreds("platform", seed, agentID, 0)
		if err == nil {
			t.Errorf("expected error for unsafe agent id %q", agentID)
		}
	}
}

// TestGenerateAgentFlowCollectorCreds_CrossAgentPublishDenied is the B-5
// sub-issue 1 acceptance regression: a creds file minted for agent A
// must not contain publish authority for agent B's host-slice subject.
// We validate this by inspecting the JWT permissions exactly the way a
// NATS server does — Pub.Allow is an allowlist; any subject not in it
// is implicitly denied.
func TestGenerateAgentFlowCollectorCreds_CrossAgentPublishDenied(t *testing.T) {
	seed := bootstrapTestAccount(t)

	credsA, err := GenerateAgentFlowCollectorCreds("platform", seed, "agent-a", 0)
	if err != nil {
		t.Fatalf("GenerateAgentFlowCollectorCreds(agent-a): %v", err)
	}
	credsB, err := GenerateAgentFlowCollectorCreds("platform", seed, "agent-b", 0)
	if err != nil {
		t.Fatalf("GenerateAgentFlowCollectorCreds(agent-b): %v", err)
	}

	claimsA := decodeUserClaims(t, credsA.CredsFileContent)
	claimsB := decodeUserClaims(t, credsB.CredsFileContent)

	// agent A's allow list must scope to its own slice and nothing else.
	if !containsString(claimsA.Pub.Allow, "flow.host-slice.agent-a") {
		t.Fatalf("agent-a publish allow missing own subject: %v", claimsA.Pub.Allow)
	}
	// agent A must NOT have allowance for agent-b's slice. Anything not
	// listed is denied by NATS, so the strict assertion here matches
	// server-side behavior even without a live broker.
	for _, forbidden := range []string{
		"flow.host-slice.agent-b",
		"flow.host-slice.>",
		"flow.attributed.*",
		"flow.attributed.>",
		"flow.attributed.agent-b",
	} {
		if containsString(claimsA.Pub.Allow, forbidden) {
			t.Errorf("agent-a publish allow leaked %q: %v", forbidden, claimsA.Pub.Allow)
		}
	}

	// Symmetric: agent-b must scope only to its own slice.
	if !containsString(claimsB.Pub.Allow, "flow.host-slice.agent-b") {
		t.Fatalf("agent-b publish allow missing own subject: %v", claimsB.Pub.Allow)
	}
	if containsString(claimsB.Pub.Allow, "flow.host-slice.agent-a") {
		t.Errorf("agent-b publish allow leaked agent-a: %v", claimsB.Pub.Allow)
	}

	// And the deny list must include the wildcard fail-safe so a future
	// PublishAllow drift still cannot grant cross-agent publish.
	for _, mustDeny := range []string{"flow.attributed.>", "$SYS.>"} {
		if !containsString(claimsA.Pub.Deny, mustDeny) {
			t.Errorf("agent-a publish deny missing %q: %v", mustDeny, claimsA.Pub.Deny)
		}
		if !containsString(claimsB.Pub.Deny, mustDeny) {
			t.Errorf("agent-b publish deny missing %q: %v", mustDeny, claimsB.Pub.Deny)
		}
	}
}

func TestGeneratePartitionCoreCreds_ExcludesAttributedFlowReadback(t *testing.T) {
	seed := bootstrapTestAccount(t)

	creds, err := GeneratePartitionCoreCreds("platform", seed, "partition-A", 0)
	if err != nil {
		t.Fatalf("GeneratePartitionCoreCreds: %v", err)
	}

	claims := decodeUserClaims(t, creds.CredsFileContent)

	pubAllow := claims.Pub.Allow

	for _, required := range []string{"flow.raw.>", "logs.>", "live.logs.>", "events.>", "config.>"} {
		if !containsString(pubAllow, required) {
			t.Errorf("publish allow missing %q: %v", required, pubAllow)
		}
	}

	for _, forbidden := range []string{
		"flow.attributed.partition-A",
		"flow.attributed.partition-A.>",
		"flow.attributed.>",
		"flow.attributed.partition-B",
		"flow.attributed.partition-B.>",
	} {
		if containsString(pubAllow, forbidden) {
			t.Errorf("publish allow must not contain %q: %v", forbidden, pubAllow)
		}
	}

	// $SYS.> is reserved for the system account on every identity.
	if !containsString(claims.Pub.Deny, "$SYS.>") {
		t.Errorf("publish deny must contain $SYS.>: %v", claims.Pub.Deny)
	}

	if containsString(claims.Pub.Deny, "flow.attributed.>") {
		t.Errorf("publish deny must not contain flow.attributed.>: %v", claims.Pub.Deny)
	}

	subAllow := claims.Sub.Allow
	for _, required := range []string{"flow.raw.>", "logs.>", "events.>", "config.>"} {
		if !containsString(subAllow, required) {
			t.Errorf("subscribe allow missing %q: %v", required, subAllow)
		}
	}

	for _, forbidden := range []string{
		"flow.host-slice.>",
		"flow.attributed.partition-A",
		"flow.attributed.partition-A.>",
		"flow.attributed.>",
		"flow.attributed.partition-B",
		"flow.attributed.partition-B.>",
	} {
		if containsString(subAllow, forbidden) {
			t.Errorf("subscribe allow must not contain %q: %v", forbidden, subAllow)
		}
	}
}

func TestGeneratePartitionCoreCreds_RejectsUnsafePartitionID(t *testing.T) {
	seed := bootstrapTestAccount(t)

	cases := []string{
		"",
		"partition.with.dots",
		"partition>",
		"partition*",
		"partition space",
		"partition/slash",
		">",
	}
	for _, partitionID := range cases {
		_, err := GeneratePartitionCoreCreds("platform", seed, partitionID, 0)
		if err == nil {
			t.Errorf("expected error for unsafe partition id %q", partitionID)
		}
	}
}

func TestIsSafeSubjectToken(t *testing.T) {
	cases := []struct {
		token string
		want  bool
	}{
		{"agent-1", true},
		{"agent_1", true},
		{"AgentXYZ", true},
		{"123", true},
		{"", false},
		{"agent.with.dots", false},
		{"agent>", false},
		{"agent*", false},
		{"agent space", false},
	}
	for _, tc := range cases {
		if got := isSafeSubjectToken(tc.token); got != tc.want {
			t.Errorf("isSafeSubjectToken(%q) = %v want %v", tc.token, got, tc.want)
		}
	}
}

func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
