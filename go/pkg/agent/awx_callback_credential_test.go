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
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"testing"
	"time"
)

const (
	testAWXCallbackChildID = "018f3f56-1111-7222-8333-123456789abc"
	testAWXCallbackName    = "sr-callback-" + testAWXCallbackChildID
	testAWXCallbackCommand = "018f3f56-aaaa-4bbb-8ccc-123456789abc"
)

var errTestAWXCallbackCredentialLeak = errors.New("upstream leaked callback bearer abcdef")

func TestValidateAWXCallbackCredentialBindingRequiresExactSelectedAgentScope(t *testing.T) {
	t.Parallel()

	args := map[string]any{
		"credential_type_id": float64(91),
		"organization_id":    float64(2),
		"credential_name":    testAWXCallbackName,
		"injector_sha256":    repeatedByte('a', 64),
	}
	binding := testAWXCallbackBinding()
	validated, err := validateAWXCallbackCredentialBinding(binding, testAWXCallbackCommand, "agent-a", "controller-a", args, false)
	if err != nil {
		t.Fatalf("validate binding: %v", err)
	}
	if validated.CommandID != testAWXCallbackCommand {
		t.Fatalf("command id = %q", validated.CommandID)
	}

	for _, mutate := range []func(*AWXCallbackCredentialBinding){
		func(value *AWXCallbackCredentialBinding) { value.DispatchAgentID = "agent-b" },
		func(value *AWXCallbackCredentialBinding) { value.ControllerID = "controller-b" },
		func(value *AWXCallbackCredentialBinding) { value.CredentialSlot = "arbitrary" },
		func(value *AWXCallbackCredentialBinding) { value.OrganizationID = 0 },
		func(value *AWXCallbackCredentialBinding) { value.InjectorSHA256 = "moving" },
	} {
		candidate := testAWXCallbackBinding()
		mutate(&candidate)
		if _, err := validateAWXCallbackCredentialBinding(candidate, testAWXCallbackCommand, "agent-a", "controller-a", args, false); !errors.Is(err, errAWXCallbackCredentialBindingInvalid) {
			t.Fatalf("expected invalid binding, got %v for %#v", err, candidate)
		}
	}
}

func TestValidateAWXCallbackCredentialCleanupBindingCannotResolveLaunchMaterial(t *testing.T) {
	t.Parallel()

	args := map[string]any{
		"credential_id":      float64(401),
		"credential_type_id": float64(91),
		"organization_id":    float64(2),
		"credential_name":    testAWXCallbackName,
	}
	binding := testAWXCallbackBinding()
	binding.Schema = awxCallbackCredentialCleanupSchema
	binding.EnvelopeRef = ""

	validated, err := validateAWXCallbackCredentialBinding(
		binding,
		testAWXCallbackCommand,
		"agent-a",
		"controller-a",
		args,
		true,
	)
	if err != nil {
		t.Fatalf("validate cleanup binding: %v", err)
	}
	if validated.EnvelopeRef != "" {
		t.Fatalf("cleanup binding retained envelope reference: %#v", validated)
	}

	resolver := &fakeAWXCallbackCredentialResolver{
		material: testAWXCallbackMaterial(time.Now().UTC().Add(5 * time.Minute)),
	}
	_, err = resolveAWXCallbackCredentialMemoryInput(t.Context(), resolver, validated, time.Now().UTC())
	if !errors.Is(err, errAWXCallbackCredentialResolutionDenied) {
		t.Fatalf("cleanup binding unexpectedly resolved material: %v", err)
	}
	if resolver.binding != (AWXCallbackCredentialBinding{}) {
		t.Fatalf("cleanup binding reached credential resolver: %#v", resolver.binding)
	}

	launchBinding := testAWXCallbackBinding()
	if _, err := validateAWXCallbackCredentialBinding(
		launchBinding,
		testAWXCallbackCommand,
		"agent-a",
		"controller-a",
		args,
		true,
	); !errors.Is(err, errAWXCallbackCredentialBindingInvalid) {
		t.Fatalf("delete accepted launch-envelope binding: %v", err)
	}
}

func TestDecodeAWXCallbackCredentialBindingRejectsUnknownFields(t *testing.T) {
	t.Parallel()

	raw, err := json.Marshal(map[string]any{
		"schema":             awxCallbackCredentialBindingSchema,
		"envelope_ref":       "launch-envelope:v1:abcdefghijklmnopqrstuvwxyz012345",
		"dispatch_agent_id":  "agent-a",
		"controller_id":      "controller-a",
		"child_execution_id": testAWXCallbackChildID,
		"inventory_id":       7,
		"job_template_id":    42,
		"credential_type_id": 91,
		"organization_id":    2,
		"credential_name":    testAWXCallbackName,
		"credential_slot":    awxCallbackCredentialSlot,
		"injector_sha256":    repeatedByte('a', 64),
		"callback_grant":     "must-not-enter-durable-command",
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if _, err := decodeAWXCallbackCredentialBinding(raw); !errors.Is(err, errAWXCallbackCredentialBindingInvalid) {
		t.Fatalf("expected unknown-field rejection, got %v", err)
	}
}

func TestAWXCallbackCredentialMemoryInputRewritesExactBodyOnce(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 1, 0, 0, 0, time.UTC)
	material := testAWXCallbackMaterial(now.Add(5 * time.Minute))
	input := &awxCallbackCredentialMemoryInput{
		Binding:  testAWXCallbackBinding(),
		Material: material,
	}
	body := callbackCredentialSentinelBody(t)
	requestURL := mustAWXCallbackURL(t, "https://awx.example.com/api/v2/credentials/")

	rewritten, err := input.consumeInputs(http.MethodPost, requestURL, body, now)
	if err != nil {
		t.Fatalf("consume input: %v", err)
	}
	var payload struct {
		Inputs map[string]string `json:"inputs"`
	}
	if err := json.Unmarshal(rewritten, &payload); err != nil {
		t.Fatalf("decode rewritten body: %v", err)
	}
	if payload.Inputs["callback_grant"] != "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG" ||
		payload.Inputs["callback_idempotency_key"] != "idempotency-key-abcdefghijklmnopqrstuvwxyz012345" {
		t.Fatalf("memory-only bearer/idempotency inputs missing: %#v", payload.Inputs)
	}
	for _, value := range payload.Inputs {
		if value == awxCallbackCredentialInputSentinel {
			t.Fatalf("sentinel remained after host rewrite: %#v", payload.Inputs)
		}
	}
	if _, err := input.consumeInputs(http.MethodPost, requestURL, body, now); !errors.Is(err, errAWXCallbackCredentialInputConsumed) {
		t.Fatalf("expected one-use denial, got %v", err)
	}

	grantBuffer := input.Material.CallbackGrant
	idempotencyBuffer := input.Material.CallbackIdempotencyKey
	input.destroy()
	if !allZero(grantBuffer) || !allZero(idempotencyBuffer) {
		t.Fatal("callback bearer and idempotency buffers were not zeroed")
	}
}

func TestAWXCallbackCredentialMemoryInputRejectsWrongPathAndMalformedMaterial(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 1, 0, 0, 0, time.UTC)
	input := &awxCallbackCredentialMemoryInput{
		Binding:  testAWXCallbackBinding(),
		Material: testAWXCallbackMaterial(now.Add(5 * time.Minute)),
	}
	body := callbackCredentialSentinelBody(t)

	if _, err := input.consumeInputs(
		http.MethodPost,
		mustAWXCallbackURL(t, "https://awx.example.com/api/v2/credentials/401/"),
		body,
		now,
	); !errors.Is(err, errAWXCallbackCredentialInputInvalid) {
		t.Fatalf("expected exact-path denial, got %v", err)
	}

	input.Material.CallbackIdempotencyKey = []byte("agent-generated-short-key")
	if _, err := input.consumeInputs(
		http.MethodPost,
		mustAWXCallbackURL(t, "https://awx.example.com/api/v2/credentials/"),
		body,
		now,
	); !errors.Is(err, errAWXCallbackCredentialInputInvalid) {
		t.Fatalf("expected missing server key denial, got %v", err)
	}
}

func TestPluginExecutionRejectsSentinelWithoutEnvelopeInput(t *testing.T) {
	t.Parallel()

	execution := &pluginExecution{}
	_, err := execution.rewriteAWXCallbackCredentialBody(
		http.MethodPost,
		mustAWXCallbackURL(t, "https://awx.example.com/api/v2/credentials/"),
		callbackCredentialSentinelBody(t),
	)
	if !errors.Is(err, errAWXCallbackCredentialInputMissing) {
		t.Fatalf("expected missing memory input, got %v", err)
	}
}

func TestPluginExecutionAllowsOnlyCanonicalCallbackCredentialPreflightThenOnePost(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	input := &awxCallbackCredentialMemoryInput{
		Binding:  testAWXCallbackBinding(),
		Material: testAWXCallbackMaterial(now.Add(5 * time.Minute)),
	}
	execution := &pluginExecution{awxCallbackCredential: input}
	canonical := "https://awx.example.com/api/v2/credentials/?" +
		"credential_type=91&name=sr-callback-018f3f56-1111-7222-8333-123456789abc&organization=2&page_size=2"

	body, err := execution.rewriteAWXCallbackCredentialBody(
		http.MethodGet,
		mustAWXCallbackURL(t, "https://awx.example.com/api/v2/credential_types/91/"),
		nil,
	)
	if err != nil || len(body) != 0 || input.used {
		t.Fatalf("credential type verification failed or consumed material: body=%q used=%v err=%v", body, input.used, err)
	}

	body, err = execution.rewriteAWXCallbackCredentialBody(
		http.MethodGet,
		mustAWXCallbackURL(t, canonical),
		nil,
	)
	if err != nil || len(body) != 0 || input.used {
		t.Fatalf("canonical preflight failed or consumed material: body=%q used=%v err=%v", body, input.used, err)
	}

	postBody, err := execution.rewriteAWXCallbackCredentialBody(
		http.MethodPost,
		mustAWXCallbackURL(t, "https://awx.example.com/api/v2/credentials/"),
		callbackCredentialSentinelBody(t),
	)
	if err != nil || len(postBody) == 0 || !input.used {
		t.Fatalf("exact POST did not consume material: body=%q used=%v err=%v", postBody, input.used, err)
	}
}

func TestPluginExecutionRejectsAlteredCallbackCredentialPreflight(t *testing.T) {
	t.Parallel()

	canonicalQuery := "credential_type=91&name=sr-callback-018f3f56-1111-7222-8333-123456789abc&organization=2&page_size=2"
	tests := []struct {
		name string
		url  string
		body []byte
	}{
		{
			name: "credential type",
			url:  "https://awx.example.com/api/v2/credential_types/34/",
		},
		{
			name: "name",
			url:  "https://awx.example.com/api/v2/credentials/?credential_type=91&name=other&organization=2&page_size=2",
		},
		{
			name: "type",
			url:  "https://awx.example.com/api/v2/credentials/?credential_type=34&name=" + testAWXCallbackName + "&organization=2&page_size=2",
		},
		{
			name: "organization",
			url:  "https://awx.example.com/api/v2/credentials/?credential_type=91&name=" + testAWXCallbackName + "&organization=3&page_size=2",
		},
		{
			name: "page size",
			url:  "https://awx.example.com/api/v2/credentials/?credential_type=91&name=" + testAWXCallbackName + "&organization=2&page_size=3",
		},
		{
			name: "path",
			url:  "https://awx.example.com/api/v2/credentials/401/?" + canonicalQuery,
		},
		{
			name: "query order",
			url: "https://awx.example.com/api/v2/credentials/?name=" + testAWXCallbackName +
				"&credential_type=91&organization=2&page_size=2",
		},
		{
			name: "extra parameter",
			url:  "https://awx.example.com/api/v2/credentials/?" + canonicalQuery + "&page=1",
		},
		{
			name: "body",
			url:  "https://awx.example.com/api/v2/credentials/?" + canonicalQuery,
			body: []byte(`{}`),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			input := &awxCallbackCredentialMemoryInput{
				Binding:  testAWXCallbackBinding(),
				Material: testAWXCallbackMaterial(time.Now().UTC().Add(5 * time.Minute)),
			}
			execution := &pluginExecution{awxCallbackCredential: input}
			_, err := execution.rewriteAWXCallbackCredentialBody(
				http.MethodGet,
				mustAWXCallbackURL(t, test.url),
				test.body,
			)
			if !errors.Is(err, errAWXCallbackCredentialInputInvalid) || input.used {
				t.Fatalf("altered preflight accepted or consumed input: used=%v err=%v", input.used, err)
			}
		})
	}
}

func TestCredentialBrokerExactPathMarkerDoesNotBroadenCredentialAccess(t *testing.T) {
	t.Parallel()

	if !credentialBrokerPathAllowed([]string{"=/api/v2/credentials/"}, "/api/v2/credentials/") {
		t.Fatal("exact create path should match")
	}
	for _, denied := range []string{
		"/api/v2/credentials/401/",
		"/api/v2/credentials/anything",
		"/api/v2/credentials",
	} {
		if credentialBrokerPathAllowed([]string{"=/api/v2/credentials/"}, denied) {
			t.Fatalf("exact create path broadened to %q", denied)
		}
	}
}

func TestResolveAWXCallbackCredentialMemoryInputUsesOpaqueBindingAndSanitizesError(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 1, 0, 0, 0, time.UTC)
	resolver := &fakeAWXCallbackCredentialResolver{material: testAWXCallbackMaterial(now.Add(5 * time.Minute))}
	input, err := resolveAWXCallbackCredentialMemoryInput(t.Context(), resolver, testAWXCallbackBinding(), now)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	defer input.destroy()
	if resolver.binding.EnvelopeRef == "" || resolver.binding.CommandID != testAWXCallbackCommand {
		t.Fatalf("resolver binding = %#v", resolver.binding)
	}

	resolver.err = errTestAWXCallbackCredentialLeak
	_, err = resolveAWXCallbackCredentialMemoryInput(t.Context(), resolver, testAWXCallbackBinding(), now)
	if !errors.Is(err, errAWXCallbackCredentialResolutionDenied) ||
		err.Error() != errAWXCallbackCredentialResolutionDenied.Error() {
		t.Fatalf("expected sanitized resolution denial, got %v", err)
	}
}

func TestPluginManagerDestroysAWXCallbackMaterialOnPreExecutionFailure(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	material := testAWXCallbackMaterial(now.Add(5 * time.Minute))
	buffers := [][]byte{
		material.CallbackGrant,
		material.CallbackIdempotencyKey,
		material.CallbackURL,
		material.CallbackAllowedOrigin,
		material.CallbackManifestSHA256,
		material.SCMRevision,
		material.ContentSHA256,
		material.CallbackPhase,
		material.CallbackOperation,
		material.CallbackState,
	}
	input := &awxCallbackCredentialMemoryInput{
		Binding:  testAWXCallbackBinding(),
		Material: material,
	}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{})
	defer manager.Stop()

	_, err := manager.RunPluginVerbWithAWXCallbackCredential(
		t.Context(),
		awxPluginID,
		nil,
		nil,
		input,
		time.Second,
	)
	if !errors.Is(err, errPluginAssignmentNotFound) {
		t.Fatalf("expected pre-execution assignment failure, got %v", err)
	}
	for _, buffer := range buffers {
		if !allZero(buffer) {
			t.Fatal("PluginManager retained callback material after failure")
		}
	}
}

func testAWXCallbackBinding() AWXCallbackCredentialBinding {
	return AWXCallbackCredentialBinding{
		Schema:           awxCallbackCredentialBindingSchema,
		EnvelopeRef:      "launch-envelope:v1:abcdefghijklmnopqrstuvwxyz012345",
		DispatchAgentID:  "agent-a",
		ControllerID:     "controller-a",
		ChildExecutionID: testAWXCallbackChildID,
		InventoryID:      7,
		JobTemplateID:    42,
		CredentialTypeID: 91,
		OrganizationID:   2,
		CredentialName:   testAWXCallbackName,
		CredentialSlot:   awxCallbackCredentialSlot,
		InjectorSHA256:   repeatedByte('a', 64),
		CommandID:        testAWXCallbackCommand,
	}
}

func testAWXCallbackMaterial(expiresAt time.Time) AWXCallbackCredentialMaterial {
	return AWXCallbackCredentialMaterial{
		CallbackURL: []byte(
			"https://demo.example.com/api/v1/automation/callback-grants/grant_1/actions/remote_access.ssh_ca.bundle.read",
		),
		CallbackGrant:          []byte("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"),
		CallbackIdempotencyKey: []byte("idempotency-key-abcdefghijklmnopqrstuvwxyz012345"),
		CallbackAllowedOrigin:  []byte("https://demo.example.com"),
		CallbackManifestSHA256: []byte(repeatedByte('b', 64)),
		SCMRevision:            []byte(repeatedByte('c', 40)),
		ContentSHA256:          []byte(repeatedByte('d', 64)),
		CallbackPhase:          []byte("stage"),
		CallbackOperation:      []byte("enroll"),
		CallbackState:          []byte("present"),
		ExpiresAt:              expiresAt,
	}
}

func callbackCredentialSentinelBody(t *testing.T) []byte {
	t.Helper()
	inputNames := awxCallbackCredentialInputNames()
	inputs := make(map[string]string, len(inputNames))
	for _, key := range inputNames {
		inputs[key] = awxCallbackCredentialInputSentinel
	}
	body, err := json.Marshal(map[string]any{
		"name":            testAWXCallbackName,
		"description":     awxCallbackCredentialDescription,
		"credential_type": 91,
		"organization":    2,
		"inputs":          inputs,
	})
	if err != nil {
		t.Fatalf("marshal callback body: %v", err)
	}
	return body
}

func mustAWXCallbackURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse URL: %v", err)
	}
	return parsed
}

func repeatedByte(value byte, count int) string {
	buffer := make([]byte, count)
	for i := range buffer {
		buffer[i] = value
	}
	return string(buffer)
}

func allZero(value []byte) bool {
	for _, current := range value {
		if current != 0 {
			return false
		}
	}
	return true
}

type fakeAWXCallbackCredentialResolver struct {
	binding  AWXCallbackCredentialBinding
	material AWXCallbackCredentialMaterial
	err      error
}

func (f *fakeAWXCallbackCredentialResolver) ResolveAWXCallbackCredentialEnvelope(
	_ context.Context,
	binding AWXCallbackCredentialBinding,
) (AWXCallbackCredentialMaterial, error) {
	f.binding = binding
	if f.err != nil {
		return AWXCallbackCredentialMaterial{}, f.err
	}
	return f.material, nil
}
