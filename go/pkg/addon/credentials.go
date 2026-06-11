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
	"strings"
	"time"
)

const CredentialConfigKey = "_serviceradar"

// CredentialBrokerGrant is the runtime-neutral grant shape used by Wasm plugins
// and native add-ons when requesting gateway-mediated credential resolution.
type CredentialBrokerGrant struct {
	Schema              string                      `json:"schema,omitempty"`
	GrantID             string                      `json:"grant_id,omitempty"`
	GrantType           string                      `json:"grant_type,omitempty"`
	CredentialRuleID    string                      `json:"credential_rule_id,omitempty"`
	CredentialSecretRef string                      `json:"credential_secret_ref,omitempty"`
	Consumer            map[string]string           `json:"consumer,omitempty"`
	Target              CredentialBrokerTarget      `json:"target,omitempty"`
	ResolutionLocation  string                      `json:"resolution_location,omitempty"`
	Inject              map[string]string           `json:"inject,omitempty"`
	Cache               CredentialBrokerCachePolicy `json:"cache,omitempty"`
	Allow               CredentialBrokerACL         `json:"allow,omitempty"`
	TTLSeconds          int                         `json:"ttl_seconds,omitempty"`
	ExpiresAt           string                      `json:"expires_at,omitempty"`
}

type CredentialBrokerTarget struct {
	Kind      string `json:"kind,omitempty"`
	ID        string `json:"id,omitempty"`
	AgentID   string `json:"agent_id,omitempty"`
	DeviceUID string `json:"device_uid,omitempty"`
	BaseURL   string `json:"base_url,omitempty"`
	Hostname  string `json:"hostname,omitempty"`
	IP        string `json:"ip,omitempty"`
}

type CredentialBrokerACL struct {
	Methods []string `json:"methods,omitempty"`
	Paths   []string `json:"paths,omitempty"`
	Hosts   []string `json:"hosts,omitempty"`
	Ports   []int    `json:"ports,omitempty"`
}

type CredentialBrokerCachePolicy struct {
	Mode       string `json:"mode,omitempty"`
	TTLSeconds int    `json:"ttl_seconds,omitempty"`
}

// CredentialBrokerMaterial is resolved by the agent through agent-gateway. It
// is injected into native add-on Configure payloads only when the assignment
// explicitly carries credential broker grants.
type CredentialBrokerMaterial struct {
	Value          string
	Fields         map[string]string
	LeaseExpiresAt time.Time
}

type CredentialResolver interface {
	ResolveCredentialGrant(context.Context, CredentialBrokerGrant) (CredentialBrokerMaterial, error)
}

type CredentialMaterial struct {
	GrantID             string            `json:"grant_id,omitempty"`
	CredentialSecretRef string            `json:"credential_secret_ref,omitempty"`
	Value               string            `json:"value,omitempty"`
	Fields              map[string]string `json:"fields,omitempty"`
	LeaseExpiresAtUnix  int64             `json:"lease_expires_at_unix,omitempty"`
}

type CredentialBundle struct {
	Credentials []CredentialMaterial `json:"credentials,omitempty"`
}

// CredentialBundleFromConfig extracts agent-injected native add-on credentials
// from the reserved ServiceRadar config block.
func CredentialBundleFromConfig(configJSON []byte) (CredentialBundle, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(configJSON, &root); err != nil {
		return CredentialBundle{}, err
	}

	rawServiceRadar, ok := root[CredentialConfigKey]
	if !ok || len(rawServiceRadar) == 0 {
		return CredentialBundle{}, nil
	}

	var serviceRadar struct {
		Credentials []CredentialMaterial `json:"credentials,omitempty"`
	}
	if err := json.Unmarshal(rawServiceRadar, &serviceRadar); err != nil {
		return CredentialBundle{}, err
	}

	return CredentialBundle{Credentials: serviceRadar.Credentials}, nil
}

func (b CredentialBundle) Find(identifier string) (CredentialMaterial, bool) {
	identifier = strings.TrimSpace(identifier)
	if identifier == "" {
		return CredentialMaterial{}, false
	}

	for _, credential := range b.Credentials {
		if strings.TrimSpace(credential.GrantID) == identifier ||
			strings.TrimSpace(credential.CredentialSecretRef) == identifier {
			return credential, true
		}
	}

	return CredentialMaterial{}, false
}
