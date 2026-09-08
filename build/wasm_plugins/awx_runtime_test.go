package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

// These fixtures are invented independently of any controller. Exercising the
// built Wasm is essential: native Go runs package initializers, whereas the
// agent calls run_check without WASI _start, which would close the module.
func TestAWXPreflightWithoutWASIStart(t *testing.T) {
	wasmPath, err := runfiles.Rlocation(filepath.Join(os.Getenv("TEST_WORKSPACE"), "build/wasm_plugins/awx.wasm"))
	if err != nil {
		t.Fatal(err)
	}
	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name           string
		extraField     bool
		generation     string
		surveyVariable string
		wantCalls      int
		wantStatus     string
	}{
		{name: "canonical projection", generation: "1800000000000000001", surveyVariable: "release_version", wantCalls: 8, wantStatus: "OK"},
		{name: "unknown selector denied", extraField: true, generation: "1800000000000000001", surveyVariable: "release_version", wantCalls: 0, wantStatus: "CRITICAL"},
		{name: "generation overflow denied", generation: "9223372036854775808", surveyVariable: "release_version", wantCalls: 0, wantStatus: "CRITICAL"},
		{name: "secret survey denied", generation: "1800000000000000001", surveyVariable: "client_secret", wantCalls: 2, wantStatus: "CRITICAL"},
		{name: "reserved survey denied", generation: "1800000000000000001", surveyVariable: "hostvars", wantCalls: 2, wantStatus: "CRITICAL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			config := awxRuntimeConfig(tc.generation)
			if tc.extraField {
				config["args"].(map[string]any)["extra_vars"] = map[string]any{}
			}
			result, calls := runAWXWasm(t, wasm, config, awxRuntimeResponses(tc.surveyVariable))
			if result["status"] != tc.wantStatus || calls != tc.wantCalls {
				t.Fatalf("status=%v calls=%d; want %s/%d; summary=%v", result["status"], calls, tc.wantStatus, tc.wantCalls, result["summary"])
			}
			if tc.wantStatus == "OK" {
				var details map[string]any
				if err := json.Unmarshal([]byte(result["details"].(string)), &details); err != nil {
					t.Fatal(err)
				}
				if details["ok"] != true {
					t.Fatalf("preflight not successful: %v", details)
				}
				hosts := details["preflight"].(map[string]any)["selected_hosts"].([]any)
				if hosts[0].(map[string]any)["membership_generation"] != tc.generation {
					t.Fatal("membership generation lost precision")
				}
				for _, key := range []string{"request_digest", "preflight_digest"} {
					if len(details[key].(string)) != 64 {
						t.Fatalf("invalid %s", key)
					}
				}
			}
		})
	}
}

func awxRuntimeConfig(generation string) map[string]any {
	controller := "11111111-1111-4111-8111-111111111111"
	return map[string]any{"verb": "awx.fetch_launch_preflight", "base_url": "https://controller.example.com", "api_token": "synthetic-placeholder", "args": map[string]any{
		"schema": "serviceradar.awx_launch_preflight_request.v1", "controller_id": controller, "template_id": "11", "project_id": "12", "inventory_id": "13", "credential_ids": []string{"14"}, "execution_environment_id": "15",
		"selected_hosts": []any{map[string]any{"membership_id": "22222222-2222-4222-8222-222222222222", "controller_id": controller, "inventory_id": "13", "awx_host_id": "16", "canonical_device_uid": "sr:33333333-3333-4333-8333-333333333333", "host_name": "host01.example.com", "ansible_host": "192.0.2.10", "enabled": true, "membership_generation": generation, "source_fingerprint": "sha256:" + strings.Repeat("a", 64)}},
	}}
}

func awxRuntimeResponses(surveyVariable string) map[string]any {
	modified := "2030-01-02T03:04:05Z"
	template := map[string]any{"id": 11, "name": "Example template", "modified": modified, "project": 12, "inventory": 13, "playbook": "playbooks/example.yml", "job_type": "run", "scm_branch": "main", "timeout": 0, "forks": 0, "job_slice_count": 1, "allow_simultaneous": false, "diff_mode": false, "job_tags": "", "skip_tags": "", "survey_enabled": true, "execution_environment": 15, "summary_fields": map[string]any{"credentials": []any{map[string]any{"id": 14}}}}
	for _, field := range []string{"credential", "diff_mode", "execution_environment", "forks", "instance_groups", "inventory", "job_slice_count", "job_type", "labels", "limit", "scm_branch", "skip_tags", "tags", "timeout", "variables", "verbosity"} {
		template["ask_"+field+"_on_launch"] = field == "limit"
	}
	return map[string]any{
		"/api/v2/job_templates/11/":             template,
		"/api/v2/job_templates/11/survey_spec/": map[string]any{"name": "Example survey", "spec": []any{map[string]any{"variable": surveyVariable, "question_name": "Example input", "question_description": "", "type": "text", "required": true, "min": 1, "max": 20, "default": ""}}},
		"/api/v2/projects/12/":                  map[string]any{"id": 12, "name": "Example project", "modified": modified, "scm_type": "git", "scm_url": "https://git.example.com/ops/example.git", "scm_branch": "main", "scm_revision": strings.Repeat("c", 40), "scm_clean": true, "scm_update_on_launch": false, "status": "successful"},
		"/api/v2/inventories/13/":               map[string]any{"id": 13, "name": "Example inventory", "modified": modified, "kind": ""},
		"/api/v2/credentials/14/":               map[string]any{"id": 14, "name": "Example credential", "modified": modified, "credential_type": 1, "summary_fields": map[string]any{"credential_type": map[string]any{"id": 1, "name": "Machine", "kind": "ssh"}}},
		"/api/v2/execution_environments/15/":    map[string]any{"id": 15, "name": "Example environment", "image": "registry.example.com/automation@sha256:" + strings.Repeat("b", 64)},
		"/api/v2/hosts/16/":                     map[string]any{"id": 16, "inventory": 13, "name": "host01.example.com", "enabled": true, "variables": "ansible_host: 192.0.2.10\n"},
	}
}

func runAWXWasm(t *testing.T, wasm []byte, config map[string]any, responses map[string]any) (map[string]any, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	runtime := wazero.NewRuntime(ctx)
	defer runtime.Close(ctx)
	if _, err := wasi_snapshot_preview1.Instantiate(ctx, runtime); err != nil {
		t.Fatal(err)
	}
	compiled, err := runtime.CompileModule(ctx, wasm)
	if err != nil {
		t.Fatal(err)
	}
	configJSON, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	calls := 0
	builder := runtime.NewHostModuleBuilder("env")
	for _, definition := range compiled.ImportedFunctions() {
		module, name, _ := definition.Import()
		if module != "env" {
			continue
		}
		builder.NewFunctionBuilder().WithGoModuleFunction(api.GoModuleFunc(func(ctx context.Context, module api.Module, stack []uint64) {
			switch name {
			case "get_config":
				if uint64(len(configJSON)) > stack[1] || !module.Memory().Write(uint32(stack[0]), configJSON) {
					t.Fatal("config exceeds guest buffer")
				}
				stack[0] = uint64(len(configJSON))
			case "submit_result":
				raw, ok := module.Memory().Read(uint32(stack[0]), uint32(stack[1]))
				if !ok {
					t.Fatal("invalid result pointer")
				}
				if result != nil {
					t.Fatal("duplicate result")
				}
				if err := json.Unmarshal(raw, &result); err != nil {
					t.Fatal(err)
				}
				stack[0] = 0
			case "log":
			case "http_request":
				calls++
				raw, ok := module.Memory().Read(uint32(stack[0]), uint32(stack[1]))
				if !ok {
					t.Fatal("invalid request pointer")
				}
				var request struct {
					Method       string `json:"method"`
					URL          string `json:"url"`
					ResponseMode string `json:"response_mode"`
				}
				if err := json.Unmarshal(raw, &request); err != nil {
					t.Fatal(err)
				}
				path := strings.TrimPrefix(request.URL, "https://controller.example.com")
				body, exists := responses[path]
				if !exists || request.Method != "GET" || request.ResponseMode != "status_body" {
					t.Fatalf("unexpected HTTP request: %+v", request)
				}
				encoded, err := json.Marshal(body)
				if err != nil {
					t.Fatal(err)
				}
				response := append([]byte("200\n"), encoded...)
				if uint64(len(response)) > stack[3] || !module.Memory().Write(uint32(stack[2]), response) {
					t.Fatal("response exceeds guest buffer")
				}
				stack[0] = uint64(len(response))
			default:
				t.Fatalf("unexpected host call %s", name)
			}
		}), definition.ParamTypes(), definition.ResultTypes()).Export(name)
	}
	if _, err := builder.Instantiate(ctx); err != nil {
		t.Fatal(err)
	}
	module, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithStartFunctions().WithSysWalltime().WithSysNanotime())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := module.ExportedFunction("run_check").Call(ctx); err != nil {
		t.Fatal(fmt.Errorf("run_check: %w", err))
	}
	if result == nil {
		t.Fatal("plugin did not submit a result")
	}
	return result, calls
}
