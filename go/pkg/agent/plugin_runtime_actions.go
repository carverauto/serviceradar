/*
 * Copyright 2025 Carver Automation Corporation.
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
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func buildActionPluginConfig(baseConfig []byte, invocationPayload json.RawMessage) ([]byte, error) {
	var actionPayload any = map[string]any{}
	if len(bytes.TrimSpace(invocationPayload)) > 0 {
		if err := json.Unmarshal(invocationPayload, &actionPayload); err != nil {
			return nil, fmt.Errorf("decode action payload: %w", err)
		}
	}

	config := map[string]any{
		"action_invocation": actionPayload,
	}

	if len(bytes.TrimSpace(baseConfig)) == 0 {
		return json.Marshal(config)
	}

	var base map[string]any
	if err := json.Unmarshal(baseConfig, &base); err == nil {
		for key, value := range base {
			if key == "action_invocation" {
				config["plugin_config"] = map[string]any{"action_invocation": value}
				continue
			}
			config[key] = value
		}
		return json.Marshal(config)
	}

	config["plugin_config_base64"] = base64.StdEncoding.EncodeToString(baseConfig)
	return json.Marshal(config)
}

func pluginActionCredentialGrants(invocationPayload json.RawMessage) ([]credentialBrokerGrant, error) {
	if len(bytes.TrimSpace(invocationPayload)) == 0 {
		return nil, nil
	}

	var payload struct {
		CredentialBroker  *credentialBrokerGrant  `json:"credential_broker"`
		CredentialBrokers []credentialBrokerGrant `json:"credential_brokers"`
	}
	if err := json.Unmarshal(invocationPayload, &payload); err != nil {
		return nil, fmt.Errorf("decode action credential grants: %w", err)
	}

	grants := make([]credentialBrokerGrant, 0, len(payload.CredentialBrokers)+1)
	if payload.CredentialBroker != nil {
		grants = append(grants, *payload.CredentialBroker)
	}
	grants = append(grants, payload.CredentialBrokers...)
	if len(grants) == 0 {
		return nil, nil
	}

	normalized := make([]credentialBrokerGrant, 0, len(grants))
	seen := make(map[string]struct{}, len(grants))
	for _, grant := range grants {
		key := strings.TrimSpace(grant.GrantID)
		if key == "" {
			key = strings.TrimSpace(grant.CredentialSecretRef)
		}
		if key != "" {
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
		}
		normalized = append(normalized, grant)
	}

	return normalized, nil
}

func pluginActionGrantForHTTPRequest(
	grants []credentialBrokerGrant,
	method string,
	reqURL *url.URL,
	now time.Time,
) (*credentialBrokerGrant, error) {
	if len(grants) == 0 {
		return nil, nil
	}
	if reqURL == nil || reqURL.Host == "" {
		return nil, errInvalidCredentialBrokerGrant
	}

	lastErr := errCredentialBrokerGrantDenied
	for i := range grants {
		grant := &grants[i]
		if err := validatePluginActionCredentialGrantEnvelope(*grant, now); err != nil {
			lastErr = err
			continue
		}
		if err := validatePluginActionGrantAllow(*grant, method, reqURL); err != nil {
			lastErr = err
			continue
		}
		return grant, nil
	}

	return nil, lastErr
}

func validatePluginActionCredentialGrantEnvelope(grant credentialBrokerGrant, now time.Time) error {
	if strings.TrimSpace(grant.CredentialSecretRef) == "" {
		return errInvalidCredentialBrokerGrant
	}
	if grant.Schema != "" && grant.Schema != "serviceradar.edge_credential_broker_grant.v1" {
		return errInvalidCredentialBrokerGrant
	}
	if grant.TTLSeconds < 0 {
		return errInvalidCredentialBrokerGrant
	}
	if strings.TrimSpace(grant.ExpiresAt) == "" {
		return nil
	}

	expiresAt, err := time.Parse(time.RFC3339, strings.TrimSpace(grant.ExpiresAt))
	if err != nil {
		return errInvalidCredentialBrokerGrant
	}
	if !now.Before(expiresAt) {
		return errCredentialBrokerGrantExpired
	}

	return nil
}

func validatePluginActionGrantAllow(grant credentialBrokerGrant, method string, reqURL *url.URL) error {
	allow := grant.Allow
	if len(allow.Hosts) == 0 {
		return errCredentialBrokerGrantDenied
	}

	strictAWXScope := strings.EqualFold(strings.TrimSpace(grant.GrantType), "awx_oauth2_token")
	// AWX grants are issued by a closed verb registry and must always carry an
	// exact HTTP scope. Other legacy plugin grants still use host-only ACLs;
	// tightening those requires per-integration migration instead of silently
	// breaking Proxmox console or UniFi camera traffic here.
	if (strictAWXScope && len(allow.Methods) == 0) ||
		(len(allow.Methods) > 0 && !stringInFoldedList(method, allow.Methods)) {
		return errCredentialBrokerGrantDenied
	}

	requestedPath := reqURL.EscapedPath()
	if requestedPath == "" {
		requestedPath = "/"
	}
	if (strictAWXScope && len(allow.Paths) == 0) ||
		(len(allow.Paths) > 0 && !credentialBrokerPathAllowed(allow.Paths, requestedPath)) {
		return errCredentialBrokerGrantDenied
	}

	if len(allow.Hosts) > 0 {
		host := reqURL.Hostname()
		if !stringInFoldedList(host, allow.Hosts) && !stringInFoldedList(reqURL.Host, allow.Hosts) {
			return errCredentialBrokerGrantDenied
		}
	}

	if len(allow.Ports) > 0 {
		port := portForURL(reqURL)
		if port == 0 || !intInList(port, allow.Ports) {
			return errCredentialBrokerGrantDenied
		}
	}

	return nil
}

func credentialBrokerPathAllowed(patterns []string, requested string) bool {
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		switch {
		case pattern == "":
			continue
		case strings.HasPrefix(pattern, "=") && strings.TrimPrefix(pattern, "=") == requested:
			return true
		case pattern == requested:
			return true
		case strings.HasSuffix(pattern, "*") && strings.HasPrefix(requested, strings.TrimSuffix(pattern, "*")):
			return true
		case strings.HasSuffix(pattern, "/") && strings.HasPrefix(requested, pattern):
			return true
		}
	}

	return false
}

func applyCredentialBrokerHTTPInjection(
	req *http.Request,
	grant credentialBrokerGrant,
	material CredentialBrokerMaterial,
) error {
	if req == nil {
		return errCredentialBrokerInjectionUnsupported
	}

	injectType := strings.ToLower(strings.TrimSpace(grant.Inject["type"]))
	if injectType == "" {
		return nil
	}

	switch injectType {
	case "http_header", "header":
		return applyCredentialBrokerHeaderInjection(req, grant, material)
	case "bearer_token":
		inject := map[string]string{
			"type":   "http_header",
			"name":   firstNonEmptyString(grant.Inject["name"], "Authorization"),
			"scheme": firstNonEmptyString(grant.Inject["scheme"], "Bearer"),
		}
		grant.Inject = inject
		return applyCredentialBrokerHeaderInjection(req, grant, material)
	case "basic_auth", "http_basic_auth":
		username := credentialMaterialFieldValue(material, "username", "user")
		password := credentialMaterialFieldValue(material, "password")
		if strings.TrimSpace(username) == "" || password == "" {
			return errCredentialBrokerMaterialUnavailable
		}
		req.SetBasicAuth(username, password)
		return nil
	case "query", "query_param", "http_query":
		name := strings.TrimSpace(grant.Inject["name"])
		value := credentialMaterialValue(material, "value", name)
		if name == "" || value == "" {
			return errCredentialBrokerMaterialUnavailable
		}
		query := req.URL.Query()
		query.Set(name, value)
		req.URL.RawQuery = query.Encode()
		return nil
	default:
		return errCredentialBrokerInjectionUnsupported
	}
}

func applyCredentialBrokerHeaderInjection(
	req *http.Request,
	grant credentialBrokerGrant,
	material CredentialBrokerMaterial,
) error {
	name := strings.TrimSpace(grant.Inject["name"])
	if name == "" {
		return errCredentialBrokerMaterialUnavailable
	}

	value := credentialMaterialValue(material, "value", name)
	if value == "" {
		return errCredentialBrokerMaterialUnavailable
	}

	if scheme := strings.TrimSpace(grant.Inject["scheme"]); scheme != "" {
		value = scheme + " " + value
	}

	req.Header.Set(name, value)
	return nil
}

func credentialMaterialValue(material CredentialBrokerMaterial, keys ...string) string {
	for _, key := range keys {
		if material.Fields == nil {
			continue
		}
		for _, candidate := range []string{key, strings.ToLower(key), strings.ToUpper(key)} {
			if value := strings.TrimSpace(material.Fields[candidate]); value != "" {
				return value
			}
		}
	}

	return strings.TrimSpace(material.Value)
}

func credentialMaterialFieldValue(material CredentialBrokerMaterial, keys ...string) string {
	for _, key := range keys {
		if material.Fields == nil {
			continue
		}
		for _, candidate := range []string{key, strings.ToLower(key), strings.ToUpper(key)} {
			if value := strings.TrimSpace(material.Fields[candidate]); value != "" {
				return value
			}
		}
	}

	return ""
}
