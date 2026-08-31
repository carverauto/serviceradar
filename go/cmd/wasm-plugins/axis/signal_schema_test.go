package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAxisSignalSchemaRefMatchesShippedPackageContract(t *testing.T) {
	manifestPath := signalSchemaTestFile(t, "plugin.yaml")
	producerID, producerVersion, signal := readManifestSignal(t, manifestPath, axisSignalSchemaID)
	contract := readDisplayContract(t, signalSchemaTestFile(t, signal["display_contract"]))
	ref := axisSignalSchemaRef()

	assertSignalRefMatchesPackage(t, ref.ProducerID, producerID, "producer id")
	assertSignalRefMatchesPackage(t, ref.ProducerVersion, producerVersion, "producer version")
	assertSignalRefMatchesPackage(t, ref.SchemaID, signal["id"], "schema id")
	assertSignalRefMatchesPackage(t, ref.SchemaVersion, signal["version"], "schema version")
	assertSignalRefMatchesPackage(t, ref.DisplayContract, signal["display_contract"], "display contract path")
	assertSignalRefMatchesPackage(t, ref.DisplayContractID, signal["display_contract_id"], "display contract id")
	assertSignalRefMatchesPackage(t, ref.DisplayContractVersion, signal["display_contract_version"], "display contract version")
	assertSignalRefMatchesPackage(t, ref.SchemaID, contract["schema_id"], "contract schema id")
	assertSignalRefMatchesPackage(t, ref.SchemaVersion, contract["schema_version"], "contract schema version")
	assertSignalRefMatchesPackage(t, ref.DisplayContractID, contract["id"], "contract id")
	assertSignalRefMatchesPackage(t, ref.DisplayContractVersion, contract["version"], "contract version")
}

func signalSchemaTestFile(t *testing.T, relative string) string {
	t.Helper()

	candidates := []string{relative}
	if testSrcDir := os.Getenv("TEST_SRCDIR"); testSrcDir != "" {
		packagePath := filepath.Join("go", "cmd", "wasm-plugins", "axis", relative)
		if workspace := os.Getenv("TEST_WORKSPACE"); workspace != "" {
			candidates = append(candidates, filepath.Join(testSrcDir, workspace, packagePath))
		}
		candidates = append(candidates, filepath.Join(testSrcDir, packagePath))
	}

	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}

	t.Fatalf("declared package file %q not found in candidates %q", relative, candidates)
	return ""
}

func readManifestSignal(t *testing.T, path, schemaID string) (string, string, map[string]string) {
	t.Helper()

	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	var producerID, producerVersion string
	signal := make(map[string]string)
	selected := false
	scanner := bufio.NewScanner(strings.NewReader(string(contents)))

	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "id: "):
			producerID = yamlScalar(strings.TrimPrefix(line, "id:"))
		case strings.HasPrefix(line, "version: "):
			producerVersion = yamlScalar(strings.TrimPrefix(line, "version:"))
		case strings.HasPrefix(line, "  - id: "):
			selected = yamlScalar(strings.TrimPrefix(line, "  - id:")) == schemaID
			if selected {
				signal["id"] = schemaID
			}
		case selected && strings.HasPrefix(line, "    "):
			parts := strings.SplitN(strings.TrimSpace(line), ":", 2)
			if len(parts) == 2 {
				signal[parts[0]] = yamlScalar(parts[1])
			}
		}
	}

	if err := scanner.Err(); err != nil {
		t.Fatalf("scan %s: %v", path, err)
	}
	if producerID == "" || producerVersion == "" || signal["id"] == "" {
		t.Fatalf("manifest %s does not declare producer and schema %s", path, schemaID)
	}

	return producerID, producerVersion, signal
}

func readDisplayContract(t *testing.T, path string) map[string]string {
	t.Helper()

	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	var contract map[string]any
	if err := json.Unmarshal(contents, &contract); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}

	return map[string]string{
		"id":             contract["id"].(string),
		"version":        contract["version"].(string),
		"schema_id":      contract["schema_id"].(string),
		"schema_version": contract["schema_version"].(string),
	}
}

func yamlScalar(value string) string {
	return strings.Trim(strings.TrimSpace(value), `"`)
}

func assertSignalRefMatchesPackage(t *testing.T, got, want, field string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %q, shipped package contract declares %q", field, got, want)
	}
}
