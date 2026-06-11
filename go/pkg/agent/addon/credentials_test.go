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
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

func TestInjectCredentialMaterials(t *testing.T) {
	expiresAt := time.Unix(1781140000, 0).UTC()
	resolver := &fakeCredentialResolver{
		material: coreaddon.CredentialBrokerMaterial{
			Value:          "token-value",
			Fields:         map[string]string{"username": "alice", "password": "secret"},
			LeaseExpiresAt: expiresAt,
		},
	}

	config, err := injectCredentialMaterials(t.Context(), []byte(`{
		"collector": {"interval": "1h"},
		"credential_broker": {
			"grant_id": "grant-1",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-1"
		},
		"_serviceradar": {
			"existing": true
		}
	}`), resolver)
	if err != nil {
		t.Fatalf("injectCredentialMaterials returned error: %v", err)
	}

	var root struct {
		Collector struct {
			Interval string `json:"interval"`
		} `json:"collector"`
		ServiceRadar struct {
			Existing    bool                           `json:"existing"`
			Credentials []coreaddon.CredentialMaterial `json:"credentials"`
		} `json:"_serviceradar"`
	}
	if err := json.Unmarshal(config, &root); err != nil {
		t.Fatalf("injected config is invalid JSON: %v", err)
	}

	if root.Collector.Interval != "1h" || !root.ServiceRadar.Existing {
		t.Fatalf("config fields were not preserved: %s", string(config))
	}
	if len(root.ServiceRadar.Credentials) != 1 {
		t.Fatalf("credentials = %#v", root.ServiceRadar.Credentials)
	}

	credential := root.ServiceRadar.Credentials[0]
	if credential.GrantID != "grant-1" ||
		credential.CredentialSecretRef != "credentialref:network-credential-secret:secret-1" ||
		credential.Value != "token-value" ||
		credential.Fields["username"] != "alice" ||
		credential.LeaseExpiresAtUnix != expiresAt.Unix() {
		t.Fatalf("credential = %#v", credential)
	}

	if len(resolver.grants) != 1 || resolver.grants[0].GrantID != "grant-1" {
		t.Fatalf("resolved grants = %#v", resolver.grants)
	}
}

func TestInjectCredentialMaterialsRequiresResolver(t *testing.T) {
	_, err := injectCredentialMaterials(t.Context(), []byte(`{
		"credential_broker": {
			"grant_id": "grant-1",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-1"
		}
	}`), nil)
	if !errors.Is(err, ErrCredentialResolverUnavailable) {
		t.Fatalf("error = %v, want %v", err, ErrCredentialResolverUnavailable)
	}
}

func TestInjectCredentialMaterialsRejectsInvalidConfigRoot(t *testing.T) {
	_, err := injectCredentialMaterials(t.Context(), []byte(`[]`), &fakeCredentialResolver{})
	if !errors.Is(err, ErrInvalidConfig) {
		t.Fatalf("error = %v, want %v", err, ErrInvalidConfig)
	}
}

func TestInjectCredentialMaterialsRejectsInvalidServiceRadarBlock(t *testing.T) {
	_, err := injectCredentialMaterials(t.Context(), []byte(`{
		"_serviceradar": "bad",
		"credential_broker": {
			"grant_id": "grant-1",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-1"
		}
	}`), &fakeCredentialResolver{})
	if !errors.Is(err, ErrInvalidConfig) {
		t.Fatalf("error = %v, want %v", err, ErrInvalidConfig)
	}
}

func TestInjectCredentialMaterialsWithoutGrantsReturnsOriginalConfig(t *testing.T) {
	config := []byte(`{"collector":{"interval":"1h"}}`)
	got, err := injectCredentialMaterials(t.Context(), config, nil)
	if err != nil {
		t.Fatalf("injectCredentialMaterials returned error: %v", err)
	}
	if string(got) != string(config) {
		t.Fatalf("config = %s, want %s", string(got), string(config))
	}
}

type fakeCredentialResolver struct {
	material coreaddon.CredentialBrokerMaterial
	err      error
	grants   []coreaddon.CredentialBrokerGrant
}

func (f *fakeCredentialResolver) ResolveCredentialGrant(
	_ context.Context,
	grant coreaddon.CredentialBrokerGrant,
) (coreaddon.CredentialBrokerMaterial, error) {
	f.grants = append(f.grants, grant)
	if f.err != nil {
		return coreaddon.CredentialBrokerMaterial{}, f.err
	}

	return f.material, nil
}
