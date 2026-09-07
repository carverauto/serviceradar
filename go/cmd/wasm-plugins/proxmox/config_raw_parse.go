package main

import (
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

// configFromRawConfigGJSON parses raw plugin config JSON with gjson instead of
// encoding/json so the TinyGo build can use it (see config_raw_tinygo.go). It
// must mirror the std path (configFromJSON in config.go) exactly; the parity
// is enforced by TestConfigFromRawConfigGJSONMatchesStdParser.
//
// In particular, serviceradar.plugin_inputs.v1 payloads apply the `template`
// object wholesale, exactly like configFromPluginInputsPayload does via
// applyConfigStruct. The API token visible to Wasm is only the fixed host
// credential sentinel; the agent injects real material after authorization.
func configFromRawConfigGJSON(raw string) Config {
	if !gjson.Valid(raw) {
		// std: json.Unmarshal fails -> configFromRawConfig falls back to
		// defaultConfig().
		return defaultConfig()
	}

	root := gjson.Parse(raw)
	if !root.IsObject() {
		// std: unmarshalling a non-object into configJSON errors out.
		return defaultConfig()
	}
	if rawContainsForbiddenProxmoxPublicConfig(root) {
		return defaultConfig()
	}

	if rawLooksLikePluginInputs(root) {
		return configFromRawPluginInputs(root)
	}

	cfg := defaultConfig()
	applyRawConfigStruct(root, &cfg)

	return cfg
}

// rawLooksLikePluginInputs mirrors looksLikePluginInputsJSON.
func rawLooksLikePluginInputs(root gjson.Result) bool {
	if strings.TrimSpace(root.Get("schema").String()) == sdk.PluginInputsSchemaV1 {
		return true
	}

	inputs := root.Get("inputs")

	return inputs.IsArray() && len(inputs.Array()) > 0
}

// configFromRawPluginInputs mirrors configFromPluginInputsPayload: validate the
// payload, apply the template wholesale, then derive per-target entries that
// inherit the host credential sentinel.
func configFromRawPluginInputs(root gjson.Result) Config {
	if !rawPluginInputsValid(root) {
		return defaultConfig()
	}

	cfg := defaultConfig()
	if template := root.Get("template"); template.IsObject() {
		applyRawConfigStruct(template, &cfg)
	}

	generatedTargets := targetsFromRawPluginInputItems(root, cfg)
	if len(generatedTargets) > 0 {
		cfg.Targets = append(cfg.Targets, generatedTargets...)
		cfg.Targets = dedupeTargets(cfg.Targets)
		cfg.BaseURL = ""
	}

	return cfg
}

// rawPluginInputsValid mirrors validatePluginInputsJSON.
func rawPluginInputsValid(root gjson.Result) bool {
	if strings.TrimSpace(root.Get("schema").String()) != sdk.PluginInputsSchemaV1 {
		return false
	}
	if strings.TrimSpace(root.Get("policy_id").String()) == "" {
		return false
	}
	if root.Get("policy_version").Int() < 1 {
		return false
	}
	if strings.TrimSpace(root.Get("agent_id").String()) == "" {
		return false
	}
	if strings.TrimSpace(root.Get("generated_at").String()) == "" {
		return false
	}

	inputs := root.Get("inputs")
	if !inputs.IsArray() {
		return false
	}
	inputList := inputs.Array()
	if len(inputList) == 0 {
		return false
	}

	for _, input := range inputList {
		if strings.TrimSpace(input.Get("name").String()) == "" ||
			strings.TrimSpace(input.Get("entity").String()) == "" ||
			strings.TrimSpace(input.Get("query").String()) == "" {
			return false
		}
		if input.Get("chunk_index").Int() < 0 {
			return false
		}
		if input.Get("chunk_total").Int() < 1 {
			return false
		}
		if strings.TrimSpace(input.Get("chunk_hash").String()) == "" {
			return false
		}
		items := input.Get("items")
		if !items.IsArray() || len(items.Array()) == 0 {
			return false
		}
	}

	return true
}

// applyRawConfigStruct mirrors applyConfigStruct: every configJSON field is
// assigned unconditionally, so absent fields reset to their zero value exactly
// like decoding into a fresh configJSON struct does (applyDefaults later
// restores timeout/response-size floors).
func applyRawConfigStruct(node gjson.Result, cfg *Config) {
	cfg.BaseURL = node.Get("base_url").String()
	cfg.APIToken = node.Get("api_token").String()
	cfg.Targets = rawConfigTargets(node.Get("targets"))
	cfg.TimeoutMS = int(node.Get("timeout_ms").Int())
	cfg.MaxResponseBytes = int(node.Get("max_response_bytes").Int())
	cfg.MaxGuests = int(node.Get("max_guests").Int())
	cfg.IncludeGuests = nil
	if value := node.Get("include_guests"); value.IsBool() {
		includeGuests := value.Bool()
		cfg.IncludeGuests = &includeGuests
	}
	cfg.AutoDiscovery = node.Get("auto_discovery_enabled").Bool()
}

func rawContainsForbiddenProxmoxPublicConfig(node gjson.Result) bool {
	forbidden := false
	if node.IsObject() {
		node.ForEach(func(key, value gjson.Result) bool {
			switch key.String() {
			case "api_token_secret_ref", "credential_secret_ref", "credential_broker", "insecure_skip_verify",
				"ssh", "ssh_host_key_policy":
				forbidden = true
				return false
			case "api_token", "credential_secret":
				if value.String() != hostCredentialSentinel {
					forbidden = true
					return false
				}
			case "password", "private_key", "passphrase":
				forbidden = true
				return false
			}
			if rawContainsForbiddenProxmoxPublicConfig(value) {
				forbidden = true
				return false
			}
			return true
		})
	} else if node.IsArray() {
		for _, child := range node.Array() {
			if rawContainsForbiddenProxmoxPublicConfig(child) {
				return true
			}
		}
	}
	return forbidden
}

// rawConfigTargets mirrors decoding configJSON.Targets: absent/null yields nil,
// an array yields one Target per element.
func rawConfigTargets(node gjson.Result) []Target {
	if !node.IsArray() {
		return nil
	}

	items := node.Array()
	targets := make([]Target, 0, len(items))
	for _, item := range items {
		targets = append(targets, Target{
			BaseURL:   item.Get("base_url").String(),
			APIToken:  item.Get("api_token").String(),
			DeviceID:  item.Get("device_id").String(),
			Hostname:  item.Get("hostname").String(),
			Partition: item.Get("partition").String(),
		})
	}

	return targets
}

// targetsFromRawPluginInputItems mirrors targetsFromPluginInputsJSON: only
// `devices` inputs contribute targets, and each target inherits cfg.APIToken
// (the template token after applyRawConfigStruct). Deduplication happens in
// the caller, matching the std path.
func targetsFromRawPluginInputItems(root gjson.Result, cfg Config) []Target {
	targets := make([]Target, 0)

	for _, input := range root.Get("inputs").Array() {
		if input.Get("entity").String() != "devices" {
			continue
		}

		for _, item := range input.Get("items").Array() {
			target := targetFromRawPluginInputItem(item, cfg)
			if strings.TrimSpace(target.BaseURL) != "" {
				targets = append(targets, target)
			}
		}
	}

	return targets
}

// targetFromRawPluginInputItem mirrors targetFromPluginInputItem.
func targetFromRawPluginInputItem(item gjson.Result, cfg Config) Target {
	hostname := firstNonEmpty(item.Get("hostname").String(), item.Get("name").String())

	return Target{
		BaseURL:  rawItemBaseURL(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			item.Get("uid").String(),
			item.Get("device_uid").String(),
			item.Get("device_id").String(),
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			item.Get("partition").String(),
			item.Get("site").String(),
		),
	}
}

// rawItemBaseURL mirrors baseURLForPluginInputItem.
func rawItemBaseURL(item gjson.Result, cfg Config) string {
	direct := firstNonEmpty(
		item.Get("base_url").String(),
		item.Get("proxmox_base_url").String(),
		item.Get("endpoint").String(),
		item.Get("management_url").String(),
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		item.Get("ip").String(),
		item.Get("device_ip").String(),
		item.Get("hostname").String(),
		item.Get("name").String(),
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}
