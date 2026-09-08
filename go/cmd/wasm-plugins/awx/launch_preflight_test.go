package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const launchPreflightTestSecret = "SR_LAUNCH_PREFLIGHT_SECRET_MUST_NOT_CROSS"

func TestRunFetchLaunchPreflightReturnsRedactedCanonicalProjection(t *testing.T) {
	firstTemplate := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	lastTemplate := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	fake := &scriptedHTTPClient{responses: launchPreflightResponses(t, firstTemplate, lastTemplate)}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.test",
		APIToken: "broker-sentinel",
		Verb:     launchPreflightVerb,
		Args:     validLaunchPreflightArgs(),
	}
	result := dispatch(cfg)
	if result.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %s: %s", result.Status, result.Summary)
	}
	if strings.Contains(result.Details, launchPreflightTestSecret) || strings.Contains(result.Details, "api_token") ||
		strings.Contains(result.Details, "credential_password") {
		t.Fatalf("preflight result leaked raw controller material: %s", result.Details)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(result.Details), &payload); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	assertExactMapKeys(t, payload, "schema", "verb", "ok", "request_digest", "preflight", "preflight_digest")
	if payload["schema"] != launchPreflightResultSchema || payload["verb"] != launchPreflightVerb || payload["ok"] != true {
		t.Fatalf("unexpected result envelope: %#v", payload)
	}
	if !validBareSHA256Digest(payload["request_digest"].(string)) ||
		!validBareSHA256Digest(payload["preflight_digest"].(string)) {
		t.Fatalf("result digest is not a canonical SHA-256: %#v", payload)
	}
	if containsJSONFloat(payload) {
		t.Fatalf("preflight result must not contain JSON floats: %s", result.Details)
	}

	preflight, ok := payload["preflight"].(map[string]any)
	if !ok {
		t.Fatalf("preflight projection missing: %#v", payload["preflight"])
	}
	assertExactMapKeys(t, preflight,
		"schema", "controller_id", "template", "survey", "survey_digest", "project", "inventory",
		"credentials", "execution_environment", "selected_hosts")
	if preflight["schema"] != launchPreflightContractSchema {
		t.Fatalf("unexpected preflight schema: %#v", preflight)
	}
	if !validBareSHA256Digest(preflight["survey_digest"].(string)) {
		t.Fatalf("survey digest is invalid: %#v", preflight["survey_digest"])
	}

	template := preflight["template"].(map[string]any)
	assertExactMapKeys(t, template,
		"id", "name", "modified", "project_id", "inventory_id", "playbook", "job_type", "scm_branch",
		"timeout", "forks", "job_slice_count", "allow_simultaneous", "diff_mode", "job_tags", "skip_tags",
		"survey_enabled", "credential_ids", "execution_environment_id", "prompt_on_launch")
	if template["timeout"] != "900" || template["forks"] != "20" || template["job_slice_count"] != "1" {
		t.Fatalf("template numeric settings must be strings: %#v", template)
	}
	prompt := template["prompt_on_launch"].(map[string]any)
	assertExactMapKeys(t, prompt, launchPreflightPromptFieldNames()...)
	if prompt["ask_execution_environment_on_launch"] != true || prompt["ask_variables_on_launch"] != false {
		t.Fatalf("prompt evidence not projected exactly: %#v", prompt)
	}

	credentials := preflight["credentials"].([]any)
	if len(credentials) != 2 {
		t.Fatalf("credential projection = %#v", credentials)
	}
	credential := credentials[0].(map[string]any)
	assertExactMapKeys(t, credential, "id", "name", "modified", "type")
	if credential["modified"] != "2026-07-14T19:30:00Z" {
		t.Fatalf("credential version evidence = %#v", credential)
	}
	assertExactMapKeys(t, credential["type"].(map[string]any), "id", "name", "kind")

	environment := preflight["execution_environment"].(map[string]any)
	assertExactMapKeys(t, environment, "id", "name", "image_reference", "image_digest")
	if environment["image_digest"] != "sha256:"+strings.Repeat("b", 64) {
		t.Fatalf("execution environment digest = %#v", environment)
	}

	hosts := preflight["selected_hosts"].([]any)
	if len(hosts) != 1 {
		t.Fatalf("selected_hosts = %#v", hosts)
	}
	host := hosts[0].(map[string]any)
	assertExactMapKeys(t, host,
		"membership_id", "controller_id", "inventory_id", "awx_host_id", "canonical_device_uid", "host_name",
		"ansible_host", "enabled", "membership_generation", "source_fingerprint", "identity_variables_digest")
	if host["ansible_host"] != "192.168.2.22" || !validBareSHA256Digest(host["identity_variables_digest"].(string)) {
		t.Fatalf("selected host projection = %#v", host)
	}

	decodedRequest, err := decodeLaunchPreflightRequest(validLaunchPreflightArgs())
	if err != nil {
		t.Fatalf("decode expected request: %v", err)
	}
	requestDigest, err := canonicalDigest(decodedRequest)
	if err != nil || requestDigest != payload["request_digest"] {
		t.Fatalf("request digest mismatch: got=%q want=%q err=%v", payload["request_digest"], requestDigest, err)
	}

	// The plugin only uses selector-bound individual host paths. It must never
	// fall back to an inventory-wide, paginated endpoint that can broaden the
	// controller read scope.
	wantPaths := []string{
		"/api/v2/job_templates/42/",
		"/api/v2/job_templates/42/survey_spec/",
		"/api/v2/projects/7/",
		"/api/v2/inventories/8/",
		"/api/v2/credentials/101/",
		"/api/v2/credentials/102/",
		"/api/v2/execution_environments/9/",
		"/api/v2/hosts/201/",
		"/api/v2/job_templates/42/",
	}
	if len(fake.requests) != len(wantPaths) {
		t.Fatalf("request count = %d, want %d", len(fake.requests), len(wantPaths))
	}
	for index, request := range fake.requests {
		if request.Method != http.MethodGet || len(request.Body) != 0 || !strings.HasSuffix(request.URL, wantPaths[index]) {
			t.Fatalf("request[%d] = %#v, want GET %s without body", index, request, wantPaths[index])
		}
		if strings.Contains(request.URL, "/inventories/8/hosts/") {
			t.Fatalf("preflight used broad inventory host path: %q", request.URL)
		}
		if request.Headers["Authorization"] != "Bearer broker-sentinel" {
			t.Fatalf("request[%d] authorization = %q", index, request.Headers["Authorization"])
		}
	}
}

func TestRunFetchLaunchPreflightRejectsNonCanonicalOrUnboundedRequestBeforeHTTP(t *testing.T) {
	tests := []struct {
		name string
		args func() map[string]any
	}{
		{
			name: "numeric ID is rejected",
			args: func() map[string]any {
				args := validLaunchPreflightArgs()
				args["template_id"] = float64(42)
				return args
			},
		},
		{
			name: "unknown field is rejected",
			args: func() map[string]any {
				args := validLaunchPreflightArgs()
				args["credential_broker"] = "must-not-be-a-domain-input"
				return args
			},
		},
		{
			name: "credential IDs must already be sorted and unique",
			args: func() map[string]any {
				args := validLaunchPreflightArgs()
				args["credential_ids"] = []any{"102", "101"}
				return args
			},
		},
		{
			name: "selected hosts have a hard bound",
			args: func() map[string]any {
				args := validLaunchPreflightArgs()
				targets := make([]any, 0, maxLaunchPreflightSelectedHosts+1)
				for id := 1; id <= maxLaunchPreflightSelectedHosts+1; id++ {
					target := validLaunchPreflightTarget()
					target["awx_host_id"] = fmt.Sprintf("%d", id)
					target["membership_id"] = fmt.Sprintf("00000000-0000-7000-8000-%012d", id)
					targets = append(targets, target)
				}
				args["selected_hosts"] = targets
				return args
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeHTTPClient{}
			swapHTTP(t, fake)
			result := dispatch(Config{
				BaseURL:  "https://awx.example.test",
				APIToken: "broker-sentinel",
				Verb:     launchPreflightVerb,
				Args:     test.args(),
			})
			if result.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", result.Status)
			}
			if len(fake.requests) != 0 {
				t.Fatalf("invalid preflight request made %d controller calls", len(fake.requests))
			}
			if strings.Contains(result.Details, "credential_broker") || strings.Contains(result.Details, "must-not-be-a-domain-input") {
				t.Fatalf("unsafe request data crossed error boundary: %s", result.Details)
			}
		})
	}
}

func TestRunFetchLaunchPreflightPreservesInt64MembershipGenerations(t *testing.T) {
	previousDigest := ""
	for _, generation := range []string{"2147483648", "1800000000000000000", "1800000000000000001", "9223372036854775807"} {
		t.Run(generation, func(t *testing.T) {
			template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
			fake := &scriptedHTTPClient{responses: launchPreflightResponses(t, template, template)}
			swapHTTP(t, fake)

			args := validLaunchPreflightArgs()
			args["selected_hosts"].([]any)[0].(map[string]any)["membership_generation"] = generation
			// Config.Args crosses a generic JSON decoder before reaching the plugin.
			var decodedArgs map[string]any
			if err := json.Unmarshal(mustLaunchPreflightJSON(t, args), &decodedArgs); err != nil {
				t.Fatal(err)
			}
			result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: decodedArgs})
			if result.Status != sdk.StatusOK {
				t.Fatalf("preflight failed: %s", result.Summary)
			}
			var payload map[string]any
			if err := json.Unmarshal([]byte(result.Details), &payload); err != nil {
				t.Fatal(err)
			}
			host := payload["preflight"].(map[string]any)["selected_hosts"].([]any)[0].(map[string]any)
			if host["membership_generation"] != generation {
				t.Fatalf("generation lost precision: got %#v, want %q", host["membership_generation"], generation)
			}
			request, err := decodeLaunchPreflightRequest(decodedArgs)
			if err != nil {
				t.Fatal(err)
			}
			digest, err := canonicalDigest(request)
			if err != nil || digest != payload["request_digest"] || digest == previousDigest {
				t.Fatalf("generation request digest mismatch: got=%q previous=%q err=%v", payload["request_digest"], previousDigest, err)
			}
			previousDigest = digest
		})
	}
}

func TestRunFetchLaunchPreflightRejectsInvalidMembershipGenerationsBeforeHTTP(t *testing.T) {
	for _, generation := range []any{"0", "-1", "01", "+1", "1.0", "1e9", " 1", "1\n", "9223372036854775808", 1, float64(1), nil} {
		t.Run(fmt.Sprintf("%T_%v", generation, generation), func(t *testing.T) {
			fake := &fakeHTTPClient{}
			swapHTTP(t, fake)
			args := validLaunchPreflightArgs()
			args["selected_hosts"].([]any)[0].(map[string]any)["membership_generation"] = generation
			result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: args})
			if result.Status != sdk.StatusCritical || len(fake.requests) != 0 {
				t.Fatalf("invalid generation made %d controller calls, status=%s", len(fake.requests), result.Status)
			}
		})
	}
}

func TestDecodeLaunchPreflightRequestKeepsAWXObjectIDsWithinInt32(t *testing.T) {
	for _, field := range []string{"template_id", "project_id", "inventory_id", "execution_environment_id", "awx_host_id"} {
		t.Run(field, func(t *testing.T) {
			args := validLaunchPreflightArgs()
			if field == "awx_host_id" {
				args["selected_hosts"].([]any)[0].(map[string]any)[field] = "2147483648"
			} else {
				args[field] = "2147483648"
			}
			if _, err := decodeLaunchPreflightRequest(args); err == nil {
				t.Fatal("accepted an AWX object ID beyond signed 32-bit range")
			}
		})
	}
}

func TestRunFetchLaunchPreflightRejectsSurveyDefaultBeforeDependentReads(t *testing.T) {
	template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	responses := launchPreflightResponses(t, template, template)
	responses[1] = launchPreflightSurveyResponse(t, launchPreflightTestSecret)
	fake := &scriptedHTTPClient{responses: responses}
	swapHTTP(t, fake)

	result := dispatch(Config{
		BaseURL:  "https://awx.example.test",
		APIToken: "broker-sentinel",
		Verb:     launchPreflightVerb,
		Args:     validLaunchPreflightArgs(),
	})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if len(fake.requests) != 2 {
		t.Fatalf("unreviewed survey default must stop after the survey read, got %d requests", len(fake.requests))
	}
	if strings.Contains(result.Details, launchPreflightTestSecret) || strings.Contains(result.Summary, launchPreflightTestSecret) {
		t.Fatalf("survey default leaked into failure: summary=%q details=%q", result.Summary, result.Details)
	}
}

func TestLaunchPreflightSurveyDefaultPolicyIsFailClosed(t *testing.T) {
	for _, test := range []struct {
		name         string
		defaultValue any
		setDefault   bool
		allow        bool
	}{
		{name: "default omitted", allow: true},
		{name: "default null", defaultValue: nil, setDefault: true, allow: true},
		{name: "default empty string", defaultValue: "", setDefault: true, allow: true},
		{name: "default text", defaultValue: "unreviewed", setDefault: true, allow: false},
		{name: "default zero", defaultValue: 0, setDefault: true, allow: false},
		{name: "default false", defaultValue: false, setDefault: true, allow: false},
		{name: "default empty collection", defaultValue: []any{}, setDefault: true, allow: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			field := map[string]any{"variable": "release"}
			if test.setDefault {
				field["default"] = test.defaultValue
			}
			body := mustLaunchPreflightJSON(t, map[string]any{"spec": []any{field}})
			if got := launchPreflightSurveyDefaultsEmpty(body); got != test.allow {
				t.Fatalf("launchPreflightSurveyDefaultsEmpty() = %t, want %t", got, test.allow)
			}
		})
	}
}

func TestRunFetchLaunchPreflightFailsClosedWhenAnyPromptFlagIsMissing(t *testing.T) {
	for _, promptField := range launchPreflightPromptFieldNames() {
		t.Run(promptField, func(t *testing.T) {
			fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
				"/api/v2/job_templates/42/": {
					Status: http.StatusOK,
					Body:   launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", promptField),
				},
			}}
			swapHTTP(t, fake)
			result := dispatch(Config{
				BaseURL:  "https://awx.example.test",
				APIToken: "broker-sentinel",
				Verb:     launchPreflightVerb,
				Args:     validLaunchPreflightArgs(),
			})
			if result.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", result.Status)
			}
			if len(fake.requests) != 1 {
				t.Fatalf("missing prompt flag must fail at initial template read, got %d requests", len(fake.requests))
			}
		})
	}
}

func TestRunFetchLaunchPreflightRejectsTemplateVersionDriftWithoutLeakingResponse(t *testing.T) {
	firstTemplate := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	lastTemplate := launchPreflightTemplateBody(t, "2026-07-14T20:01:00Z", "")
	fake := &scriptedHTTPClient{responses: launchPreflightResponses(t, firstTemplate, lastTemplate)}
	swapHTTP(t, fake)

	result := dispatch(Config{
		BaseURL:  "https://awx.example.test",
		APIToken: "broker-sentinel",
		Verb:     launchPreflightVerb,
		Args:     validLaunchPreflightArgs(),
	})
	if result.Status != sdk.StatusCritical || !strings.Contains(result.Summary, "changed during preflight") {
		t.Fatalf("expected version-drift failure, got status=%s summary=%q", result.Status, result.Summary)
	}
	if strings.Contains(result.Details, launchPreflightTestSecret) || strings.Contains(result.Summary, launchPreflightTestSecret) {
		t.Fatalf("version drift retained controller response data: summary=%q details=%q", result.Summary, result.Details)
	}
	if len(fake.requests) != 9 {
		t.Fatalf("template drift must happen after complete fixed read set, got %d requests", len(fake.requests))
	}
}

func TestRunFetchLaunchPreflightRejectsOversizedHostVariables(t *testing.T) {
	firstTemplate := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	responses := launchPreflightResponses(t, firstTemplate, firstTemplate)
	responses[7] = &sdk.HTTPResponse{
		Status: http.StatusOK,
		Body: mustLaunchPreflightJSON(t, map[string]any{
			"id":        201,
			"inventory": 8,
			"name":      "web01.example.test",
			"enabled":   true,
			"variables": "ansible_host: 192.168.2.22\napi_token: " + strings.Repeat("x", maxLaunchPreflightHostVariablesBytes),
		}),
	}
	fake := &scriptedHTTPClient{responses: responses}
	swapHTTP(t, fake)

	result := dispatch(Config{
		BaseURL:  "https://awx.example.test",
		APIToken: "broker-sentinel",
		Verb:     launchPreflightVerb,
		Args:     validLaunchPreflightArgs(),
	})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if strings.Contains(result.Details, "api_token") || strings.Contains(result.Details, strings.Repeat("x", 64)) {
		t.Fatalf("oversized variable body leaked into result: %s", result.Details)
	}
	if len(fake.requests) != 8 {
		t.Fatalf("oversized host variables should stop before post-template read, got %d requests", len(fake.requests))
	}
}

func TestRunFetchLaunchPreflightRejectsMutableExecutionEnvironmentImage(t *testing.T) {
	template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	responses := launchPreflightResponses(t, template, template)
	responses[6] = &sdk.HTTPResponse{Status: http.StatusOK, Body: mustLaunchPreflightJSON(t, map[string]any{
		"id": 9, "name": "Mutable EE", "image": "registry.example.test/serviceradar/ee:latest",
	})}
	fake := &scriptedHTTPClient{responses: responses}
	swapHTTP(t, fake)

	result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if len(fake.requests) != 7 {
		t.Fatalf("mutable execution-environment image should stop at its read, got %d requests", len(fake.requests))
	}
}

func TestRunFetchLaunchPreflightIncludesCredentialVersionInDigest(t *testing.T) {
	template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	firstFake := &scriptedHTTPClient{responses: launchPreflightResponses(t, template, template)}
	swapHTTP(t, firstFake)
	first := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if first.Status != sdk.StatusOK {
		t.Fatalf("first preflight failed: %s", first.Summary)
	}

	changedResponses := launchPreflightResponses(t, template, template)
	changedResponses[4] = &sdk.HTTPResponse{Status: http.StatusOK, Body: launchPreflightCredentialBody(
		t, 101, "Machine SSH", "ssh", "2026-07-14T19:35:00Z",
	)}
	secondFake := &scriptedHTTPClient{responses: changedResponses}
	swapHTTP(t, secondFake)
	second := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if second.Status != sdk.StatusOK {
		t.Fatalf("changed credential preflight failed: %s", second.Summary)
	}
	if launchPreflightResultDigest(t, first) == launchPreflightResultDigest(t, second) {
		t.Fatal("credential version change did not alter the preflight digest")
	}
}

func TestRunFetchLaunchPreflightRejectsProjectUpdateOnLaunch(t *testing.T) {
	template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	responses := launchPreflightResponses(t, template, template)
	responses[2] = &sdk.HTTPResponse{Status: http.StatusOK, Body: launchPreflightProjectBody(t, true, true)}
	fake := &scriptedHTTPClient{responses: responses}
	swapHTTP(t, fake)

	result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("project update-on-launch must fail at the project read, got %d requests", len(fake.requests))
	}
}

func TestRunFetchLaunchPreflightRejectsDirtyProjectCheckout(t *testing.T) {
	template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	responses := launchPreflightResponses(t, template, template)
	responses[2] = &sdk.HTTPResponse{Status: http.StatusOK, Body: launchPreflightProjectBody(t, false, false)}
	fake := &scriptedHTTPClient{responses: responses}
	swapHTTP(t, fake)

	result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("dirty project checkout must fail at the project read, got %d requests", len(fake.requests))
	}
}

func TestRunFetchLaunchPreflightRejectsAmbiguousHostVariables(t *testing.T) {
	template := launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", "")
	responses := launchPreflightResponses(t, template, template)
	responses[7] = &sdk.HTTPResponse{Status: http.StatusOK, Body: mustLaunchPreflightJSON(t, map[string]any{
		"id": 201, "inventory": 8, "name": "web01.example.test", "enabled": true,
		"variables": "ansible_host: 192.168.2.22\nansible_ssh_host: 192.168.2.99\n",
	})}
	fake := &scriptedHTTPClient{responses: responses}
	swapHTTP(t, fake)

	result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if len(fake.requests) != 8 {
		t.Fatalf("ambiguous host variables should stop at the host read, got %d requests", len(fake.requests))
	}
}

func TestRunFetchLaunchPreflightRejectsDuplicateControllerJSONKeys(t *testing.T) {
	template := string(launchPreflightTemplateBody(t, "2026-07-14T20:00:00Z", ""))
	duplicated := strings.Replace(template, `"id":42`, `"id":42,"id":42`, 1)
	if duplicated == template {
		t.Fatal("test fixture did not gain a duplicate JSON key")
	}
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/job_templates/42/": {Status: http.StatusOK, Body: []byte(duplicated)},
	}}
	swapHTTP(t, fake)

	result := dispatch(Config{BaseURL: "https://awx.example.test", APIToken: "broker-sentinel", Verb: launchPreflightVerb, Args: validLaunchPreflightArgs()})
	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", result.Status)
	}
	if len(fake.requests) != 1 {
		t.Fatalf("duplicate controller JSON should fail at the first read, got %d requests", len(fake.requests))
	}
}

func TestLaunchPreflightCanonicalJSONMatchesElixirSafeSubset(t *testing.T) {
	encoded, err := canonicalJSON(map[string]any{"z": true, "a": "<>&"})
	if err != nil {
		t.Fatalf("canonical JSON error: %v", err)
	}
	if got, want := string(encoded), `{"a":"<>&","z":true}`; got != want {
		t.Fatalf("canonical JSON = %q, want %q", got, want)
	}
	if _, err := canonicalJSON(map[string]any{"number": 1}); err == nil {
		t.Fatal("canonical JSON accepted a numeric value instead of the string-only preflight contract")
	}
}

func validLaunchPreflightArgs() map[string]any {
	return map[string]any{
		"schema":                   launchPreflightRequestSchema,
		"controller_id":            "018f0000-0000-7000-8000-000000000001",
		"template_id":              "42",
		"project_id":               "7",
		"inventory_id":             "8",
		"credential_ids":           []any{"101", "102"},
		"execution_environment_id": "9",
		"selected_hosts":           []any{validLaunchPreflightTarget()},
	}
}

func validLaunchPreflightTarget() map[string]any {
	return map[string]any{
		"membership_id":         "018f0000-0000-7000-8000-000000000201",
		"controller_id":         "018f0000-0000-7000-8000-000000000001",
		"inventory_id":          "8",
		"awx_host_id":           "201",
		"canonical_device_uid":  "device-web01",
		"host_name":             "web01.example.test",
		"ansible_host":          "192.168.2.22",
		"enabled":               true,
		"membership_generation": "5",
		"source_fingerprint":    "sha256:" + strings.Repeat("a", 64),
	}
}

func launchPreflightPromptFieldNames() []string {
	return []string{
		"ask_credential_on_launch",
		"ask_diff_mode_on_launch",
		"ask_execution_environment_on_launch",
		"ask_forks_on_launch",
		"ask_instance_groups_on_launch",
		"ask_inventory_on_launch",
		"ask_job_slice_count_on_launch",
		"ask_job_type_on_launch",
		"ask_labels_on_launch",
		"ask_limit_on_launch",
		"ask_scm_branch_on_launch",
		"ask_skip_tags_on_launch",
		"ask_tags_on_launch",
		"ask_timeout_on_launch",
		"ask_variables_on_launch",
		"ask_verbosity_on_launch",
	}
}

func launchPreflightTemplateBody(t *testing.T, modified, omit string) []byte {
	t.Helper()
	row := map[string]any{
		"id":                    42,
		"name":                  "Deploy",
		"modified":              modified,
		"project":               7,
		"inventory":             8,
		"playbook":              "playbooks/deploy.yml",
		"job_type":              "run",
		"scm_branch":            "main",
		"timeout":               900,
		"forks":                 20,
		"job_slice_count":       1,
		"allow_simultaneous":    false,
		"diff_mode":             true,
		"job_tags":              "deploy",
		"skip_tags":             "destructive",
		"survey_enabled":        true,
		"execution_environment": 9,
		"summary_fields": map[string]any{
			"credentials": []any{map[string]any{"id": 101}, map[string]any{"id": 102}},
		},
		"extra_vars": "api_token: " + launchPreflightTestSecret,
	}
	for index, field := range launchPreflightPromptFieldNames() {
		row[field] = index%2 == 0
	}
	// Pin two values used by the assertion above instead of relying on the
	// incidental position in the complete supported-flag list.
	row["ask_execution_environment_on_launch"] = true
	row["ask_variables_on_launch"] = false
	if omit != "" {
		delete(row, omit)
	}
	return mustLaunchPreflightJSON(t, row)
}

func launchPreflightResponses(t *testing.T, firstTemplate, lastTemplate []byte) []*sdk.HTTPResponse {
	t.Helper()
	return []*sdk.HTTPResponse{
		{Status: http.StatusOK, Body: firstTemplate},
		launchPreflightSurveyResponse(t, ""),
		{Status: http.StatusOK, Body: launchPreflightProjectBody(t, false, true)},
		{Status: http.StatusOK, Body: mustLaunchPreflightJSON(t, map[string]any{
			"id": 8, "name": "Production", "modified": "2026-07-14T18:00:00Z", "kind": "", "variables": launchPreflightTestSecret,
		})},
		{Status: http.StatusOK, Body: launchPreflightCredentialBody(t, 101, "Machine SSH", "ssh", "2026-07-14T19:30:00Z")},
		{Status: http.StatusOK, Body: launchPreflightCredentialBody(t, 102, "Vault", "vault", "2026-07-14T19:31:00Z")},
		{Status: http.StatusOK, Body: mustLaunchPreflightJSON(t, map[string]any{
			"id": 9, "name": "Approved EE", "image": "registry.example.test/serviceradar/ee@sha256:" + strings.Repeat("b", 64),
			"description": launchPreflightTestSecret,
		})},
		{Status: http.StatusOK, Body: mustLaunchPreflightJSON(t, map[string]any{
			"id": 201, "inventory": 8, "name": "Web01.EXAMPLE.test", "enabled": true,
			"variables": "ansible_host: 192.168.2.22\napi_token: " + launchPreflightTestSecret + "\n",
		})},
		{Status: http.StatusOK, Body: lastTemplate},
	}
}

func launchPreflightSurveyResponse(t *testing.T, defaultValue any) *sdk.HTTPResponse {
	t.Helper()
	return &sdk.HTTPResponse{Status: http.StatusOK, Body: mustLaunchPreflightJSON(t, map[string]any{
		"name": "Launch survey",
		"spec": []any{map[string]any{
			"variable":             "version",
			"question_name":        "Release version",
			"question_description": "Reviewed release input",
			"type":                 "text",
			"required":             true,
			"min":                  1,
			"max":                  20,
			"default":              defaultValue,
		}},
	})}
}

func launchPreflightCredentialBody(t *testing.T, id int, name, kind, modified string) []byte {
	t.Helper()
	return mustLaunchPreflightJSON(t, map[string]any{
		"id": id, "name": name, "modified": modified, "credential_type": 1, "kind": kind,
		"summary_fields": map[string]any{
			"credential_type": map[string]any{"id": 1, "name": "Machine"},
		},
		"inputs": map[string]any{"password": launchPreflightTestSecret},
	})
}

func launchPreflightProjectBody(t *testing.T, updateOnLaunch, clean bool) []byte {
	t.Helper()
	return mustLaunchPreflightJSON(t, map[string]any{
		"id": 7, "name": "Deploy project", "modified": "2026-07-14T19:00:00Z", "scm_type": "git",
		"scm_url": "https://git.example.test/ops/deploy.git", "scm_branch": "main", "scm_revision": "abc123",
		"scm_clean": clean, "scm_update_on_launch": updateOnLaunch, "status": "successful",
		"related": map[string]any{"secret": launchPreflightTestSecret},
	})
}

func mustLaunchPreflightJSON(t *testing.T, value any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal AWX fixture: %v", err)
	}
	return encoded
}

func containsJSONFloat(value any) bool {
	switch typed := value.(type) {
	case float64:
		return true
	case []any:
		for _, nested := range typed {
			if containsJSONFloat(nested) {
				return true
			}
		}
	case map[string]any:
		for _, nested := range typed {
			if containsJSONFloat(nested) {
				return true
			}
		}
	}
	return false
}

func launchPreflightResultDigest(t *testing.T, result *sdk.Result) string {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal([]byte(result.Details), &payload); err != nil {
		t.Fatalf("decode preflight result: %v", err)
	}
	digest, ok := payload["preflight_digest"].(string)
	if !ok || !validBareSHA256Digest(digest) {
		t.Fatalf("preflight result missing digest: %#v", payload)
	}
	return digest
}

func TestLaunchPreflightCredentialUsesTopLevelKind(t *testing.T) {
	for _, tc := range []struct {
		name        string
		kind        any
		summaryKind any
		expected    bool
	}{
		{"controller shape", "ssh", nil, true},
		{"consistent summary", "ssh", "ssh", true},
		{"missing kind", nil, "ssh", false},
		{"mismatched summary", "ssh", "vault", false},
		{"non-string kind", true, nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := launchPreflightCredentialBody(t, 17, "Example machine", "ssh", "2030-01-02T03:04:05Z")
			var row map[string]any
			if err := json.Unmarshal(raw, &row); err != nil {
				t.Fatal(err)
			}
			row["kind"] = tc.kind
			if tc.summaryKind != nil {
				row["summary_fields"].(map[string]any)["credential_type"].(map[string]any)["kind"] = tc.summaryKind
			}
			object, ok := launchPreflightResponseObject(mustLaunchPreflightJSON(t, row))
			if !ok {
				t.Fatal("invalid fixture")
			}
			projection, ok := projectLaunchPreflightCredential(object)
			if ok != tc.expected {
				t.Fatalf("accepted=%v want=%v", ok, tc.expected)
			}
			if ok && projection.Type.Kind != "ssh" {
				t.Fatalf("wrong kind: %q", projection.Type.Kind)
			}
		})
	}
}
