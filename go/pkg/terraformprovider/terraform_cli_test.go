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
var terraformBinaryRlocation string //nolint:gochecknoglobals // Bazel injects this declared runfile with -X.
var providerBinaryRlocation string  //nolint:gochecknoglobals // Bazel injects this declared runfile with -X.

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
  credential_provider = "awx"
  auth_method = "bearer_token"
  idempotency_key = %q
  values_version = %d
  values_wo = { api_token = var.credential_material }
}
resource "serviceradar_ansible_repository" "example" {
  name = "Example repository"
  git_url = "https://git.example.com/project/playbooks.git"
  %s
}
`, ca, fixtureKey, version, createKey))
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
		archive, err := zip.OpenReader(filepath.Join(directory, name))
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
