//go:build tinygo

package main

import (
	"strings"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
	"github.com/tidwall/gjson"
)

func configFromRawConfig(raw string) Config {
	root := gjson.Parse(raw)
	cfg := defaultConfig()
	cfg.BaseURL = root.Get("base_url").String()
	cfg.APIToken = root.Get("api_token").String()
	cfg.APITokenSecretRef = root.Get("api_token_secret_ref").String()
	cfg.TimeoutMS = int(root.Get("timeout_ms").Int())
	cfg.MaxResponseBytes = int(root.Get("max_response_bytes").Int())
	if value := root.Get("include_guests"); value.Exists() {
		includeGuests := value.Bool()
		cfg.IncludeGuests = &includeGuests
	}
	if value := root.Get("insecure_skip_verify"); value.Exists() {
		cfg.InsecureSkipVerify = value.Bool()
	}
	if value := root.Get("auto_discovery_enabled"); value.Exists() {
		cfg.AutoDiscovery = value.Bool()
	}

	if strings.TrimSpace(root.Get("schema").String()) == sdk.PluginInputsSchemaV1 ||
		root.Get("inputs").Exists() ||
		strings.Contains(raw, sdk.PluginInputsSchemaV1) {
		cfg.Targets = targetsFromRawPluginInputItems(root, cfg)
		if len(cfg.Targets) > 0 {
			cfg.BaseURL = ""
		}
	}

	return cfg
}

func targetsFromRawPluginInputItems(root gjson.Result, cfg Config) []Target {
	inputs := root.Get("inputs").Array()
	targets := make([]Target, 0)

	for _, input := range inputs {
		input.Get("items").ForEach(func(_key, item gjson.Result) bool {
			target := targetFromRawPluginInputItem(item, cfg)
			if strings.TrimSpace(target.BaseURL) != "" {
				targets = append(targets, target)
			}
			return true
		})
	}

	return dedupeTargets(targets)
}

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
