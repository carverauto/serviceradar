package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func loadConfig() (Config, error) {
	raw, err := loadConfigBytes()
	if err != nil {
		return defaultConfig(), err
	}
	if len(raw) == 0 {
		return defaultConfig(), nil
	}

	return configFromRawConfig(string(raw)), nil
}

func configFromJSON(raw json.RawMessage) (Config, error) {
	if containsForbiddenProxmoxPublicConfigJSON(raw) {
		return defaultConfig(), errors.New("legacy credential or TLS override is forbidden")
	}
	if looksLikePluginInputsJSON(raw) {
		return configFromPluginInputsJSON(raw)
	}

	cfg := defaultConfig()
	if err := applyConfigJSON(raw, &cfg); err != nil {
		return defaultConfig(), err
	}

	return cfg, nil
}

func configFromMap(raw map[string]any) (Config, error) {
	if containsForbiddenProxmoxPublicConfigValue(raw) {
		return defaultConfig(), errors.New("legacy credential or TLS override is forbidden")
	}
	if looksLikePluginInputs(raw) {
		return configFromPluginInputs(raw)
	}

	cfg := defaultConfig()
	if err := applyConfigMap(raw, &cfg); err != nil {
		return defaultConfig(), err
	}

	return cfg, nil
}

func configFromPluginInputsJSON(raw json.RawMessage) (Config, error) {
	var payload pluginInputsJSON
	if err := json.Unmarshal(raw, &payload); err != nil {
		return defaultConfig(), err
	}

	return configFromPluginInputsPayload(payload)
}

func configFromPluginInputsPayload(payload pluginInputsJSON) (Config, error) {
	if err := validatePluginInputsJSON(payload); err != nil {
		return defaultConfig(), err
	}

	cfg := defaultConfig()
	if payload.Template != nil {
		applyConfigStruct(*payload.Template, &cfg)
	}

	generatedTargets := targetsFromPluginInputsJSON(payload, cfg)
	if len(generatedTargets) > 0 {
		cfg.Targets = append(cfg.Targets, generatedTargets...)
		cfg.Targets = dedupeTargets(cfg.Targets)
		cfg.BaseURL = ""
	}

	return cfg, nil
}

func configFromPluginInputs(raw map[string]any) (Config, error) {
	payload, err := sdk.ParsePluginInputsMap(raw)
	if err != nil {
		return defaultConfig(), err
	}

	cfg := defaultConfig()
	if payload.Template != nil {
		if err := applyConfigMap(payload.Template, &cfg); err != nil {
			return defaultConfig(), err
		}
	}

	generatedTargets := targetsFromPluginInputs(payload, cfg)
	if len(generatedTargets) > 0 {
		cfg.Targets = append(cfg.Targets, generatedTargets...)
		cfg.Targets = dedupeTargets(cfg.Targets)
		cfg.BaseURL = ""
	}

	return cfg, nil
}
func applyConfigMap(raw map[string]any, cfg *Config) error {
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(encoded, cfg); err != nil {
		return err
	}

	return nil
}

func applyConfigJSON(raw json.RawMessage, cfg *Config) error {
	var decoded configJSON
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return err
	}

	applyConfigStruct(decoded, cfg)

	return nil
}

func applyConfigStruct(decoded configJSON, cfg *Config) {
	cfg.BaseURL = decoded.BaseURL
	cfg.APIToken = decoded.APIToken
	cfg.Targets = decoded.Targets
	cfg.TimeoutMS = decoded.TimeoutMS
	cfg.MaxResponseBytes = decoded.MaxResponseBytes
	cfg.MaxGuests = decoded.MaxGuests
	cfg.IncludeGuests = decoded.IncludeGuests
	cfg.AutoDiscovery = decoded.AutoDiscovery
}
func (cfg *Config) applyDefaults() {
	if cfg.TimeoutMS <= 0 {
		cfg.TimeoutMS = defaultTimeoutMS
	}
	if cfg.TimeoutMS > maxTimeoutMS {
		cfg.TimeoutMS = maxTimeoutMS
	}
	if cfg.MaxResponseBytes <= 0 {
		cfg.MaxResponseBytes = defaultHTTPMaxResponseBytes
	}
	if cfg.MaxResponseBytes > maxHTTPResponseBytes {
		cfg.MaxResponseBytes = maxHTTPResponseBytes
	}
	if cfg.MaxGuests <= 0 {
		cfg.MaxGuests = defaultMaxGuests
	}
	if cfg.MaxGuests > maxGuests {
		cfg.MaxGuests = maxGuests
	}
	if cfg.Targets == nil {
		cfg.Targets = []Target{}
	}
}

func (cfg Config) includeGuests() bool {
	if cfg.IncludeGuests == nil {
		return true
	}

	return *cfg.IncludeGuests
}

func (cfg Config) effectiveTargets() []Target {
	targets := make([]Target, 0, len(cfg.Targets)+1)
	for _, target := range cfg.Targets {
		if strings.TrimSpace(target.BaseURL) != "" {
			targets = append(targets, target)
		}
	}

	if strings.TrimSpace(cfg.BaseURL) != "" {
		targets = append(targets, Target{
			BaseURL:  cfg.BaseURL,
			APIToken: cfg.APIToken,
		})
	}

	return targets
}

func looksLikePluginInputs(raw map[string]any) bool {
	if strings.TrimSpace(stringValue(raw, "schema")) == sdk.PluginInputsSchemaV1 {
		return true
	}
	if _, ok := raw["inputs"]; ok {
		return true
	}

	return false
}

func looksLikePluginInputsPayload(payload pluginInputsJSON) bool {
	return strings.TrimSpace(payload.Schema) == sdk.PluginInputsSchemaV1 ||
		len(payload.Inputs) > 0 ||
		strings.TrimSpace(payload.PolicyID) != ""
}

func looksLikePluginInputsJSON(raw json.RawMessage) bool {
	var probe struct {
		Schema string            `json:"schema"`
		Inputs []json.RawMessage `json:"inputs"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return false
	}

	return strings.TrimSpace(probe.Schema) == sdk.PluginInputsSchemaV1 || len(probe.Inputs) > 0
}

func validatePluginInputsJSON(payload pluginInputsJSON) error {
	if strings.TrimSpace(payload.Schema) != sdk.PluginInputsSchemaV1 {
		return fmt.Errorf("plugin inputs payload has invalid schema: %q", payload.Schema)
	}
	if strings.TrimSpace(payload.PolicyID) == "" {
		return errors.New("plugin inputs payload missing policy_id")
	}
	if payload.PolicyVersion < 1 {
		return errors.New("plugin inputs payload has invalid policy_version")
	}
	if strings.TrimSpace(payload.AgentID) == "" {
		return errors.New("plugin inputs payload missing agent_id")
	}
	if strings.TrimSpace(payload.GeneratedAt) == "" {
		return errors.New("plugin inputs payload missing generated_at")
	}
	if len(payload.Inputs) == 0 {
		return errors.New("plugin inputs payload missing inputs")
	}

	for i, input := range payload.Inputs {
		if strings.TrimSpace(input.Name) == "" {
			return fmt.Errorf("plugin inputs payload missing input name at inputs[%d]", i)
		}
		if strings.TrimSpace(input.Entity) == "" {
			return fmt.Errorf("plugin inputs payload missing input entity at inputs[%d]", i)
		}
		if strings.TrimSpace(input.Query) == "" {
			return fmt.Errorf("plugin inputs payload missing input query at inputs[%d]", i)
		}
		if input.ChunkIndex < 0 {
			return fmt.Errorf("plugin inputs payload has invalid input chunk_index at inputs[%d]", i)
		}
		if input.ChunkTotal < 1 {
			return fmt.Errorf("plugin inputs payload has invalid input chunk_total at inputs[%d]", i)
		}
		if strings.TrimSpace(input.ChunkHash) == "" {
			return fmt.Errorf("plugin inputs payload missing input chunk_hash at inputs[%d]", i)
		}
		if len(input.Items) == 0 {
			return fmt.Errorf("plugin inputs payload missing input items at inputs[%d]", i)
		}
	}

	return nil
}

func targetsFromPluginInputs(payload *sdk.PluginInputsPayload, cfg Config) []Target {
	if payload == nil {
		return nil
	}

	targets := make([]Target, 0)
	for _, input := range payload.FlattenItems() {
		if input.Entity != "devices" {
			continue
		}

		target := targetFromInputItem(input.Item, cfg)
		if strings.TrimSpace(target.BaseURL) != "" {
			targets = append(targets, target)
		}
	}

	return targets
}

func targetsFromPluginInputsJSON(payload pluginInputsJSON, cfg Config) []Target {
	targets := make([]Target, 0)
	for _, input := range payload.Inputs {
		if input.Entity != "devices" {
			continue
		}

		for _, item := range input.Items {
			target := targetFromPluginInputItem(item, cfg)
			if strings.TrimSpace(target.BaseURL) != "" {
				targets = append(targets, target)
			}
		}
	}

	return targets
}

func targetFromInputItem(item map[string]any, cfg Config) Target {
	hostname := firstNonEmpty(
		stringValue(item, "hostname"),
		stringValue(item, "name"),
	)

	return Target{
		BaseURL:  baseURLForItem(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			stringValue(item, "uid"),
			stringValue(item, "device_uid"),
			stringValue(item, "device_id"),
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			stringValue(item, "partition"),
			stringValue(item, "site"),
		),
	}
}

func targetFromPluginInputItem(item pluginInputItem, cfg Config) Target {
	hostname := firstNonEmpty(item.Hostname, item.Name)

	return Target{
		BaseURL:  baseURLForPluginInputItem(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			item.UID,
			item.DeviceUID,
			item.DeviceID,
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			item.Partition,
			item.Site,
		),
	}
}

func applyHTTPClientLimits(cfg Config) {
	client, ok := proxmoxHTTP.(*sdk.HTTPClient)
	if !ok {
		return
	}

	client.MaxResponseBytes = uint32(cfg.MaxResponseBytes)
}

func baseURLForItem(item map[string]any, cfg Config) string {
	direct := firstNonEmpty(
		stringValue(item, "base_url"),
		stringValue(item, "proxmox_base_url"),
		stringValue(item, "endpoint"),
		stringValue(item, "management_url"),
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		stringValue(item, "ip"),
		stringValue(item, "device_ip"),
		stringValue(item, "hostname"),
		stringValue(item, "name"),
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}

func baseURLForPluginInputItem(item pluginInputItem, cfg Config) string {
	direct := firstNonEmpty(
		item.BaseURL,
		item.ProxmoxBaseURL,
		item.Endpoint,
		item.ManagementURL,
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		item.IP,
		item.DeviceIP,
		item.Hostname,
		item.Name,
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}

func normalizeBaseURL(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://") {
		return strings.TrimRight(value, "/")
	}

	return "https://" + strings.TrimRight(value, "/") + ":8006"
}

func normalizeProxmoxAPIToken(value string) string {
	value = strings.TrimSpace(value)
	if value == hostCredentialSentinel {
		return value
	}
	return ""
}

func containsForbiddenProxmoxPublicConfigJSON(raw json.RawMessage) bool {
	var decoded any
	return json.Unmarshal(raw, &decoded) == nil && containsForbiddenProxmoxPublicConfigValue(decoded)
}

func containsForbiddenProxmoxPublicConfigValue(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			switch key {
			case "api_token_secret_ref", "credential_secret_ref", "credential_broker", "insecure_skip_verify",
				"ssh", "ssh_host_key_policy":
				return true
			case "api_token", "credential_secret":
				text, ok := child.(string)
				if !ok || text != hostCredentialSentinel {
					return true
				}
			case "password", "private_key", "passphrase":
				return true
			}
			if containsForbiddenProxmoxPublicConfigValue(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if containsForbiddenProxmoxPublicConfigValue(child) {
				return true
			}
		}
	}
	return false
}

func dedupeTargets(targets []Target) []Target {
	seen := map[string]bool{}
	out := make([]Target, 0, len(targets))

	for _, target := range targets {
		key := target.BaseURL + "|" + target.DeviceID + "|" + target.Hostname
		if seen[key] || strings.TrimSpace(target.BaseURL) == "" {
			continue
		}
		seen[key] = true
		out = append(out, target)
	}

	return out
}

func stringValue(mapValue map[string]any, key string) string {
	if mapValue == nil {
		return ""
	}
	if value, ok := mapValue[key]; ok {
		switch typed := value.(type) {
		case string:
			return strings.TrimSpace(typed)
		case fmt.Stringer:
			return strings.TrimSpace(typed.String())
		}
	}

	return ""
}
