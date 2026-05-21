//go:build tinygo

package main

import (
	"strings"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func configFromRawConfig(raw string) Config {
	cfg := defaultConfig()
	cfg.BaseURL = jsonStringValue(raw, "base_url")
	cfg.APIToken = jsonStringValue(raw, "api_token")
	cfg.APITokenSecretRef = jsonStringValue(raw, "api_token_secret_ref")
	cfg.TimeoutMS = jsonIntValue(raw, "timeout_ms")
	cfg.MaxResponseBytes = jsonIntValue(raw, "max_response_bytes")
	if value, ok := jsonBoolValue(raw, "include_guests"); ok {
		cfg.IncludeGuests = &value
	}
	if value, ok := jsonBoolValue(raw, "insecure_skip_verify"); ok {
		cfg.InsecureSkipVerify = value
	}
	if value, ok := jsonBoolValue(raw, "auto_discovery_enabled"); ok {
		cfg.AutoDiscovery = value
	}

	if strings.Contains(raw, sdk.PluginInputsSchemaV1) {
		cfg.Targets = targetsFromRawPluginInputItems(raw, cfg)
		if len(cfg.Targets) > 0 {
			cfg.BaseURL = ""
		}
	}

	return cfg
}

func targetsFromRawPluginInputItems(raw string, cfg Config) []Target {
	items := rawJSONObjectList(rawItemsArray(raw))
	targets := make([]Target, 0, len(items))

	for _, item := range items {
		target := targetFromRawPluginInputItem(item, cfg)
		if strings.TrimSpace(target.BaseURL) != "" {
			targets = append(targets, target)
		}
	}

	return dedupeTargets(targets)
}

func targetFromRawPluginInputItem(item string, cfg Config) Target {
	hostname := firstNonEmpty(jsonStringValue(item, "hostname"), jsonStringValue(item, "name"))

	return Target{
		BaseURL:  rawItemBaseURL(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			jsonStringValue(item, "uid"),
			jsonStringValue(item, "device_uid"),
			jsonStringValue(item, "device_id"),
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			jsonStringValue(item, "partition"),
			jsonStringValue(item, "site"),
		),
	}
}

func rawItemBaseURL(item string, cfg Config) string {
	direct := firstNonEmpty(
		jsonStringValue(item, "base_url"),
		jsonStringValue(item, "proxmox_base_url"),
		jsonStringValue(item, "endpoint"),
		jsonStringValue(item, "management_url"),
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		jsonStringValue(item, "ip"),
		jsonStringValue(item, "device_ip"),
		jsonStringValue(item, "hostname"),
		jsonStringValue(item, "name"),
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}
