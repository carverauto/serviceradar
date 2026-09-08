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

package addon

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCredentialBrokerRequestBodyPolicyRoundTrip(t *testing.T) {
	t.Parallel()

	grant := CredentialBrokerGrant{
		Schema: CredentialBrokerGrantSchemaV2,
		Allow: CredentialBrokerACL{
			RequestBody: CredentialBrokerRequestBodyPolicy{
				Mode:         CredentialBrokerRequestBodyModeBoundBytes,
				SHA256:       strings.Repeat("a", 64),
				Source:       CredentialBrokerBoundBodySource,
				ContentType:  "application/json",
				MaxBytes:     262144,
				MaxMutations: 1,
			},
		},
	}

	encoded, err := json.Marshal(grant)
	if err != nil {
		t.Fatalf("marshal grant: %v", err)
	}

	var decoded CredentialBrokerGrant
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("unmarshal grant: %v", err)
	}
	if decoded.Allow.RequestBody != grant.Allow.RequestBody {
		t.Fatalf("request body policy = %#v, want %#v", decoded.Allow.RequestBody, grant.Allow.RequestBody)
	}
}

func TestCredentialBrokerRequestBodyPolicyRejectsUnknownFields(t *testing.T) {
	t.Parallel()

	var grant CredentialBrokerGrant
	err := json.Unmarshal([]byte(`{
		"schema":"serviceradar.edge_credential_broker_grant.v2",
		"allow":{"request_body":{"mode":"empty","max_mutations":1,"canonicalize":true}}
	}`), &grant)
	if err == nil {
		t.Fatal("unmarshal grant succeeded with unknown request-body policy field")
	}
}
