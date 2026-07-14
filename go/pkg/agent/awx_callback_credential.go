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
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	awxCallbackCredentialBindingSchema = "serviceradar.awx_callback_credential_binding.v1"
	awxCallbackCredentialCleanupSchema = "serviceradar.awx_callback_credential_cleanup_binding.v1"
	awxCallbackCredentialSlot          = "ssh_ca_callback"
	awxCallbackCredentialNamePrefix    = "sr-callback-"
	awxCallbackCredentialDescription   = "ServiceRadar ephemeral automation callback credential"
	awxCallbackCredentialCreatePath    = "/api/v2/credentials/"
	awxCallbackCredentialInputSentinel = "__SERVICERADAR_CALLBACK_CREDENTIAL_INPUT__"
	maxAWXCallbackEnvelopeRefBytes     = 512
	maxAWXCallbackURLBytes             = 2048
	maxAWXCallbackOriginBytes          = 512
	maxAWXCallbackMaterialTTL          = 10 * time.Minute
	awxCallbackCredentialInputCount    = 10
)

var (
	errAWXCallbackCredentialBindingInvalid   = errors.New("invalid awx callback credential binding")
	errAWXCallbackCredentialResolverMissing  = errors.New("awx callback credential envelope resolver unavailable")
	errAWXCallbackCredentialResolutionDenied = errors.New("awx callback credential envelope resolution denied")
	errAWXCallbackCredentialInputInvalid     = errors.New("invalid awx callback credential input")
	errAWXCallbackCredentialInputMissing     = errors.New("awx callback credential input unavailable")
	errAWXCallbackCredentialInputConsumed    = errors.New("awx callback credential input already consumed")
)

func awxCallbackCredentialInputNames() [awxCallbackCredentialInputCount]string {
	return [awxCallbackCredentialInputCount]string{
		"callback_url",
		"callback_grant",
		"callback_idempotency_key",
		"callback_allowed_origin",
		"callback_manifest_sha256",
		"scm_revision",
		"content_sha256",
		"callback_phase",
		"callback_operation",
		"callback_state",
	}
}

// AWXCallbackCredentialBinding is the non-secret, durable command binding for
// one reviewed callback credential. EnvelopeRef is opaque and single-use for
// creation and is not credential material. Cleanup commands use a distinct
// schema and MUST leave EnvelopeRef empty, so credential deletion cannot
// resolve or reuse launch material. CommandID is filled by the selected agent
// and is never accepted from the durable payload.
type AWXCallbackCredentialBinding struct {
	Schema           string `json:"schema"`
	EnvelopeRef      string `json:"envelope_ref"`
	DispatchAgentID  string `json:"dispatch_agent_id"`
	ControllerID     string `json:"controller_id"`
	ChildExecutionID string `json:"child_execution_id"`
	InventoryID      int    `json:"inventory_id"`
	JobTemplateID    int    `json:"job_template_id"`
	CredentialTypeID int    `json:"credential_type_id"`
	OrganizationID   int    `json:"organization_id"`
	CredentialName   string `json:"credential_name"`
	CredentialSlot   string `json:"credential_slot"`
	InjectorSHA256   string `json:"injector_sha256"`
	CommandID        string `json:"-"`
}

// AWXCallbackCredentialMaterial is owned by the trusted selected-agent
// resolver and remains memory-only. Each byte slice is destroyed after the
// one plugin execution. Implementations must return fresh, caller-owned slices.
type AWXCallbackCredentialMaterial struct {
	CallbackURL            []byte
	CallbackGrant          []byte
	CallbackIdempotencyKey []byte
	CallbackAllowedOrigin  []byte
	CallbackManifestSHA256 []byte
	SCMRevision            []byte
	ContentSHA256          []byte
	CallbackPhase          []byte
	CallbackOperation      []byte
	CallbackState          []byte
	ExpiresAt              time.Time
}

// AWXCallbackCredentialEnvelopeResolver authenticates and resolves one opaque
// launch envelope for the exact selected-agent binding. The control-plane
// implementation also re-correlates the returned material before handing it
// to this trusted host boundary.
type AWXCallbackCredentialEnvelopeResolver interface {
	ResolveAWXCallbackCredentialEnvelope(
		context.Context,
		AWXCallbackCredentialBinding,
	) (AWXCallbackCredentialMaterial, error)
}

type awxCallbackCredentialMemoryInput struct {
	Binding  AWXCallbackCredentialBinding
	Material AWXCallbackCredentialMaterial
	mu       sync.Mutex
	used     bool
}

func (e *pluginExecution) rewriteAWXCallbackCredentialBody(
	method string,
	requestURL *url.URL,
	body []byte,
) ([]byte, error) {
	hasSentinel := bytes.Contains(body, []byte(awxCallbackCredentialInputSentinel))
	if e == nil || e.awxCallbackCredential == nil {
		if hasSentinel {
			return nil, errAWXCallbackCredentialInputMissing
		}
		return body, nil
	}
	if method == http.MethodGet && !hasSentinel {
		if e.awxCallbackCredential.validCredentialTypeRequest(requestURL, body) ||
			e.awxCallbackCredential.validPreflightRequest(requestURL, body) {
			return body, nil
		}
		return nil, errAWXCallbackCredentialInputInvalid
	}
	if !hasSentinel {
		return nil, errAWXCallbackCredentialInputInvalid
	}

	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}
	return e.awxCallbackCredential.consumeInputs(method, requestURL, body, now)
}

func awxCredentialEndpoint(requestURL *url.URL) bool {
	if requestURL == nil {
		return false
	}
	path := requestURL.EscapedPath()
	if path == awxCallbackCredentialCreatePath {
		return true
	}
	if !strings.HasPrefix(path, awxCallbackCredentialCreatePath) || !strings.HasSuffix(path, "/") {
		return false
	}
	id := strings.TrimSuffix(strings.TrimPrefix(path, awxCallbackCredentialCreatePath), "/")
	if id == "" {
		return false
	}
	for _, char := range id {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

func (input *awxCallbackCredentialMemoryInput) validCredentialTypeRequest(
	requestURL *url.URL,
	body []byte,
) bool {
	if input == nil || requestURL == nil || len(body) != 0 || requestURL.RawQuery != "" {
		return false
	}
	expectedPath := fmt.Sprintf("/api/v2/credential_types/%d/", input.Binding.CredentialTypeID)
	return requestURL.EscapedPath() == expectedPath
}

func awxReviewedCredentialTypeEndpoint(requestURL *url.URL) bool {
	if requestURL == nil || requestURL.RawQuery != "" {
		return false
	}
	const prefix = "/api/v2/credential_types/"
	path := requestURL.EscapedPath()
	if !strings.HasPrefix(path, prefix) || !strings.HasSuffix(path, "/") {
		return false
	}
	id := strings.TrimSuffix(strings.TrimPrefix(path, prefix), "/")
	if id == "" {
		return false
	}
	for _, char := range id {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

func (input *awxCallbackCredentialMemoryInput) validPreflightRequest(requestURL *url.URL, body []byte) bool {
	if input == nil || requestURL == nil || requestURL.EscapedPath() != awxCallbackCredentialCreatePath ||
		len(body) != 0 {
		return false
	}
	expectedQuery := url.Values{}
	expectedQuery.Set("name", input.Binding.CredentialName)
	expectedQuery.Set("credential_type", strconv.Itoa(input.Binding.CredentialTypeID))
	expectedQuery.Set("organization", strconv.Itoa(input.Binding.OrganizationID))
	expectedQuery.Set("page_size", "2")
	if requestURL.RawQuery != expectedQuery.Encode() {
		return false
	}
	query := requestURL.Query()
	if len(query) != 4 || len(query["name"]) != 1 || len(query["credential_type"]) != 1 ||
		len(query["organization"]) != 1 || len(query["page_size"]) != 1 {
		return false
	}
	return query.Get("name") == input.Binding.CredentialName &&
		query.Get("credential_type") == strconv.Itoa(input.Binding.CredentialTypeID) &&
		query.Get("organization") == strconv.Itoa(input.Binding.OrganizationID) &&
		query.Get("page_size") == "2"
}

func decodeAWXCallbackCredentialBinding(raw json.RawMessage) (AWXCallbackCredentialBinding, error) {
	var binding AWXCallbackCredentialBinding
	if len(bytes.TrimSpace(raw)) == 0 {
		return binding, errAWXCallbackCredentialBindingInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&binding); err != nil {
		return binding, errAWXCallbackCredentialBindingInvalid
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return binding, errAWXCallbackCredentialBindingInvalid
	}
	return binding, nil
}

func validateAWXCallbackCredentialBinding(
	binding AWXCallbackCredentialBinding,
	commandID string,
	selectedAgentID string,
	controllerID string,
	args map[string]any,
	deleting bool,
) (AWXCallbackCredentialBinding, error) {
	binding.CommandID = strings.TrimSpace(commandID)
	expectedSchema := awxCallbackCredentialBindingSchema
	validEnvelope := opaqueEnvelopeReference(binding.EnvelopeRef)
	if deleting {
		expectedSchema = awxCallbackCredentialCleanupSchema
		validEnvelope = binding.EnvelopeRef == ""
	}
	if binding.Schema != expectedSchema || !validEnvelope ||
		strings.TrimSpace(binding.DispatchAgentID) == "" ||
		strings.TrimSpace(binding.DispatchAgentID) != strings.TrimSpace(selectedAgentID) ||
		strings.TrimSpace(binding.ControllerID) == "" ||
		strings.TrimSpace(binding.ControllerID) != strings.TrimSpace(controllerID) ||
		!uuidLike(binding.ChildExecutionID) ||
		!positiveAWXID(binding.InventoryID) || !positiveAWXID(binding.JobTemplateID) ||
		!positiveAWXID(binding.CredentialTypeID) || !positiveAWXID(binding.OrganizationID) ||
		binding.CredentialSlot != awxCallbackCredentialSlot ||
		!lowerHex(binding.InjectorSHA256, 64) ||
		!uuidLike(binding.CommandID) ||
		binding.CredentialName != awxCallbackCredentialNamePrefix+binding.ChildExecutionID {
		return binding, errAWXCallbackCredentialBindingInvalid
	}

	credentialTypeID, typeOK := awxCallbackArgInt(args, "credential_type_id")
	organizationID, orgOK := awxCallbackArgInt(args, "organization_id")
	credentialName, nameOK := args["credential_name"].(string)
	injectorSHA256, injectorOK := args["injector_sha256"].(string)
	if !typeOK || !orgOK || !positiveAWXID(credentialTypeID) || !positiveAWXID(organizationID) ||
		!nameOK || credentialTypeID != binding.CredentialTypeID ||
		organizationID != binding.OrganizationID || credentialName != binding.CredentialName ||
		(!deleting && (!injectorOK || injectorSHA256 != binding.InjectorSHA256)) {
		return binding, errAWXCallbackCredentialBindingInvalid
	}

	return binding, nil
}

func positiveAWXID(value int) bool {
	return value > 0 && value <= math.MaxInt32
}

func validateAWXCallbackCredentialCommandArgs(args map[string]any, deleting bool) error {
	expected := []string{"credential_type_id", "organization_id", "credential_name"}
	if deleting {
		expected = append(expected, "credential_id")
	} else {
		expected = append(expected, "injector_sha256")
	}
	if !exactStringSet(mapKeys(args), expected) {
		return errAWXCallbackCredentialBindingInvalid
	}
	return nil
}

func validateAWXCallbackCredentialMaterial(material AWXCallbackCredentialMaterial, now time.Time) error {
	if material.ExpiresAt.IsZero() || !now.Before(material.ExpiresAt) ||
		material.ExpiresAt.After(now.Add(maxAWXCallbackMaterialTTL)) {
		return errAWXCallbackCredentialInputInvalid
	}

	callbackURL := string(material.CallbackURL)
	allowedOrigin := string(material.CallbackAllowedOrigin)
	if !validCallbackURL(callbackURL, allowedOrigin) ||
		!boundedOpaqueValue(material.CallbackGrant, 32, 128) ||
		!boundedOpaqueValue(material.CallbackIdempotencyKey, 32, 128) ||
		!lowerHexBytes(material.CallbackManifestSHA256, 64, 64) ||
		!lowerHexBytes(material.SCMRevision, 40, 64) ||
		!lowerHexBytes(material.ContentSHA256, 64, 64) ||
		!oneOfBytes(material.CallbackPhase, "preflight", "stage", "verify", "commit") ||
		!oneOfBytes(material.CallbackOperation, "enroll", "overlap", "retire", "remove") ||
		!oneOfBytes(material.CallbackState, "present", "absent") ||
		(bytes.Equal(material.CallbackOperation, []byte("remove")) !=
			bytes.Equal(material.CallbackState, []byte("absent"))) {
		return errAWXCallbackCredentialInputInvalid
	}

	return nil
}

func (input *awxCallbackCredentialMemoryInput) consumeInputs(
	method string,
	requestURL *url.URL,
	body []byte,
	now time.Time,
) ([]byte, error) {
	if input == nil {
		return nil, errAWXCallbackCredentialInputMissing
	}
	input.mu.Lock()
	defer input.mu.Unlock()
	if input.used {
		return nil, errAWXCallbackCredentialInputConsumed
	}
	if method != http.MethodPost || requestURL == nil ||
		requestURL.EscapedPath() != awxCallbackCredentialCreatePath || requestURL.RawQuery != "" {
		return nil, errAWXCallbackCredentialInputInvalid
	}
	if err := validateAWXCallbackCredentialMaterial(input.Material, now); err != nil {
		return nil, err
	}

	var root map[string]json.RawMessage
	if err := json.Unmarshal(body, &root); err != nil || !exactStringSet(
		mapKeys(root),
		[]string{"name", "description", "credential_type", "organization", "inputs"},
	) {
		return nil, errAWXCallbackCredentialInputInvalid
	}

	var name, description string
	var credentialTypeID, organizationID int
	var rawInputs map[string]string
	inputNames := awxCallbackCredentialInputNames()
	if json.Unmarshal(root["name"], &name) != nil ||
		json.Unmarshal(root["description"], &description) != nil ||
		json.Unmarshal(root["credential_type"], &credentialTypeID) != nil ||
		json.Unmarshal(root["organization"], &organizationID) != nil ||
		json.Unmarshal(root["inputs"], &rawInputs) != nil ||
		name != input.Binding.CredentialName ||
		description != awxCallbackCredentialDescription ||
		credentialTypeID != input.Binding.CredentialTypeID ||
		organizationID != input.Binding.OrganizationID ||
		!exactStringSet(mapKeys(rawInputs), inputNames[:]) {
		return nil, errAWXCallbackCredentialInputInvalid
	}
	for _, key := range inputNames {
		if rawInputs[key] != awxCallbackCredentialInputSentinel {
			return nil, errAWXCallbackCredentialInputInvalid
		}
	}

	encoded := encodeAWXCallbackCredentialCreateBody(
		name,
		description,
		credentialTypeID,
		organizationID,
		input.Material,
	)
	input.used = true
	return encoded, nil
}

// encodeAWXCallbackCredentialCreateBody deliberately appends directly from
// caller-owned byte slices. Converting the bearer or idempotency key to a Go
// string would leave an immutable, non-zeroable copy behind. The returned body
// is cleared by hostHTTPRequest immediately after the HTTP exchange.
func encodeAWXCallbackCredentialCreateBody(
	name string,
	description string,
	credentialTypeID int,
	organizationID int,
	material AWXCallbackCredentialMaterial,
) []byte {
	values := [...][]byte{
		material.CallbackURL,
		material.CallbackGrant,
		material.CallbackIdempotencyKey,
		material.CallbackAllowedOrigin,
		material.CallbackManifestSHA256,
		material.SCMRevision,
		material.ContentSHA256,
		material.CallbackPhase,
		material.CallbackOperation,
		material.CallbackState,
	}

	encoded := make([]byte, 0, 1024)
	encoded = append(encoded, `{"credential_type":`...)
	encoded = strconv.AppendInt(encoded, int64(credentialTypeID), 10)
	encoded = append(encoded, `,"description":`...)
	encoded = strconv.AppendQuote(encoded, description)
	encoded = append(encoded, `,"inputs":{`...)
	for i, key := range awxCallbackCredentialInputNames() {
		if i > 0 {
			encoded = append(encoded, ',')
		}
		encoded = strconv.AppendQuote(encoded, key)
		encoded = append(encoded, ':')
		encoded = appendJSONStringBytes(encoded, values[i])
	}
	encoded = append(encoded, `},"name":`...)
	encoded = strconv.AppendQuote(encoded, name)
	encoded = append(encoded, `,"organization":`...)
	encoded = strconv.AppendInt(encoded, int64(organizationID), 10)
	encoded = append(encoded, '}')
	return encoded
}

func appendJSONStringBytes(dst []byte, value []byte) []byte {
	const hex = "0123456789abcdef"
	dst = append(dst, '"')
	for _, char := range value {
		switch char {
		case '"', '\\':
			dst = append(dst, '\\', char)
		case '\b':
			dst = append(dst, `\b`...)
		case '\f':
			dst = append(dst, `\f`...)
		case '\n':
			dst = append(dst, `\n`...)
		case '\r':
			dst = append(dst, `\r`...)
		case '\t':
			dst = append(dst, `\t`...)
		default:
			if char < 0x20 {
				dst = append(dst, '\\', 'u', '0', '0', hex[char>>4], hex[char&0x0f])
			} else {
				dst = append(dst, char)
			}
		}
	}
	return append(dst, '"')
}

func (input *awxCallbackCredentialMemoryInput) destroy() {
	if input == nil {
		return
	}
	input.mu.Lock()
	defer input.mu.Unlock()
	input.Material.destroy()
}

func (material *AWXCallbackCredentialMaterial) destroy() {
	if material == nil {
		return
	}
	for _, value := range [][]byte{
		material.CallbackURL,
		material.CallbackGrant,
		material.CallbackIdempotencyKey,
		material.CallbackAllowedOrigin,
		material.CallbackManifestSHA256,
		material.SCMRevision,
		material.ContentSHA256,
		material.CallbackPhase,
		material.CallbackOperation,
		material.CallbackState,
	} {
		clear(value)
	}
}

func validCallbackURL(rawURL, rawOrigin string) bool {
	if len(rawURL) == 0 || len(rawURL) > maxAWXCallbackURLBytes ||
		len(rawOrigin) == 0 || len(rawOrigin) > maxAWXCallbackOriginBytes ||
		!printableASCII(rawURL) || !printableASCII(rawOrigin) {
		return false
	}
	callback, err := url.Parse(rawURL)
	if err != nil || callback.Scheme != httpsScheme || callback.Host == "" || callback.User != nil ||
		callback.RawQuery != "" || callback.Fragment != "" {
		return false
	}
	origin, err := url.Parse(rawOrigin)
	if err != nil || origin.Scheme != httpsScheme || origin.Host == "" || origin.User != nil ||
		origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" {
		return false
	}
	if !strings.EqualFold(callback.Host, origin.Host) {
		return false
	}
	const prefix = "/api/v1/automation/callback-grants/"
	const suffix = "/actions/remote_access.ssh_ca.bundle.read"
	if !strings.HasPrefix(callback.EscapedPath(), prefix) || !strings.HasSuffix(callback.EscapedPath(), suffix) {
		return false
	}
	grantID := strings.TrimSuffix(strings.TrimPrefix(callback.EscapedPath(), prefix), suffix)
	return grantID != "" && len(grantID) <= 128 && safeOpaqueASCII(grantID)
}

func printableASCII(value string) bool {
	for _, char := range []byte(value) {
		if char < 0x20 || char > 0x7e {
			return false
		}
	}
	return true
}

func opaqueEnvelopeReference(value string) bool {
	return len(value) >= 16 && len(value) <= maxAWXCallbackEnvelopeRefBytes && safeOpaqueASCII(value)
}

func boundedOpaqueValue(value []byte, minBytes, maxBytes int) bool {
	if len(value) < minBytes || len(value) > maxBytes {
		return false
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || strings.ContainsRune("._~:-", rune(char)) {
			continue
		}
		return false
	}
	return true
}

func lowerHexBytes(value []byte, minBytes, maxBytes int) bool {
	if len(value) < minBytes || len(value) > maxBytes {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'f') && (char < '0' || char > '9') {
			return false
		}
	}
	return true
}

func oneOfBytes(value []byte, allowed ...string) bool {
	for _, candidate := range allowed {
		if bytes.Equal(value, []byte(candidate)) {
			return true
		}
	}
	return false
}

func safeOpaqueASCII(value string) bool {
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || strings.ContainsRune("._~:-", char) {
			continue
		}
		return false
	}
	return true
}

func uuidLike(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, char := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if char != '-' {
				return false
			}
			continue
		}
		if (char < 'a' || char > 'f') && (char < '0' || char > '9') {
			return false
		}
	}
	return true
}

func lowerHex(value string, size int) bool {
	return len(value) == size && lowerHexRange(value, size, size)
}

func lowerHexRange(value string, minBytes, maxBytes int) bool {
	if len(value) < minBytes || len(value) > maxBytes {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'f') && (char < '0' || char > '9') {
			return false
		}
	}
	return true
}

func awxCallbackArgInt(args map[string]any, key string) (int, bool) {
	value, ok := args[key]
	if !ok {
		return 0, false
	}
	switch typed := value.(type) {
	case int:
		return typed, true
	case int64:
		converted := int(typed)
		return converted, int64(converted) == typed
	case float64:
		if math.Trunc(typed) != typed || typed > float64(math.MaxInt) || typed < float64(math.MinInt) {
			return 0, false
		}
		return int(typed), true
	case json.Number:
		parsed, err := strconv.ParseInt(string(typed), 10, 64)
		if err != nil {
			return 0, false
		}
		converted := int(parsed)
		return converted, int64(converted) == parsed
	default:
		return 0, false
	}
}

func mapKeys[T any](value map[string]T) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	return keys
}

func exactStringSet(actual, expected []string) bool {
	if len(actual) != len(expected) {
		return false
	}
	set := make(map[string]struct{}, len(expected))
	for _, value := range expected {
		set[value] = struct{}{}
	}
	for _, value := range actual {
		if _, ok := set[value]; !ok {
			return false
		}
	}
	return true
}

func resolveAWXCallbackCredentialMemoryInput(
	ctx context.Context,
	resolver AWXCallbackCredentialEnvelopeResolver,
	binding AWXCallbackCredentialBinding,
	now time.Time,
) (*awxCallbackCredentialMemoryInput, error) {
	// Cleanup bindings are deliberately non-resolvable. Keep this check here in
	// addition to the delete branch in control_stream.go so a future call-site
	// cannot accidentally turn deletion correlation into credential access.
	if binding.Schema != awxCallbackCredentialBindingSchema ||
		!opaqueEnvelopeReference(binding.EnvelopeRef) {
		return nil, errAWXCallbackCredentialResolutionDenied
	}
	if resolver == nil {
		return nil, errAWXCallbackCredentialResolverMissing
	}
	material, err := resolver.ResolveAWXCallbackCredentialEnvelope(ctx, binding)
	if err != nil {
		material.destroy()
		return nil, fmt.Errorf("%w", errAWXCallbackCredentialResolutionDenied)
	}
	if err := validateAWXCallbackCredentialMaterial(material, now); err != nil {
		material.destroy()
		return nil, err
	}
	return &awxCallbackCredentialMemoryInput{Binding: binding, Material: material}, nil
}

func (m *PluginManager) awxCallbackCredentialEnvelopeResolver() AWXCallbackCredentialEnvelopeResolver {
	if m == nil {
		return nil
	}
	m.awxCallbackCredentialMu.Lock()
	defer m.awxCallbackCredentialMu.Unlock()
	return m.awxCallbackCredentialResolver
}
