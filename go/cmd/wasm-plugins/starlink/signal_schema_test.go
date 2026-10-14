package main

import (
	"encoding/json"
	"os"
	"testing"

	"gopkg.in/yaml.v3"
)

// web-ng resolves a stored event's display contract by the four-part key
// {producer_id, producer_version, schema_id, schema_version}, where
// producer_version is the installed package version. A ref that drifts from
// the manifest it ships in renders without its contract.
func TestAlertSignalSchemaRefMatchesShippedPackageContracts(t *testing.T) {
	for manifest, producerID := range map[string]string{
		"plugin.yaml":       cloudPluginID,
		"plugin.local.yaml": localPluginID,
	} {
		t.Run(producerID, func(t *testing.T) {
			pkg := readSignalManifest(t, manifest)
			signal := pkg.signal(t, alertSignalSchemaID)
			contract := readDisplayContract(t, signal.DisplayContract)
			ref := alertSignalSchemaRef(producerID)

			assertRefField(t, "producer id", ref.ProducerID, pkg.ID)
			assertRefField(t, "producer version", ref.ProducerVersion, pkg.Version)
			assertRefField(t, "schema version", ref.SchemaVersion, signal.Version)
			assertRefField(t, "display contract path", ref.DisplayContract, signal.DisplayContract)
			assertRefField(t, "display contract id", ref.DisplayContractID, signal.DisplayContractID)
			assertRefField(t, "display contract version", ref.DisplayContractVersion, signal.DisplayContractVersion)
			assertRefField(t, "contract schema id", ref.SchemaID, contract.SchemaID)
			assertRefField(t, "contract schema version", ref.SchemaVersion, contract.SchemaVersion)
			assertRefField(t, "contract id", ref.DisplayContractID, contract.ID)
			assertRefField(t, "contract version", ref.DisplayContractVersion, contract.Version)
		})
	}
}

type signalManifest struct {
	ID            string                `yaml:"id"`
	Version       string                `yaml:"version"`
	SignalSchemas []manifestSignalEntry `yaml:"signal_schemas"`
}

type manifestSignalEntry struct {
	ID                     string `yaml:"id"`
	Version                string `yaml:"version"`
	DisplayContract        string `yaml:"display_contract"`
	DisplayContractID      string `yaml:"display_contract_id"`
	DisplayContractVersion string `yaml:"display_contract_version"`
}

func (m signalManifest) signal(t *testing.T, schemaID string) manifestSignalEntry {
	t.Helper()
	for _, signal := range m.SignalSchemas {
		if signal.ID == schemaID {
			return signal
		}
	}
	t.Fatalf("package %s does not declare signal schema %s", m.ID, schemaID)
	return manifestSignalEntry{}
}

type displayContract struct {
	ID            string `json:"id"`
	Version       string `json:"version"`
	SchemaID      string `json:"schema_id"`
	SchemaVersion string `json:"schema_version"`
}

func readSignalManifest(t *testing.T, relative string) signalManifest {
	t.Helper()
	var manifest signalManifest
	if err := yaml.Unmarshal(readPackageFile(t, relative), &manifest); err != nil {
		t.Fatalf("parse %s: %v", relative, err)
	}
	return manifest
}

func readDisplayContract(t *testing.T, relative string) displayContract {
	t.Helper()
	var contract displayContract
	if err := json.Unmarshal(readPackageFile(t, relative), &contract); err != nil {
		t.Fatalf("decode %s: %v", relative, err)
	}
	return contract
}

func readPackageFile(t *testing.T, relative string) []byte {
	t.Helper()
	contents, err := os.ReadFile(relative)
	if err != nil {
		t.Fatalf("read %s: %v", relative, err)
	}
	return contents
}

func assertRefField(t *testing.T, field, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("%s = %q, shipped package declares %q", field, got, want)
	}
}
