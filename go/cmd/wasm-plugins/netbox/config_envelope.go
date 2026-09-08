package main

import (
	"encoding/json"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// pluginInputsEnvelope is the typed view of a serviceradar.plugin_inputs.v1
// payload. A credential-rule-materialized assignment puts the source's public
// fields in `template` (base_url, page_size, timeout_ms, ...) alongside the
// api_token that config delivery resolved from the rule's secret; the
// `inputs[].items[]` targets only scoped the rule to this agent and carry
// nothing the sync needs.
type pluginInputsEnvelope struct {
	Schema   string            `json:"schema"`
	Template json.RawMessage   `json:"template"`
	Inputs   []json.RawMessage `json:"inputs"`
}

// loadRawConfigBytes returns the raw host-provided config so the plugin can
// tell a flat config object from a plugin_inputs envelope before decoding.
func loadRawConfigBytes() (json.RawMessage, error) {
	var raw json.RawMessage
	if err := sdk.LoadConfig(&raw); err != nil {
		return nil, err
	}

	return raw, nil
}

// decodeConfig parses the host-provided config, transparently handling both a
// hand-written config object and a serviceradar.plugin_inputs.v1 envelope.
func decodeConfig(raw []byte) (Config, error) {
	var cfg Config
	if strings.TrimSpace(string(raw)) == "" {
		return cfg, nil
	}

	if looksLikePluginInputs(raw) {
		var env pluginInputsEnvelope
		if err := json.Unmarshal(raw, &env); err != nil {
			return cfg, err
		}
		if len(env.Template) == 0 {
			return cfg, nil
		}

		return cfg, json.Unmarshal(env.Template, &cfg)
	}

	return cfg, json.Unmarshal(raw, &cfg)
}

func looksLikePluginInputs(raw []byte) bool {
	var probe struct {
		Schema string            `json:"schema"`
		Inputs []json.RawMessage `json:"inputs"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return false
	}

	return strings.TrimSpace(probe.Schema) == sdk.PluginInputsSchemaV1 || len(probe.Inputs) > 0
}
