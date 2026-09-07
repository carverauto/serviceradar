package main

import (
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestDecodeConfigFlatObject(t *testing.T) {
	cfg, err := decodeConfig([]byte(`{"source_id":"lab","base_url":"https://netbox.example.com","api_token":"t"}`))
	if err != nil {
		t.Fatalf("flat config must decode: %v", err)
	}
	if cfg.BaseURL != "https://netbox.example.com" || cfg.APIToken != "t" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestDecodeConfigPluginInputsEnvelope(t *testing.T) {
	raw := []byte(`{
	  "schema": "` + sdk.PluginInputsSchemaV1 + `",
	  "policy_id": "network-credential-rule:r1:inventory_sync",
	  "policy_version": 3,
	  "agent_id": "agent-1",
	  "template": {
	    "source_id": "lab",
	    "base_url": "https://netbox.example.com",
	    "api_token": "resolved-token",
	    "page_size": 250,
	    "timeout_ms": 45000,
	    "credential_rule_id": "r1"
	  },
	  "inputs": [{"name":"targets","entity":"devices","items":[{"uid":"d1","ip":"10.0.0.9"}]}]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("plugin_inputs envelope must decode: %v", err)
	}

	sources := cfg.sourceConfigs()
	if len(sources) != 1 {
		t.Fatalf("expected one materialized source, got %d", len(sources))
	}
	if sources[0].BaseURL != "https://netbox.example.com" || sources[0].APIToken != "resolved-token" {
		t.Fatalf("credential-materialized fields lost: %+v", sources[0])
	}
	if sources[0].PageSize != 250 || sources[0].TimeoutMS != 45000 {
		t.Fatalf("non-secret template fields lost: %+v", sources[0])
	}
}

func TestDecodeConfigEnvelopeWithoutTemplateReportsNoSource(t *testing.T) {
	raw := []byte(`{"schema":"` + sdk.PluginInputsSchemaV1 + `","inputs":[{"name":"targets","entity":"devices","items":[]}]}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("templateless envelope must decode: %v", err)
	}

	result := runInventorySync(cfg)
	if result.Status != sdk.StatusUnknown {
		t.Fatalf("expected Unknown, got %v", result.Status)
	}
	if !strings.Contains(result.Summary, "has no source configured") {
		t.Fatalf("summary must name the missing source, got %q", result.Summary)
	}
}

func TestDecodeConfigEmptyPayload(t *testing.T) {
	cfg, err := decodeConfig(nil)
	if err != nil {
		t.Fatalf("empty payload must decode: %v", err)
	}
	if len(cfg.sourceConfigs()) != 0 {
		t.Fatalf("empty payload must configure no source")
	}
}

// The "could not be parsed" branch has exactly two reachable inputs: a flat
// config object whose JSON types do not match Config, and a plugin_inputs
// envelope whose template does not. Both must report Unknown rather than
// falling through to a sync with a half-decoded config.
func TestInventorySyncFlatConfigTypeMismatchReportsParseFailure(t *testing.T) {
	// base_url is a string on Config; a number reaches json.Unmarshal only
	// after looksLikePluginInputs decides this is not an envelope.
	raw := []byte(`{"source_id":"lab","base_url":42,"api_token":"t"}`)

	if _, err := decodeConfig(raw); err == nil {
		t.Fatalf("flat config with a mistyped field must not decode")
	}

	result := inventorySyncFromRawConfig(raw)
	if result.Status != sdk.StatusUnknown {
		t.Fatalf("expected Unknown, got %v", result.Status)
	}
	if !strings.Contains(result.Summary, "could not be parsed") {
		t.Fatalf("summary must name the parse failure, got %q", result.Summary)
	}
}

func TestInventorySyncMalformedEnvelopeTemplateReportsParseFailure(t *testing.T) {
	// page_size is an int on Config. The envelope itself is well formed, so
	// the failure comes from unmarshalling env.Template.
	raw := []byte(`{
	  "schema": "` + sdk.PluginInputsSchemaV1 + `",
	  "policy_id": "network-credential-rule:r1:inventory_sync",
	  "policy_version": 1,
	  "agent_id": "agent-1",
	  "template": {
	    "base_url": "https://netbox.example.com",
	    "api_token": "resolved-token",
	    "page_size": "every-device"
	  },
	  "inputs": [{"name":"targets","entity":"devices","items":[{"uid":"d1"}]}]
	}`)

	if _, err := decodeConfig(raw); err == nil {
		t.Fatalf("envelope with a mistyped template field must not decode")
	}

	result := inventorySyncFromRawConfig(raw)
	if result.Status != sdk.StatusUnknown {
		t.Fatalf("expected Unknown, got %v", result.Status)
	}
	if !strings.Contains(result.Summary, "could not be parsed") {
		t.Fatalf("summary must name the parse failure, got %q", result.Summary)
	}
}
