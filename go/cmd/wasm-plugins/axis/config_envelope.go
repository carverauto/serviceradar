package main

import (
	"encoding/json"
	"net/url"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const defaultAxisRTSPPort = 554

// pluginInputsEnvelope is the typed view of a serviceradar.plugin_inputs.v1
// payload. The agent injects this for policy-driven, per-target camera
// assignments: `template` carries the materialized base params (scheme,
// timeout_ms, credentials, ...) while `inputs[].items[]` carry the resolved
// SRQL targets. Host is derived per target from the item ip/hostname, mirroring
// the proxmox plugin so the camera plugins never require an inline host.
type pluginInputsEnvelope struct {
	Schema   string             `json:"schema"`
	Template json.RawMessage    `json:"template"`
	Inputs   []pluginInputGroup `json:"inputs"`
}

type pluginInputGroup struct {
	Entity string            `json:"entity"`
	Items  []pluginInputItem `json:"items"`
}

// pluginInputItem is a single resolved SRQL target. The camera host is derived
// from ip -> device_ip -> host -> hostname -> name (ip preferred).
type pluginInputItem struct {
	IP        string `json:"ip"`
	DeviceIP  string `json:"device_ip"`
	Host      string `json:"host"`
	Hostname  string `json:"hostname"`
	Name      string `json:"name"`
	UID       string `json:"uid"`
	DeviceUID string `json:"device_uid"`
	DeviceID  string `json:"device_id"`
}

func (item pluginInputItem) host() string {
	return firstNonBlank(
		item.IP,
		item.DeviceIP,
		item.Host,
		item.Hostname,
		item.Name,
	)
}

// defaultConfig returns the AXIS inventory plugin defaults. Timeout is left
// empty so timeout_ms (or the legacy timeout string) drives the effective value
// via normalizeTimeout; scheme defaults to https to match the credential
// materializer from this package's credential profile params_template.
func defaultConfig() Config {
	base := sdk.DefaultCameraPluginConfig()
	base.Scheme = "https"
	base.Timeout = ""
	return Config{
		CameraPluginConfig: base,
		RTSPPort:           defaultAxisRTSPPort,
	}
}

// loadRawConfigBytes returns the raw host-provided config bytes by decoding into
// a json.RawMessage. This lets the plugin detect and parse the plugin_inputs
// envelope itself (host is injected per target, not inline).
func loadRawConfigBytes() (json.RawMessage, error) {
	var raw json.RawMessage
	if err := sdk.LoadConfig(&raw); err != nil {
		return nil, err
	}
	return raw, nil
}

// decodeConfig parses the host-provided config, transparently handling both a
// flat config object and a serviceradar.plugin_inputs.v1 envelope.
func decodeConfig(raw []byte) (Config, error) {
	cfg := defaultConfig()
	if len(strings.TrimSpace(string(raw))) == 0 {
		normalizeTimeout(&cfg)
		return cfg, nil
	}

	if looksLikePluginInputs(raw) {
		if err := applyPluginInputs(raw, &cfg); err != nil {
			return cfg, err
		}
	} else if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, err
	}

	normalizeTimeout(&cfg)
	return cfg, nil
}

// applyPluginInputs merges the envelope template over the defaulted config and
// injects the per-target host from the first resolvable device item.
func applyPluginInputs(raw []byte, cfg *Config) error {
	var env pluginInputsEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return err
	}
	if len(env.Template) > 0 {
		if err := json.Unmarshal(env.Template, cfg); err != nil {
			return err
		}
	}
	if host := hostFromEnvelopeItems(env.Inputs); host != "" {
		cfg.Host = host
	}
	return nil
}

// hostFromEnvelopeItems returns the first usable host among device items,
// preferring the `devices` entity when the input names an entity.
func hostFromEnvelopeItems(inputs []pluginInputGroup) string {
	for _, group := range inputs {
		entity := strings.TrimSpace(group.Entity)
		if entity != "" && !strings.EqualFold(entity, "devices") {
			continue
		}
		for _, item := range group.Items {
			if host := item.host(); host != "" {
				return host
			}
		}
	}
	return ""
}

// hostFromRelaySourceURL extracts the host from an injected relay source URL
// (for example rtsp://10.0.0.5:554/axis-media/media.amp). Streaming plugins use
// this so media works when the agent injects only the relay object and no host
// envelope.
func hostFromRelaySourceURL(sourceURL string) string {
	sourceURL = strings.TrimSpace(sourceURL)
	if sourceURL == "" {
		return ""
	}
	parsed, err := url.Parse(sourceURL)
	if err != nil {
		return ""
	}
	return parsed.Hostname()
}

func looksLikePluginInputs(raw []byte) bool {
	if len(raw) == 0 {
		return false
	}
	var probe struct {
		Schema string            `json:"schema"`
		Inputs []json.RawMessage `json:"inputs"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return false
	}
	return strings.TrimSpace(probe.Schema) == sdk.PluginInputsSchemaV1 || len(probe.Inputs) > 0
}

// normalizeTimeout resolves the effective request timeout string consumed by the
// SDK HTTP client. timeout_ms (canonical, from the materializer) wins; otherwise
// the legacy timeout string is kept; otherwise a 10s default is applied.
func normalizeTimeout(cfg *Config) {
	if cfg.TimeoutMS > 0 {
		cfg.Timeout = strconv.Itoa(cfg.TimeoutMS) + "ms"
		return
	}
	if strings.TrimSpace(cfg.Timeout) == "" {
		cfg.Timeout = "10s"
	}
}

// axisRTSPHost returns the RTSP host, appending the configured rtsp_port only
// when it is non-standard (RTSP omits the port for the default 554).
func axisRTSPHost(cfg Config) string {
	host := strings.TrimSpace(cfg.Host)
	if host == "" {
		return host
	}
	if cfg.RTSPPort > 0 && cfg.RTSPPort != defaultAxisRTSPPort {
		return host + ":" + strconv.Itoa(cfg.RTSPPort)
	}
	return host
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}
