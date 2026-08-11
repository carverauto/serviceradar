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
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

const maxCredentialBrokerMutations = 16

func buildActionPluginConfig(baseConfig []byte, invocationPayload json.RawMessage) ([]byte, error) {
	if _, isNotification := decodeNotificationDelivery(invocationPayload); isNotification {
		return buildNotificationPluginConfig(baseConfig, invocationPayload)
	}

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

// buildNotificationPluginConfig adapts the control-plane command envelope to
// the notifier SDK host ABI. Credential grants and command-addressing fields
// remain host-only; the guest sees the typed delivery request plus its ordinary
// assignment configuration.
func buildNotificationPluginConfig(baseConfig []byte, invocationPayload json.RawMessage) ([]byte, error) {
	var delivery map[string]any
	if err := json.Unmarshal(invocationPayload, &delivery); err != nil {
		return nil, fmt.Errorf("decode notification payload: %w", err)
	}
	if delivery == nil {
		return nil, fmt.Errorf("%w: expected a JSON object", errNotificationDeliveryInvalid)
	}

	delete(delivery, "credential_broker")
	delete(delivery, "credential_brokers")
	delete(delivery, "plugin_assignment_id")
	delete(delivery, "plugin_package_id")
	delete(delivery, "action_key")
	delete(delivery, "entrypoint")
	delivery["schema"] = notificationDeliveryRequestSchema

	// Accept commands from the first implementation while core and agent roll
	// independently. The request ABI calls this field rendered_payload.
	if _, ok := delivery["rendered_payload"]; !ok {
		if payload, exists := delivery["payload"]; exists {
			delivery["rendered_payload"] = payload
		}
	}
	delete(delivery, "payload")

	config := map[string]any{
		notificationDeliveryConfigKey: delivery,
	}

	if len(bytes.TrimSpace(baseConfig)) == 0 {
		return json.Marshal(config)
	}

	var base map[string]any
	if err := json.Unmarshal(baseConfig, &base); err == nil {
		for key, value := range base {
			if key == notificationDeliveryConfigKey {
				config["plugin_config"] = map[string]any{notificationDeliveryConfigKey: value}
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

// pluginActionGrantForHTTPRequestIntent selects the one authority a guest
// explicitly requested. Notification grants are never ambient: without an
// intent they are ignored, and an ambiguous intent is denied instead of
// injecting whichever secret happens to be first in the command payload.
// Non-notification grants retain the legacy host-match behavior for existing
// action integrations whose ABI predates credential_injection.
func pluginActionGrantForHTTPRequestIntent(
	grants []credentialBrokerGrant,
	method string,
	reqURL *url.URL,
	now time.Time,
	intent *credentialInjectionIntent,
) (*credentialBrokerGrant, error) {
	if intent == nil {
		legacy := make([]credentialBrokerGrant, 0, len(grants))
		for i := range grants {
			if !strings.EqualFold(strings.TrimSpace(grants[i].GrantType), "notification_credential") {
				legacy = append(legacy, grants[i])
			}
		}
		return pluginActionGrantForHTTPRequest(legacy, method, reqURL, now)
	}

	if !validCredentialInjectionIntent(intent) {
		return nil, errCredentialBrokerGrantDenied
	}

	matches := make([]*credentialBrokerGrant, 0, 1)
	lastErr := errCredentialBrokerGrantDenied
	for i := range grants {
		grant := &grants[i]
		if !credentialInjectionIntentMatchesGrant(intent, grant) {
			continue
		}
		if err := validatePluginActionCredentialGrantEnvelope(*grant, now); err != nil {
			lastErr = err
			continue
		}
		if err := validatePluginActionGrantAllow(*grant, method, reqURL); err != nil {
			lastErr = err
			continue
		}
		matches = append(matches, grant)
	}

	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) > 1 {
		return nil, errCredentialBrokerGrantDenied
	}
	return nil, lastErr
}

func validCredentialInjectionIntent(intent *credentialInjectionIntent) bool {
	if intent == nil {
		return false
	}
	mode := strings.ToLower(strings.TrimSpace(intent.Mode))
	_, ok := notificationCredentialInjectionModes[mode]
	return ok
}

func credentialInjectionIntentMatchesGrant(
	intent *credentialInjectionIntent,
	grant *credentialBrokerGrant,
) bool {
	if intent == nil || grant == nil {
		return false
	}
	if selected := strings.TrimSpace(intent.GrantID); selected != "" &&
		selected != strings.TrimSpace(grant.GrantID) {
		return false
	}
	if selected := strings.TrimSpace(intent.CredentialSecretRef); selected != "" &&
		selected != strings.TrimSpace(grant.CredentialSecretRef) {
		return false
	}
	if !strings.EqualFold(strings.TrimSpace(intent.Mode), strings.TrimSpace(grant.Inject["type"])) {
		return false
	}
	if selected := strings.TrimSpace(intent.Name); selected != "" &&
		!strings.EqualFold(selected, strings.TrimSpace(grant.Inject["name"])) {
		return false
	}
	if selected := strings.TrimSpace(intent.Scheme); selected != "" &&
		!strings.EqualFold(selected, strings.TrimSpace(grant.Inject["scheme"])) {
		return false
	}
	return true
}

func validatePluginActionCredentialGrantEnvelope(grant credentialBrokerGrant, now time.Time) error {
	if strings.TrimSpace(grant.CredentialSecretRef) == "" {
		return errInvalidCredentialBrokerGrant
	}
	schema := strings.TrimSpace(grant.Schema)
	switch schema {
	case "", coreaddon.CredentialBrokerGrantSchemaV1:
		if !credentialBrokerRequestBodyPolicyEmpty(grant.Allow.RequestBody) {
			return errInvalidCredentialBrokerGrant
		}
	case coreaddon.CredentialBrokerGrantSchemaV2:
		if strings.TrimSpace(grant.GrantID) == "" ||
			validateCredentialBrokerRequestBodyPolicy(grant.Allow.RequestBody) != nil {
			return errInvalidCredentialBrokerGrant
		}
	default:
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
	requestedScheme := strings.ToLower(strings.TrimSpace(reqURL.Scheme))
	if (strictAWXScope && len(allow.Schemes) == 0) ||
		(len(allow.Schemes) > 0 && !stringInFoldedList(requestedScheme, allow.Schemes)) {
		return errCredentialBrokerGrantDenied
	}
	if strictAWXScope && !credentialBrokerHTTPMethodSafe(method) &&
		strings.TrimSpace(grant.Schema) != coreaddon.CredentialBrokerGrantSchemaV2 {
		return errCredentialBrokerGrantDenied
	}
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

func validateCredentialBrokerRequestBodyPolicy(policy coreaddon.CredentialBrokerRequestBodyPolicy) error {
	mode := strings.TrimSpace(policy.Mode)
	if policy.MaxMutations < 1 || policy.MaxMutations > maxCredentialBrokerMutations {
		return errInvalidCredentialBrokerGrant
	}
	if policy.ContentType != "" && !validCredentialBrokerContentType(policy.ContentType) {
		return errInvalidCredentialBrokerGrant
	}

	switch mode {
	case coreaddon.CredentialBrokerRequestBodyModeEmpty:
		if policy.SHA256 != "" || policy.Source != "" || policy.MaxBytes != 0 || policy.Handler != "" {
			return errInvalidCredentialBrokerGrant
		}
	case coreaddon.CredentialBrokerRequestBodyModeBoundBytes:
		if !validCredentialBrokerSHA256(policy.SHA256) ||
			policy.Source != coreaddon.CredentialBrokerBoundBodySource ||
			policy.ContentType == "" || policy.MaxBytes < 1 ||
			policy.MaxBytes > pluginMaxPayloadBytes || policy.Handler != "" {
			return errInvalidCredentialBrokerGrant
		}
	case coreaddon.CredentialBrokerRequestBodyModeTrustedRewrite:
		if policy.Handler != coreaddon.CredentialBrokerAWXCallbackBodyHandler ||
			policy.ContentType == "" || policy.MaxBytes < 1 ||
			policy.MaxBytes > pluginMaxPayloadBytes || policy.SHA256 != "" || policy.Source != "" {
			return errInvalidCredentialBrokerGrant
		}
	default:
		return errInvalidCredentialBrokerGrant
	}

	return nil
}

func credentialBrokerRequestBodyPolicyEmpty(policy coreaddon.CredentialBrokerRequestBodyPolicy) bool {
	return policy == (coreaddon.CredentialBrokerRequestBodyPolicy{})
}

func credentialBrokerHTTPMethodSafe(method string) bool {
	switch strings.ToUpper(strings.TrimSpace(method)) {
	case http.MethodGet, http.MethodHead:
		return true
	default:
		return false
	}
}

func validCredentialBrokerSHA256(value string) bool {
	if len(value) != 64 || value != strings.ToLower(value) {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32
}

func validCredentialBrokerContentType(value string) bool {
	value = strings.TrimSpace(value)
	mediaType, params, err := mime.ParseMediaType(value)
	return err == nil && len(params) == 0 && value == mediaType && value == strings.ToLower(value)
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
		username := credentialMaterialFieldValue(material, credentialFormFieldUsername, "user")
		password := credentialMaterialFieldValue(material, credentialFormFieldPassword)
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
