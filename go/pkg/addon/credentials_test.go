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

import "testing"

func TestCredentialBundleFromConfig(t *testing.T) {
	bundle, err := CredentialBundleFromConfig([]byte(`{
		"_serviceradar": {
			"credentials": [{
				"grant_id": "grant-1",
				"credential_secret_ref": "credentialref:network-credential-secret:secret-1",
				"value": "token",
				"fields": {"username": "alice"},
				"lease_expires_at_unix": 1781140000
			}]
		}
	}`))
	if err != nil {
		t.Fatalf("CredentialBundleFromConfig returned error: %v", err)
	}

	credential, ok := bundle.Find("grant-1")
	if !ok {
		t.Fatal("credential not found by grant id")
	}
	if credential.Value != "token" || credential.Fields["username"] != "alice" {
		t.Fatalf("credential = %#v", credential)
	}

	credential, ok = bundle.Find("credentialref:network-credential-secret:secret-1")
	if !ok || credential.GrantID != "grant-1" {
		t.Fatalf("credential not found by secret ref: %#v", credential)
	}
}
