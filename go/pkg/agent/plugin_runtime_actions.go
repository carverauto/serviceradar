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
	"io"
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
		if err := validatePluginActionGrantAllow(grant.Allow, method, reqURL); err != nil {
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

func validatePluginActionGrantAllow(allow credentialBrokerACL, method string, reqURL *url.URL) error {
	if len(allow.Hosts) == 0 {
		return errCredentialBrokerGrantDenied
	}

	if len(allow.Methods) > 0 && !stringInFoldedList(method, allow.Methods) {
		return errCredentialBrokerGrantDenied
	}

	requestedPath := reqURL.EscapedPath()
	if requestedPath == "" {
		requestedPath = "/"
	}
	if len(allow.Paths) > 0 && !credentialBrokerPathAllowed(allow.Paths, requestedPath) {
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
	case "form_urlencoded":
		return applyCredentialBrokerFormInjection(req, grant, material)
	default:
		return errCredentialBrokerInjectionUnsupported
	}
}

func applyCredentialBrokerFormInjection(
	req *http.Request,
	grant credentialBrokerGrant,
	material CredentialBrokerMaterial,
) error {
	if !credentialBrokerFormHasExactTarget(grant.Inject) {
		return errCredentialBrokerFormInvalid
	}
	if !credentialBrokerInjectionTargetsRequest(req, grant.Inject) {
		return nil
	}
	if req.URL == nil || !strings.EqualFold(req.URL.Scheme, "https") {
		return errCredentialBrokerFormInvalid
	}
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(req.Header.Get("Content-Type"), ";")[0]))
	if contentType != "" && contentType != "application/x-www-form-urlencoded" {
		return errCredentialBrokerFormInvalid
	}

	body := []byte(nil)
	if req.Body != nil {
		read, err := io.ReadAll(io.LimitReader(req.Body, pluginMaxPayloadBytes+1))
		if err != nil || len(read) > pluginMaxPayloadBytes {
			return errCredentialBrokerFormInvalid
		}
		body = read
	}
	form, err := url.ParseQuery(string(body))
	if err != nil {
		return errCredentialBrokerFormInvalid
	}

	for key, targetField := range grant.Inject {
		if !strings.HasPrefix(key, "field_") {
			continue
		}
		sourceField := strings.TrimPrefix(key, "field_")
		targetField = strings.TrimSpace(targetField)
		if sourceField == "" || targetField == "" || form.Has(targetField) {
			return errCredentialBrokerSecretFieldPresent
		}
		value := credentialMaterialFieldValue(material, sourceField)
		if value == "" {
			return errCredentialBrokerMaterialUnavailable
		}
		form.Set(targetField, value)
	}
	for key, value := range grant.Inject {
		if strings.HasPrefix(key, "fixed_") {
			field := strings.TrimSpace(strings.TrimPrefix(key, "fixed_"))
			if field == "" {
				return errCredentialBrokerFormInvalid
			}
			form.Set(field, value)
		}
	}

	encoded := form.Encode()
	req.Body = io.NopCloser(strings.NewReader(encoded))
	req.ContentLength = int64(len(encoded))
	req.GetBody = func() (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader(encoded)), nil
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return nil
}

func credentialBrokerFormHasExactTarget(inject map[string]string) bool {
	return strings.TrimSpace(inject["method"]) != "" &&
		strings.TrimSpace(inject["host"]) != "" &&
		strings.TrimSpace(inject["path"]) != ""
}

func credentialBrokerInjectionTargetsRequest(req *http.Request, inject map[string]string) bool {
	if req == nil || req.URL == nil {
		return false
	}
	if method := strings.TrimSpace(inject["method"]); method != "" &&
		!strings.EqualFold(method, req.Method) {
		return false
	}
	if host := strings.TrimSpace(inject["host"]); host != "" &&
		!strings.EqualFold(host, req.URL.Hostname()) && !strings.EqualFold(host, req.URL.Host) {
		return false
	}
	path := req.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	if expected := strings.TrimSpace(inject["path"]); expected != "" && expected != path {
		return false
	}
	return true
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
			if value := material.Fields[candidate]; strings.TrimSpace(value) != "" {
				return value
			}
		}
	}

	return ""
}
