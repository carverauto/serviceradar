package terraformprovider

import (
	"archive/zip"
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// Bazel supplies logical runfile paths, never paths into its output cache.
var terraformBinaryRlocation string       //nolint:gochecknoglobals // Bazel injects this declared runfile with -X.
var providerBinaryRlocation string        //nolint:gochecknoglobals // Bazel injects this declared runfile with -X.
var settingsBundleFixtureRlocation string //nolint:gochecknoglobals // Bazel injects this declared runfile with -X.

func TestTerraformCLILifecycle(t *testing.T) {
	terraform := declaredTool(t, terraformBinaryRlocation, "TERRAFORM_BINARY")
	providerBinary := declaredTool(t, providerBinaryRlocation, "SERVICERADAR_PROVIDER_BINARY")
	directory := t.TempDir()
	mirror := filepath.Join(directory, "mirror")
	plugin := filepath.Join(mirror, "registry.terraform.io", "carverauto", "serviceradar", "0.1.0", runtime.GOOS+"_"+runtime.GOARCH, "terraform-provider-serviceradar_v0.1.0")
	copyExecutable(t, providerBinary, plugin)
	cliConfig := filepath.Join(directory, "terraform.rc")
	writeTestFile(t, cliConfig, fmt.Sprintf("disable_checkpoint = true\nprovider_installation {\n filesystem_mirror {\n path = %q\n include = [\"registry.terraform.io/carverauto/serviceradar\"]\n }\n}\n", mirror))

	repository, credential := &apiFixture{}, &apiFixture{}
	api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch {
		case strings.HasPrefix(req.URL.Path, "/api/admin/ansible-repositories"):
			repository.serve(w, req)
		case strings.HasPrefix(req.URL.Path, "/api/admin/network-credential-secrets"):
			credential.serve(w, req)
		default:
			http.Error(w, "unexpected endpoint", http.StatusNotFound)
		}
	}))
	defer api.Close()
	ca := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw}))
	environment := []string{
		"TF_CLI_CONFIG_FILE=" + cliConfig, "CHECKPOINT_DISABLE=1", "TF_IN_AUTOMATION=1", "TF_INPUT=0",
		"SERVICERADAR_ENDPOINT=" + api.URL, "SERVICERADAR_API_TOKEN=synthetic-api-token",
	}
	for _, key := range []string{"PATH", "TMPDIR", "TEMP", "SYSTEMROOT"} {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	material := fixtureMaterial
	const rotatedMaterial = "second-invented-ephemeral-material"
	secretMarkers := []string{fixtureMaterial, rotatedMaterial, "synthetic-api-token"}
	assertNoSecrets := func(contents []byte) {
		t.Helper()
		for _, marker := range secretMarkers {
			if strings.Contains(string(contents), marker) {
				t.Fatal("Terraform output or artifact retained credential material")
			}
		}
	}
	command := func(want int, args ...string) []byte {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, terraform, args...)
		cmd.Dir = directory
		cmd.Env = append(append([]string{}, environment...), "TF_VAR_credential_material="+material)
		output, err := cmd.CombinedOutput()
		assertNoSecrets(output)
		code := 0
		if err != nil {
			var exited *exec.ExitError
			if !errors.As(err, &exited) {
				t.Fatalf("Terraform invocation failed: %v", err)
			}
			code = exited.ExitCode()
		}
		if code != want {
			t.Fatalf("terraform %s exited %d, want %d:\n%s", args[0], code, want, output)
		}
		return output
	}
	credentialProvider, authMethod, credentialKey := "awx", "bearer_token", fixtureKey
	configure := func(version int, importing bool) {
		t.Helper()
		createKey := "idempotency_key = \"bbbbbbbb-cccc-4ddd-8eee-ffffffffffff\""
		if importing {
			createKey = ""
		}
		writeTestFile(t, filepath.Join(directory, "main.tf"), fmt.Sprintf(`terraform {
  required_version = ">= 1.11.0"
  required_providers {
    serviceradar = { source = "carverauto/serviceradar", version = "0.1.0" }
  }
}
provider "serviceradar" { ca_certificate = %q }
variable "credential_material" {
  type = string
  ephemeral = true
  sensitive = true
}
resource "serviceradar_network_credential_secret" "example" {
  name = "Example credential"
  credential_provider = %q
  auth_method = %q
  idempotency_key = %q
  values_version = %d
  values_wo = { api_token = var.credential_material }
}
resource "serviceradar_ansible_repository" "example" {
  name = "Example repository"
  git_url = "https://git.example.com/project/playbooks.git"
  %s
}
`, ca, credentialProvider, authMethod, credentialKey, version, createKey))
	}
	assertStateSecretsAbsent := func() {
		t.Helper()
		state, err := os.ReadFile(filepath.Join(directory, "terraform.tfstate"))
		if err != nil {
			t.Fatal(err)
		}
		assertNoSecrets(state)
		var decoded map[string]any
		if err := json.Unmarshal(state, &decoded); err != nil {
			t.Fatal(err)
		}
		backup, err := os.ReadFile(filepath.Join(directory, "terraform.tfstate.backup"))
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		assertNoSecrets(backup)
	}
	assertPlanSecretsAbsent := func(name string) {
		t.Helper()
		assertTerraformPlanSecretsAbsent(t, filepath.Join(directory, name), assertNoSecrets)
	}

	configure(1, false)
	command(0, "init", "-backend=false", "-input=false", "-no-color")
	command(0, "validate", "-no-color")
	command(0, "plan", "-out=initial.plan", "-input=false", "-no-color")
	assertPlanSecretsAbsent("initial.plan")
	command(0, "show", "-json", "initial.plan")
	command(0, "apply", "-input=false", "-auto-approve", "-no-color", "initial.plan")
	assertStateSecretsAbsent()
	command(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	repository.mu.Lock()
	repository.object["name"] = "Intervening operator edit"
	repository.version++
	repository.mu.Unlock()
	command(2, "plan", "-detailed-exitcode", "-out=drift.plan", "-input=false", "-no-color")
	assertPlanSecretsAbsent("drift.plan")
	command(0, "apply", "-input=false", "-auto-approve", "-no-color", "drift.plan")
	command(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	material = rotatedMaterial
	configure(2, false)
	command(0, "plan", "-out=rotation.plan", "-input=false", "-no-color")
	assertPlanSecretsAbsent("rotation.plan")
	command(0, "show", "-json", "rotation.plan")
	command(0, "apply", "-input=false", "-auto-approve", "-no-color", "rotation.plan")
	assertStateSecretsAbsent()
	credential.mu.Lock()
	rotations := credential.rotations
	credential.mu.Unlock()
	if rotations != 1 {
		t.Fatal("Terraform did not execute exactly one requested rotation")
	}
	command(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	for _, replacement := range []struct{ provider, method, key string }{
		{"proxmox", "bearer_token", "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa"},
		{"proxmox", "api_token", "dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb"},
	} {
		credentialProvider, authMethod = replacement.provider, replacement.method
		configure(2, false)
		output := command(1, "plan", "-input=false", "-no-color")
		if !strings.Contains(string(output), "Fresh replacement identity required") {
			t.Fatal("replacement plan failed without the creation identity diagnostic")
		}
		credential.mu.Lock()
		intact := credential.object != nil && credential.createKey == credentialKey
		deletes := credential.deletes
		credential.mu.Unlock()
		if !intact {
			t.Fatal("rejected replacement changed the server credential")
		}
		if deletes != 0 {
			t.Fatal("rejected replacement issued DELETE")
		}
		t.Logf("Replacement %s/%s with reused key: server credential intact, DELETE count=%d\n%s", replacement.provider, replacement.method, deletes, output)
		credentialKey = replacement.key
		configure(2, false)
		command(0, "plan", "-out=replacement.plan", "-input=false", "-no-color")
		assertPlanSecretsAbsent("replacement.plan")
		command(0, "show", "-json", "replacement.plan")
		command(0, "apply", "-input=false", "-auto-approve", "-no-color", "replacement.plan")
		assertStateSecretsAbsent()
		credential.mu.Lock()
		replaced := credential.object != nil && credential.createKey == credentialKey && credential.deletes == 1
		credential.deletes = 0
		credential.mu.Unlock()
		if !replaced {
			t.Fatal("fresh-key replacement did not delete and recreate the unused credential")
		}
		t.Logf("Replacement %s/%s with fresh key: applied successfully; server credential recreated with requested key after one DELETE; plan and state contain no secret material", replacement.provider, replacement.method)
		command(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")
	}

	command(0, "state", "rm", "serviceradar_ansible_repository.example")
	configure(2, true)
	command(0, "import", "-input=false", "-no-color", "serviceradar_ansible_repository.example", fixtureID)
	command(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	repository.mu.Lock()
	repository.guardDelete = true
	repository.mu.Unlock()
	command(1, "destroy", "-target=serviceradar_ansible_repository.example", "-auto-approve", "-input=false", "-no-color")
	state := command(0, "state", "list")
	if !strings.Contains(string(state), "serviceradar_ansible_repository.example") {
		t.Fatal("guarded destroy removed the resource from Terraform state")
	}
	repository.mu.Lock()
	repository.guardDelete = false
	repository.mu.Unlock()
	command(0, "destroy", "-auto-approve", "-input=false", "-no-color")
	if len(strings.TrimSpace(string(command(0, "state", "list")))) != 0 {
		t.Fatal("successful destroy retained managed resources")
	}
}

func assertTerraformPlanSecretsAbsent(t *testing.T, planPath string, assertNoSecrets func([]byte)) {
	t.Helper()
	archive, err := zip.OpenReader(planPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := archive.Close(); err != nil {
			t.Error(err)
		}
	}()
	for _, file := range archive.File {
		entry, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		contents, err := io.ReadAll(entry)
		closeErr := entry.Close()
		if err != nil {
			t.Fatal(err)
		}
		if closeErr != nil {
			t.Fatal(closeErr)
		}
		assertNoSecrets(contents)
	}
}

func declaredTool(t *testing.T, rlocation, environmentName string) string {
	t.Helper()
	if rlocation != "" {
		resolved, err := runfiles.Rlocation(rlocation)
		if err != nil {
			t.Fatal(err)
		}
		return resolved
	}
	if path := os.Getenv(environmentName); path != "" {
		resolved, err := filepath.Abs(path)
		if err != nil {
			t.Fatal(err)
		}
		return resolved
	}
	t.Skip("Terraform CLI acceptance requires the Bazel target's declared Terraform and provider binaries")
	return ""
}

func copyExecutable(t *testing.T, source, destination string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		t.Fatal(err)
	}
	input, err := os.Open(source)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := input.Close(); err != nil {
			t.Error(err)
		}
	}()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o700)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(output, input); err != nil {
		if closeErr := output.Close(); closeErr != nil {
			t.Error(closeErr)
		}
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
}

func writeTestFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

type settingsExportBundle struct {
	SchemaVersion      int                       `json:"schema_version"`
	ExportedAt         string                    `json:"exported_at"`
	Reason             string                    `json:"reason"`
	TerraformResources exportedTerraformResource `json:"terraform_resources"`
}

type exportedTerraformResource struct {
	Secrets     []map[string]any `json:"serviceradar_network_credential_secret"`
	Rules       []map[string]any `json:"serviceradar_network_credential_rule"`
	Controllers []map[string]any `json:"serviceradar_ansible_controller"`
	Repos       []map[string]any `json:"serviceradar_ansible_repository"`
}

func TestTerraformCLISettingsBundleRoundTrip(t *testing.T) {
	terraform := declaredTool(t, terraformBinaryRlocation, "TERRAFORM_BINARY")
	providerBinary := declaredTool(t, providerBinaryRlocation, "SERVICERADAR_PROVIDER_BINARY")
	directory := t.TempDir()
	mirror := filepath.Join(directory, "mirror")
	plugin := filepath.Join(mirror, "registry.terraform.io", "carverauto", "serviceradar", "0.1.0", runtime.GOOS+"_"+runtime.GOARCH, "terraform-provider-serviceradar_v0.1.0")
	copyExecutable(t, providerBinary, plugin)
	cliConfig := filepath.Join(directory, "terraform.rc")
	writeTestFile(t, cliConfig, fmt.Sprintf("disable_checkpoint = true\nprovider_installation {\n filesystem_mirror {\n path = %q\n include = [\"registry.terraform.io/carverauto/serviceradar\"]\n }\n}\n", mirror))

	const syntheticAPIKey = "synthetic-cli-api-key"
	const bundleMatA = "synthetic-bundle-ephemeral-material-1"
	const bundleMatB = "synthetic-bundle-ephemeral-material-2"
	secretMarkers := []string{syntheticAPIKey, bundleMatA, bundleMatB, fixtureMaterial}

	fixture := newMultiResourceFixture(syntheticAPIKey)
	api := httptest.NewTLSServer(http.HandlerFunc(fixture.serve))
	defer api.Close()
	ca := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw}))

	bundle := loadSettingsBundleFixture(t)
	if bundle.SchemaVersion != 1 || bundle.Reason != "pre_resize" {
		t.Fatalf("unexpected bundle metadata: schema_version=%d reason=%q", bundle.SchemaVersion, bundle.Reason)
	}
	if len(bundle.TerraformResources.Secrets) < 2 ||
		len(bundle.TerraformResources.Rules) < 1 ||
		len(bundle.TerraformResources.Controllers) < 1 ||
		len(bundle.TerraformResources.Repos) < 1 {
		t.Fatal("shared settings export bundle is missing required Terraform resource families")
	}
	for _, secret := range bundle.TerraformResources.Secrets {
		if _, leaked := secret["values_wo"]; leaked {
			t.Fatal("shared settings export bundle unexpectedly contained values_wo")
		}
		if secret["values_version"] != float64(1) {
			t.Fatalf("expected values_version=1 in exported secret, got %v", secret["values_version"])
		}
	}
	primarySecretID := bundle.TerraformResources.Secrets[0]["id"]
	if bundle.TerraformResources.Rules[0]["secret_id"] != primarySecretID {
		t.Fatalf("rule secret_id %v does not reference primary secret %v", bundle.TerraformResources.Rules[0]["secret_id"], primarySecretID)
	}
	if bundle.TerraformResources.Controllers[0]["sync_credential_secret_id"] != primarySecretID ||
		bundle.TerraformResources.Controllers[0]["execution_credential_secret_id"] != primarySecretID {
		t.Fatalf("controller credential references do not match primary secret %v", primarySecretID)
	}

	assertNoSecrets := func(contents []byte) {
		t.Helper()
		for _, marker := range secretMarkers {
			if strings.Contains(string(contents), marker) {
				t.Fatal("Terraform artifact leaked credential material")
			}
		}
	}

	env := []string{
		"TF_CLI_CONFIG_FILE=" + cliConfig,
		"CHECKPOINT_DISABLE=1",
		"TF_IN_AUTOMATION=1",
		"TF_INPUT=0",
		"SERVICERADAR_ENDPOINT=" + api.URL,
		"SERVICERADAR_API_KEY=" + syntheticAPIKey,
		"TF_VAR_bundle_material_a=" + bundleMatA,
		"TF_VAR_bundle_material_b=" + bundleMatB,
	}
	for _, key := range []string{"PATH", "TMPDIR", "TEMP", "SYSTEMROOT"} {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}

	runTF := func(want int, args ...string) []byte {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, terraform, args...)
		cmd.Dir = directory
		cmd.Env = env
		output, err := cmd.CombinedOutput()
		assertNoSecrets(output)
		code := 0
		if err != nil {
			var exited *exec.ExitError
			if !errors.As(err, &exited) {
				t.Fatalf("Terraform invocation failed: %v", err)
			}
			code = exited.ExitCode()
		}
		if code != want {
			t.Fatalf("terraform %s exited %d, want %d:\n%s", args[0], code, want, output)
		}
		return output
	}

	renderConfig := func(importing bool, enabledOverride bool, includeData bool) {
		t.Helper()
		tfDoc := buildBundleTerraformJSON(ca, bundle, importing, enabledOverride, includeData)
		encoded, err := json.MarshalIndent(tfDoc, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		writeTestFile(t, filepath.Join(directory, "main.tf.json"), string(encoded))
	}

	renderConfig(false, true, true)
	runTF(0, "init", "-backend=false", "-input=false", "-no-color")
	runTF(0, "validate", "-no-color")
	runTF(0, "plan", "-out=bundle.plan", "-input=false", "-no-color")
	assertTerraformPlanSecretsAbsent(t, filepath.Join(directory, "bundle.plan"), assertNoSecrets)
	runTF(0, "apply", "-input=false", "-auto-approve", "-no-color", "bundle.plan")

	stateBytes, err := os.ReadFile(filepath.Join(directory, "terraform.tfstate"))
	if err != nil {
		t.Fatal(err)
	}
	assertNoSecrets(stateBytes)
	runTF(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	// Extract server-assigned IDs from Terraform state for drift & import checks.
	ids := readStateIDs(t, runTF(0, "show", "-json"))
	ruleID := ids["serviceradar_network_credential_rule.rule_0"]
	ctrlID := ids["serviceradar_ansible_controller.controller_0"]
	secID := ids["serviceradar_network_credential_secret.secret_0"]
	repoID := ids["serviceradar_ansible_repository.repo_0"]

	// Simulate out-of-band drift on rule and controller, then reconcile.
	fixture.mutateField("network-credential-rules", ruleID, "name", "Out-of-band drifted rule")
	fixture.mutateField("ansible-controllers", ctrlID, "name", "Out-of-band drifted controller")
	runTF(2, "plan", "-detailed-exitcode", "-out=drift.plan", "-input=false", "-no-color")
	assertTerraformPlanSecretsAbsent(t, filepath.Join(directory, "drift.plan"), assertNoSecrets)
	runTF(0, "apply", "-input=false", "-auto-approve", "-no-color", "drift.plan")
	runTF(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	// Import all four resource families cleanly and verify zero-diff plan.
	runTF(0, "state", "rm",
		"serviceradar_network_credential_secret.secret_0",
		"serviceradar_network_credential_rule.rule_0",
		"serviceradar_ansible_controller.controller_0",
		"serviceradar_ansible_repository.repo_0",
	)
	renderConfig(true, true, false)
	runTF(0, "import", "-input=false", "-no-color", "serviceradar_network_credential_secret.secret_0", secID)
	runTF(0, "import", "-input=false", "-no-color", "serviceradar_network_credential_rule.rule_0", ruleID)
	runTF(0, "import", "-input=false", "-no-color", "serviceradar_ansible_controller.controller_0", ctrlID)
	runTF(0, "import", "-input=false", "-no-color", "serviceradar_ansible_repository.repo_0", repoID)
	runTF(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	// Guarded destroy: enabled rule/controller reject DELETE (409), retaining state.
	runTF(1, "destroy",
		"-target=serviceradar_network_credential_rule.rule_0",
		"-target=serviceradar_ansible_controller.controller_0",
		"-auto-approve", "-input=false", "-no-color",
	)
	stateList := string(runTF(0, "state", "list"))
	if !strings.Contains(stateList, "serviceradar_network_credential_rule.rule_0") ||
		!strings.Contains(stateList, "serviceradar_ansible_controller.controller_0") {
		t.Fatal("guarded destroy removed enabled rule/controller from Terraform state")
	}

	// Disable rule & controller first, then destroy succeeds cleanly.
	renderConfig(true, false, false)
	runTF(0, "apply", "-input=false", "-auto-approve", "-no-color")
	runTF(0, "destroy", "-auto-approve", "-input=false", "-no-color")
	if len(strings.TrimSpace(string(runTF(0, "state", "list")))) != 0 {
		t.Fatal("destroy retained resources after disabling guards")
	}
}

func TestTerraformCLIEdgeCaseGuards(t *testing.T) {
	terraform := declaredTool(t, terraformBinaryRlocation, "TERRAFORM_BINARY")
	providerBinary := declaredTool(t, providerBinaryRlocation, "SERVICERADAR_PROVIDER_BINARY")
	directory := t.TempDir()
	mirror := filepath.Join(directory, "mirror")
	plugin := filepath.Join(mirror, "registry.terraform.io", "carverauto", "serviceradar", "0.1.0", runtime.GOOS+"_"+runtime.GOARCH, "terraform-provider-serviceradar_v0.1.0")
	copyExecutable(t, providerBinary, plugin)
	cliConfig := filepath.Join(directory, "terraform.rc")
	writeTestFile(t, cliConfig, fmt.Sprintf("disable_checkpoint = true\nprovider_installation {\n filesystem_mirror {\n path = %q\n include = [\"registry.terraform.io/carverauto/serviceradar\"]\n }\n}\n", mirror))

	const wrongAPIKey = "synthetic-wrong-api-key-must-never-leak"
	const rotatedMaterial = "synthetic-edge-rotated-ephemeral-material"
	secretMarkers := []string{fixtureMaterial, rotatedMaterial, wrongAPIKey, "synthetic-api-token"}

	credential := &apiFixture{}
	var (
		forceRedirect      bool
		force503           bool
		force412OnMutation bool
		redirectHits       int
	)
	api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		credential.mu.Lock()
		redir := forceRedirect
		ret503 := force503
		ret412 := force412OnMutation
		if redir {
			redirectHits++
		}
		credential.mu.Unlock()

		if redir {
			w.Header().Set("Location", "/forwarded")
			w.WriteHeader(http.StatusTemporaryRedirect)
			return
		}
		if ret503 {
			http.Error(w, fixtureMaterial, http.StatusServiceUnavailable)
			return
		}
		if ret412 && (req.Method == http.MethodPatch || req.Method == http.MethodDelete) {
			http.Error(w, "stale_etag", http.StatusPreconditionFailed)
			return
		}
		if req.Header.Get("X-API-Key") == wrongAPIKey {
			http.Error(w, wrongAPIKey, http.StatusForbidden)
			return
		}
		credential.serve(w, req)
	}))
	defer api.Close()
	ca := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw}))

	assertNoSecrets := func(contents []byte) {
		t.Helper()
		for _, marker := range secretMarkers {
			if strings.Contains(string(contents), marker) {
				t.Fatal("Terraform output or artifact leaked credential material")
			}
		}
	}

	baseEnv := []string{
		"TF_CLI_CONFIG_FILE=" + cliConfig,
		"CHECKPOINT_DISABLE=1",
		"TF_IN_AUTOMATION=1",
		"TF_INPUT=0",
		"SERVICERADAR_ENDPOINT=" + api.URL,
	}
	for _, key := range []string{"PATH", "TMPDIR", "TEMP", "SYSTEMROOT"} {
		if value, ok := os.LookupEnv(key); ok {
			baseEnv = append(baseEnv, key+"="+value)
		}
	}

	material := fixtureMaterial
	runWithAuth := func(want int, authEnv string, args ...string) []byte {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, terraform, args...)
		cmd.Dir = directory
		cmd.Env = append(append([]string{}, baseEnv...), authEnv, "TF_VAR_credential_material="+material)
		output, err := cmd.CombinedOutput()
		assertNoSecrets(output)
		code := 0
		if err != nil {
			var exited *exec.ExitError
			if !errors.As(err, &exited) {
				t.Fatalf("Terraform invocation failed: %v", err)
			}
			code = exited.ExitCode()
		}
		if code != want {
			t.Fatalf("terraform %s exited %d, want %d:\n%s", args[0], code, want, output)
		}
		return output
	}
	runTF := func(want int, args ...string) []byte {
		t.Helper()
		return runWithAuth(want, "SERVICERADAR_API_TOKEN=synthetic-api-token", args...)
	}

	const edgeKey = "ffffffff-1111-4222-8333-444444444444"
	writeConfig := func(name string, version int) {
		t.Helper()
		writeTestFile(t, filepath.Join(directory, "main.tf"), fmt.Sprintf(`terraform {
  required_version = ">= 1.11.0"
  required_providers {
    serviceradar = { source = "carverauto/serviceradar", version = "0.1.0" }
  }
}
provider "serviceradar" { ca_certificate = %q }
variable "credential_material" {
  type = string
  ephemeral = true
  sensitive = true
}
resource "serviceradar_network_credential_secret" "guarded" {
  name = %q
  credential_provider = "awx"
  auth_method = "bearer_token"
  idempotency_key = %q
  values_version = %d
  values_wo = { api_token = var.credential_material }
}
`, ca, name, edgeKey, version))
	}

	writeConfig("Guarded credential", 1)
	runTF(0, "init", "-backend=false", "-input=false", "-no-color")
	runTF(0, "validate", "-no-color")

	// 1. Auth guard: wrong X-API-Key rejected with 403 and zero secret leakage.
	collapseWS := func(b []byte) string { return strings.Join(strings.Fields(string(b)), " ") }
	out := runWithAuth(1, "SERVICERADAR_API_KEY="+wrongAPIKey, "apply", "-auto-approve", "-input=false", "-no-color")
	if !strings.Contains(collapseWS(out), "denied the request") {
		t.Fatalf("expected 403 denied diagnostic, got:\n%s", out)
	}

	// 2. Redirect guard: 307 rejected without following redirect.
	credential.mu.Lock()
	forceRedirect = true
	redirectHits = 0
	credential.mu.Unlock()
	runTF(1, "apply", "-auto-approve", "-input=false", "-no-color")
	credential.mu.Lock()
	hits := redirectHits
	forceRedirect = false
	credential.mu.Unlock()
	if hits != 1 {
		t.Fatalf("expected provider to stop on 307 without following redirect (hits=1), got %d", hits)
	}

	// 3. 503 diagnostic: surfaces temporary unavailability without leaking response body.
	credential.mu.Lock()
	force503 = true
	credential.mu.Unlock()
	out = runTF(1, "apply", "-auto-approve", "-input=false", "-no-color")
	credential.mu.Lock()
	force503 = false
	credential.mu.Unlock()
	if !strings.Contains(collapseWS(out), "temporarily unavailable") {
		t.Fatalf("expected 503 temporary unavailability diagnostic, got:\n%s", out)
	}

	// 4. Clean create, then write-only values_wo rotation partial-failure recovery without double-rotating.
	runTF(0, "apply", "-auto-approve", "-input=false", "-no-color")
	material = rotatedMaterial
	writeConfig("Guarded credential v2", 2)
	credential.mu.Lock()
	credential.rejectPatch = true
	credential.mu.Unlock()
	runTF(1, "apply", "-auto-approve", "-input=false", "-no-color")
	credential.mu.Lock()
	rotAfterFail := credential.rotations
	credential.rejectPatch = false
	credential.mu.Unlock()
	if rotAfterFail != 1 {
		t.Fatalf("expected exactly one accepted rotation before PATCH rejection, got %d", rotAfterFail)
	}
	stateBytes, err := os.ReadFile(filepath.Join(directory, "terraform.tfstate"))
	if err != nil {
		t.Fatal(err)
	}
	assertNoSecrets(stateBytes)

	runTF(0, "apply", "-auto-approve", "-input=false", "-no-color")
	credential.mu.Lock()
	rotAfterRetry := credential.rotations
	credential.mu.Unlock()
	if rotAfterRetry != 1 {
		t.Fatalf("retry repeated an already-accepted rotation: rotations=%d", rotAfterRetry)
	}
	runTF(0, "plan", "-detailed-exitcode", "-input=false", "-no-color")

	// 5. ETag/If-Match concurrency guard: 412 Precondition Failed rejects update & destroy while preserving state.
	writeConfig("Guarded credential v3", 2)
	credential.mu.Lock()
	force412OnMutation = true
	credential.mu.Unlock()
	out = runTF(1, "apply", "-auto-approve", "-input=false", "-no-color")
	if !strings.Contains(collapseWS(out), "stale or missing resource version") {
		t.Fatalf("expected 412 stale-version diagnostic on update, got:\n%s", out)
	}
	out = runTF(1, "destroy", "-auto-approve", "-input=false", "-no-color")
	if !strings.Contains(collapseWS(out), "stale or missing resource version") {
		t.Fatalf("expected 412 stale-version diagnostic on destroy, got:\n%s", out)
	}
	if !strings.Contains(string(runTF(0, "state", "list")), "serviceradar_network_credential_secret.guarded") {
		t.Fatal("412 destroy falsely removed resource from Terraform state")
	}

	// 6. Clean destroy, then 410 Gone when reusing the deleted resource's idempotency_key.
	credential.mu.Lock()
	force412OnMutation = false
	credential.mu.Unlock()
	runTF(0, "destroy", "-auto-approve", "-input=false", "-no-color")
	if len(strings.TrimSpace(string(runTF(0, "state", "list")))) != 0 {
		t.Fatal("destroy retained resource")
	}
	out = runTF(1, "apply", "-auto-approve", "-input=false", "-no-color")
	if !strings.Contains(collapseWS(out), "deleted resource") {
		t.Fatalf("expected 410 deleted-resource idempotency_key diagnostic, got:\n%s", out)
	}
}

func buildBundleTerraformJSON(caPEM string, bundle settingsExportBundle, importing, enabledOverride, includeData bool) map[string]any {
	secretOne := bundle.TerraformResources.Secrets[0]
	secretTwo := bundle.TerraformResources.Secrets[1]
	rule := bundle.TerraformResources.Rules[0]
	ctrl := bundle.TerraformResources.Controllers[0]
	repo := bundle.TerraformResources.Repos[0]

	secretRes := func(name string, src map[string]any, idemKey, varRef string) map[string]any {
		m := map[string]any{
			"name":                src["name"],
			"description":         src["description"],
			"credential_provider": src["credential_provider"],
			"auth_method":         src["auth_method"],
			"values_version":      1,
			"values_wo":           map[string]any{"api_token": fmt.Sprintf("${var.%s}", varRef)},
		}
		if importing && name == "secret_0" {
			m["values_version"] = 0
			delete(m, "values_wo")
		} else {
			m["idempotency_key"] = idemKey
		}
		return m
	}

	ruleBlock := map[string]any{
		"name":                rule["name"],
		"description":         rule["description"],
		"credential_provider": rule["credential_provider"],
		"auth_method":         rule["auth_method"],
		"purpose":             rule["purpose"],
		"target_query":        rule["target_query"],
		"scope_type":          rule["scope_type"],
		"scope_value":         rule["scope_value"],
		"secret_id":           "${serviceradar_network_credential_secret.secret_0.id}",
		"allowed_ports":       rule["allowed_ports"],
		"tls_policy":          rule["tls_policy"],
		"ssh_host_key_policy": rule["ssh_host_key_policy"],
		"priority":            rule["priority"],
		"enabled":             enabledOverride,
	}
	ctrlBlock := map[string]any{
		"name":                            ctrl["name"],
		"description":                     ctrl["description"],
		"base_url":                        ctrl["base_url"],
		"agent_id":                        ctrl["agent_id"],
		"sync_credential_secret_id":       "${serviceradar_network_credential_secret.secret_0.id}",
		"execution_credential_secret_id":  "${serviceradar_network_credential_secret.secret_0.id}",
		"inventory_sync_interval_seconds": ctrl["inventory_sync_interval_seconds"],
		"catalog_sync_interval_seconds":   ctrl["catalog_sync_interval_seconds"],
		"enabled":                         enabledOverride,
	}
	repoBlock := map[string]any{
		"name":                  repo["name"],
		"description":           repo["description"],
		"git_url":               repo["git_url"],
		"git_ref":               repo["git_ref"],
		"sync_interval_seconds": repo["sync_interval_seconds"],
	}
	if !importing {
		ruleBlock["idempotency_key"] = "eeeeeeee-1111-4222-8333-000000000003"
		ctrlBlock["idempotency_key"] = "eeeeeeee-1111-4222-8333-000000000004"
		repoBlock["idempotency_key"] = "eeeeeeee-1111-4222-8333-000000000005"
	}

	doc := map[string]any{
		"terraform": map[string]any{
			"required_version": ">= 1.11.0",
			"required_providers": map[string]any{
				"serviceradar": map[string]any{"source": "carverauto/serviceradar", "version": "0.1.0"},
			},
		},
		"provider": map[string]any{
			"serviceradar": map[string]any{"ca_certificate": caPEM},
		},
		"variable": map[string]any{
			"bundle_material_a": map[string]any{"type": "string", "ephemeral": true, "sensitive": true},
			"bundle_material_b": map[string]any{"type": "string", "ephemeral": true, "sensitive": true},
		},
		"resource": map[string]any{
			"serviceradar_network_credential_secret": map[string]any{
				"secret_0": secretRes("secret_0", secretOne, "eeeeeeee-1111-4222-8333-000000000001", "bundle_material_a"),
				"secret_1": secretRes("secret_1", secretTwo, "eeeeeeee-1111-4222-8333-000000000002", "bundle_material_b"),
			},
			"serviceradar_network_credential_rule": map[string]any{"rule_0": ruleBlock},
			"serviceradar_ansible_controller":      map[string]any{"controller_0": ctrlBlock},
			"serviceradar_ansible_repository":      map[string]any{"repo_0": repoBlock},
		},
	}
	if includeData {
		doc["data"] = map[string]any{
			"serviceradar_network_credential_secret": map[string]any{"s": map[string]any{"id": "${serviceradar_network_credential_secret.secret_0.id}"}},
			"serviceradar_network_credential_rule":   map[string]any{"r": map[string]any{"id": "${serviceradar_network_credential_rule.rule_0.id}"}},
			"serviceradar_ansible_controller":        map[string]any{"c": map[string]any{"id": "${serviceradar_ansible_controller.controller_0.id}"}},
			"serviceradar_ansible_repository":        map[string]any{"g": map[string]any{"id": "${serviceradar_ansible_repository.repo_0.id}"}},
		}
	}
	return doc
}

func loadSettingsBundleFixture(t *testing.T) settingsExportBundle {
	t.Helper()
	var path string
	if settingsBundleFixtureRlocation != "" {
		resolved, err := runfiles.Rlocation(settingsBundleFixtureRlocation)
		if err != nil {
			t.Fatal(err)
		}
		path = resolved
	} else {
		path = filepath.Join("..", "..", "..", "elixir", "serviceradar_core", "test", "fixtures", "settings_backup", "terraform_roundtrip_bundle_v1.json")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed reading shared settings export bundle fixture %q: %v", path, err)
	}
	var bundle settingsExportBundle
	if err := json.Unmarshal(raw, &bundle); err != nil {
		t.Fatalf("failed decoding shared settings export bundle fixture %q: %v", path, err)
	}
	return bundle
}

func readStateIDs(t *testing.T, showJSON []byte) map[string]string {
	t.Helper()
	var parsed struct {
		Values struct {
			RootModule struct {
				Resources []struct {
					Address string         `json:"address"`
					Mode    string         `json:"mode"`
					Values  map[string]any `json:"values"`
				} `json:"resources"`
			} `json:"root_module"`
		} `json:"values"`
	}
	if err := json.Unmarshal(showJSON, &parsed); err != nil {
		t.Fatal(err)
	}
	ids := map[string]string{}
	for _, r := range parsed.Values.RootModule.Resources {
		if r.Mode == "managed" {
			if id, ok := r.Values["id"].(string); ok {
				ids[r.Address] = id
			}
		}
	}
	return ids
}
