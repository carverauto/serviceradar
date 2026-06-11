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
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

type credentialBrokerEnvelope struct {
	CredentialBroker  *coreaddon.CredentialBrokerGrant  `json:"credential_broker,omitempty"`
	CredentialBrokers []coreaddon.CredentialBrokerGrant `json:"credential_brokers,omitempty"`
}

func injectCredentialMaterials(
	ctx context.Context,
	configJSON []byte,
	resolver coreaddon.CredentialResolver,
) ([]byte, error) {
	root, grants, err := parseCredentialBrokerConfig(configJSON)
	if err != nil {
		return nil, err
	}
	if len(grants) == 0 {
		return normalizedConfigJSON(configJSON)
	}
	if resolver == nil {
		return nil, ErrCredentialResolverUnavailable
	}

	materials := make([]coreaddon.CredentialMaterial, 0, len(grants))
	for _, grant := range grants {
		material, err := resolver.ResolveCredentialGrant(ctx, grant)
		if err != nil {
			return nil, fmt.Errorf("resolve addon credential grant %q: %w", strings.TrimSpace(grant.GrantID), err)
		}

		credential := coreaddon.CredentialMaterial{
			GrantID:             strings.TrimSpace(grant.GrantID),
			CredentialSecretRef: strings.TrimSpace(grant.CredentialSecretRef),
			Value:               material.Value,
			Fields:              cloneStringMap(material.Fields),
		}
		if !material.LeaseExpiresAt.IsZero() {
			credential.LeaseExpiresAtUnix = material.LeaseExpiresAt.UTC().Unix()
		}

		materials = append(materials, credential)
	}

	serviceRadarBlock, err := parseServiceRadarConfigBlock(root[coreaddon.CredentialConfigKey])
	if err != nil {
		return nil, err
	}
	encodedCredentials, err := json.Marshal(materials)
	if err != nil {
		return nil, err
	}
	serviceRadarBlock["credentials"] = encodedCredentials

	encodedBlock, err := json.Marshal(serviceRadarBlock)
	if err != nil {
		return nil, err
	}
	root[coreaddon.CredentialConfigKey] = encodedBlock

	encoded, err := json.Marshal(root)
	if err != nil {
		return nil, err
	}

	return encoded, nil
}

func parseCredentialBrokerConfig(configJSON []byte) (map[string]json.RawMessage, []coreaddon.CredentialBrokerGrant, error) {
	normalized := bytes.TrimSpace(configJSON)
	if len(normalized) == 0 {
		normalized = []byte("{}")
	}

	var root map[string]json.RawMessage
	if err := json.Unmarshal(normalized, &root); err != nil {
		return nil, nil, fmt.Errorf("%w: %w", ErrInvalidConfig, err)
	}
	if root == nil {
		return nil, nil, fmt.Errorf("%w: config root must be a JSON object", ErrInvalidConfig)
	}

	var envelope credentialBrokerEnvelope
	if err := json.Unmarshal(normalized, &envelope); err != nil {
		return nil, nil, fmt.Errorf("%w: %w", ErrInvalidConfig, err)
	}

	grants := make([]coreaddon.CredentialBrokerGrant, 0, len(envelope.CredentialBrokers)+1)
	if envelope.CredentialBroker != nil {
		grants = append(grants, *envelope.CredentialBroker)
	}
	grants = append(grants, envelope.CredentialBrokers...)

	return root, compactCredentialBrokerGrants(grants), nil
}

func compactCredentialBrokerGrants(grants []coreaddon.CredentialBrokerGrant) []coreaddon.CredentialBrokerGrant {
	if len(grants) == 0 {
		return nil
	}

	compacted := make([]coreaddon.CredentialBrokerGrant, 0, len(grants))
	for _, grant := range grants {
		if strings.TrimSpace(grant.GrantID) == "" && strings.TrimSpace(grant.CredentialSecretRef) == "" {
			continue
		}
		compacted = append(compacted, grant)
	}

	return compacted
}

func parseServiceRadarConfigBlock(raw json.RawMessage) (map[string]json.RawMessage, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return make(map[string]json.RawMessage), nil
	}

	var block map[string]json.RawMessage
	if err := json.Unmarshal(raw, &block); err != nil {
		return nil, fmt.Errorf("%w: _serviceradar must be a JSON object", ErrInvalidConfig)
	}
	if block == nil {
		return nil, fmt.Errorf("%w: _serviceradar must be a JSON object", ErrInvalidConfig)
	}

	return block, nil
}

func normalizedConfigJSON(configJSON []byte) ([]byte, error) {
	normalized := bytes.TrimSpace(configJSON)
	if len(normalized) == 0 {
		return []byte("{}"), nil
	}

	return configJSON, nil
}
