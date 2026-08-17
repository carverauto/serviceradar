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

package manifestschema_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/tools/addon-manifest-validator/internal/manifestschema"
)

// repoFile resolves a path to a file checked in elsewhere in the repo.
//
// Under Bazel the file is a declared data dep and lives in the runfiles tree, which
// TEST_SRCDIR/TEST_WORKSPACE points at ("_main" covers bzlmod's default when
// TEST_WORKSPACE is unset). Under a plain `go test` there are no runfiles, so fall back
// to walking up from the package directory.
//
// The callers deliberately treat a miss as a FAILURE rather than skipping. These two
// tests are the only guard against the shipped manifest and the embedded schema drifting
// from the canonical files under addons/, and a guard that silently skips when it cannot
// find its input guards nothing -- which is exactly the state this replaced.
func repoFile(t *testing.T, parts ...string) string {
	t.Helper()

	if srcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); srcDir != "" {
		for _, workspace := range []string{strings.TrimSpace(os.Getenv("TEST_WORKSPACE")), "_main"} {
			if workspace == "" {
				continue
			}

			candidate := filepath.Join(append([]string{srcDir, workspace}, parts...)...)
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}

	return filepath.Join(append([]string{"..", "..", "..", "..", ".."}, parts...)...)
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()

	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("reading fixture %s: %v", name, err)
	}

	return data
}

func TestValidManifestPasses(t *testing.T) {
	res, err := manifestschema.ValidateYAML(readFixture(t, "valid.yaml"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !res.OK() {
		t.Fatalf("expected valid manifest to pass, got %d errors: %v", len(res.Errors), res.Errors)
	}
}

func TestAgentCapabilitiesRequirementValidates(t *testing.T) {
	manifest := `
id: netprobe
name: Host Network Visibility
version: 0.2.23
kind: native
delivery: pushed-artifact
supervision: systemd-service
capabilities: [host-network-visibility]
requires:
  base_agent: ">=1.2.0"
  platforms: [linux]
  agent_capabilities: [host-network-visibility]
  os_capabilities: [CAP_NET_RAW, CAP_BPF]
exec: {binary: serviceradar-netprobe, install_path: /opt/serviceradar}
config_schema: config.schema.json
`

	res, err := manifestschema.ValidateYAML([]byte(manifest))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !res.OK() {
		t.Fatalf("expected agent_capabilities requirement to pass, got %d errors: %v", len(res.Errors), res.Errors)
	}
}

func TestInvalidManifestFailsClosed(t *testing.T) {
	res, err := manifestschema.ValidateYAML(readFixture(t, "invalid_bad_delivery.yaml"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if res.OK() {
		t.Fatal("expected invalid manifest to fail validation, but it passed")
	}

	joined := joinErrors(res)

	if !strings.Contains(joined, "delivery") {
		t.Errorf("expected a violation mentioning the unknown delivery value; got:\n%s", joined)
	}

	if !strings.Contains(joined, "config_schema") {
		t.Errorf("expected a violation for the missing required config_schema field; got:\n%s", joined)
	}
}

// TestRepoSampleManifestIsValid guards the shipped first-party manifest so the
// schema and the de-facto manifest cannot drift out of sync.
func TestRepoSampleManifestIsValid(t *testing.T) {
	path := repoFile(t, "addons", "sample-addon", "addon.yaml")

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("sample addon.yaml not readable at %s: %v", path, err)
	}

	res, err := manifestschema.ValidateYAML(data)
	if err != nil {
		t.Fatalf("unexpected error validating sample manifest: %v", err)
	}

	if !res.OK() {
		t.Fatalf("shipped sample addon.yaml is invalid against the schema: %v", res.Errors)
	}
}

func TestSignalSchemasValidate(t *testing.T) {
	manifest := `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
signal_schemas:
  - id: com.carverauto.sample.dns_activity
    version: 1.0.0
    signal_type: event
    payload_kind: ocsf_event
    payload_schema: schemas/dns_activity.schema.json
    display_contract: display/dns_activity.display.json
    display_contract_id: com.carverauto.sample.dns_activity.display
    display_contract_version: 1.0.0
    ocsf_schema_version: 1.5.0
    class_uid: 4003
    type_uid: 400301
`

	res, err := manifestschema.ValidateYAML([]byte(manifest))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !res.OK() {
		t.Fatalf("expected manifest with signal_schemas to pass, got %d errors: %v", len(res.Errors), res.Errors)
	}
}

func TestProducerSchedulesValidate(t *testing.T) {
	manifest := `
id: advisory-producer
name: Advisory Feed Producer
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [advisory-feed:v1, producer-schedule:v1]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: serviceradar-advisory-producer, install_path: /opt/serviceradar}
config_schema: config.schema.json
producer_schedules:
  - schedule_id: cisa_kev.refresh
    label: Refresh CISA KEV
    action_id: cisa_kev.refresh
    command_type: addon.run_command
    default_cadence_seconds: 21600
    min_cadence_seconds: 300
    max_cadence_seconds: 2592000
    schedule_type: interval
    jitter_seconds: 300
    dispatch_scope: assignment
    timeout_seconds: 900
    settings_schema:
      type: object
`

	res, err := manifestschema.ValidateYAML([]byte(manifest))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !res.OK() {
		t.Fatalf("expected manifest with producer_schedules to pass, got %d errors: %v", len(res.Errors), res.Errors)
	}
}

func TestResourceLimitsValidate(t *testing.T) {
	manifest := `
id: anomaly
name: Edge Anomaly Detector
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [metric-feed:v1]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: serviceradar-anomaly, install_path: /opt/serviceradar}
config_schema: config.schema.json
resources:
  cpu_max_percent: 50
  memory_high_bytes: 67108864
  memory_max_bytes: 134217728
  tasks_max: 16
  slice: serviceradar-addons.slice
`

	res, err := manifestschema.ValidateYAML([]byte(manifest))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !res.OK() {
		t.Fatalf("expected manifest with resource limits to pass, got %d errors: %v", len(res.Errors), res.Errors)
	}
}

// TestEmbeddedSchemaMatchesCanonical guards against the embedded copy drifting
// away from the canonical schema published under addons/.
func TestEmbeddedSchemaMatchesCanonical(t *testing.T) {
	path := repoFile(t, "addons", "native-addon-manifest.schema.json")

	canonical, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("canonical schema not readable at %s: %v", path, err)
	}

	if string(canonical) != string(manifestschema.SchemaJSON) {
		t.Fatalf("embedded schema has drifted from canonical %s; re-copy the canonical schema into the package", path)
	}
}

func TestTargetedViolations(t *testing.T) {
	tests := []struct {
		name        string
		manifest    string
		wantSubstrs []string
	}{
		{
			name: "missing required id",
			manifest: `
name: x
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
`,
			wantSubstrs: []string{"id", "required"},
		},
		{
			name: "unknown top-level property",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
surprise: nope
`,
			wantSubstrs: []string{"surprise", "unknown property"},
		},
		{
			name: "unknown supervision enum",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: cron-daemon
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
`,
			wantSubstrs: []string{"supervision", "allowed values"},
		},
		{
			name: "empty capabilities array",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: []
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
`,
			wantSubstrs: []string{"capabilities", "minItems"},
		},
		{
			name: "relative install_path rejected",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: relative/path}
config_schema: config.schema.json
`,
			wantSubstrs: []string{"install_path", "pattern"},
		},
		{
			name: "unknown platform enum",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [solaris]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
`,
			wantSubstrs: []string{"platforms[0]", "allowed values"},
		},
		{
			name: "bad version pattern",
			manifest: `
id: x
name: X
version: not-semver
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
`,
			wantSubstrs: []string{"version", "pattern"},
		},
		{
			name: "signal schema missing display contract",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
signal_schemas:
  - id: com.carverauto.sample.dns_activity
    version: 1.0.0
    signal_type: event
    payload_kind: ocsf_event
    payload_schema: schemas/dns_activity.schema.json
    display_contract_id: com.carverauto.sample.dns_activity.display
    display_contract_version: 1.0.0
`,
			wantSubstrs: []string{"signal_schemas[0]", "display_contract", "required"},
		},
		{
			name: "signal schema rejects unsupported signal type",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
signal_schemas:
  - id: com.carverauto.sample.dns_activity
    version: 1.0.0
    signal_type: metric
    payload_kind: ocsf_event
    payload_schema: schemas/dns_activity.schema.json
    display_contract: display/dns_activity.display.json
    display_contract_id: com.carverauto.sample.dns_activity.display
    display_contract_version: 1.0.0
`,
			wantSubstrs: []string{"signal_type", "allowed values"},
		},
		{
			name: "signal schema rejects unsafe bundle path",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
signal_schemas:
  - id: com.carverauto.sample.dns_activity
    version: 1.0.0
    signal_type: event
    payload_kind: ocsf_event
    payload_schema: ../dns_activity.schema.json
    display_contract: display/dns_activity.display.json
    display_contract_id: com.carverauto.sample.dns_activity.display
    display_contract_version: 1.0.0
`,
			wantSubstrs: []string{"payload_schema", "not"},
		},
		{
			name: "resource limit minimums",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
resources:
  cpu_max_percent: 0
  memory_max_bytes: 0
`,
			wantSubstrs: []string{"resources.cpu_max_percent", "minimum", "resources.memory_max_bytes"},
		},
		{
			name: "resource limit unknown property",
			manifest: `
id: x
name: X
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities: [sample]
requires: {base_agent: ">=1.0.0", platforms: [linux]}
exec: {binary: b, install_path: /opt/b}
config_schema: config.schema.json
resources:
  nice: 10
`,
			wantSubstrs: []string{"resources.nice", "unknown property"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			res, err := manifestschema.ValidateYAML([]byte(tc.manifest))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if res.OK() {
				t.Fatal("expected manifest to fail validation, but it passed")
			}

			joined := joinErrors(res)
			for _, want := range tc.wantSubstrs {
				if !strings.Contains(joined, want) {
					t.Errorf("expected a violation containing %q; got:\n%s", want, joined)
				}
			}
		})
	}
}

func joinErrors(res *manifestschema.Result) string {
	parts := make([]string, 0, len(res.Errors))
	for _, e := range res.Errors {
		parts = append(parts, e.String())
	}

	return strings.Join(parts, "\n")
}
