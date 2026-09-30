package main

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

const (
	defaultTimeoutMS          = 20000
	minTimeoutMS              = 5000
	maxTimeoutMS              = 60000
	defaultMaxRequestsPerRun  = 120
	maxMaxRequestsPerRun      = 240
	defaultTelemetryBatchSize = 1000
	// maxTelemetryBatchSize keeps one stream response well under the host
	// HTTP response cap; a row is a few hundred bytes of JSON.
	maxTelemetryBatchSize        = 5000
	defaultTelemetryLingerMS     = 5000
	maxTelemetryLingerMS         = 15000
	defaultTelemetryMaxIteration = 8
	maxTelemetryMaxIteration     = 30
	// telemetryLingerHeadroomMS is how much of the request timeout is left for
	// the response after the server stops lingering.
	telemetryLingerHeadroomMS = 4000
)

// forbiddenConfigKeys are credential material. The service-account secret is
// brokered to the agent host and must never reach the guest; a config that
// carries one is refused rather than used.
var forbiddenConfigKeys = []string{
	"client_secret", "client_id", "access_token", "token", "api_token", "password", "authorization",
}

var errConfigSecret = errors.New("starlink_config_contains_credential")

// Config is the merged runtime configuration: plugin config overlaid with the
// action invocation's input values (producer-schedule settings arrive there).
type Config struct {
	ActionID string
	// InstanceLabel is an optional operator label for the account; it only
	// decorates results.
	InstanceLabel         string
	TimeoutMS             int
	MaxRequestsPerRun     int
	TelemetryBatchSize    int
	TelemetryMaxLingerMS  int
	TelemetryMaxIteration int
	// Invocation is the raw action invocation, kept for management actions.
	Invocation gjson.Result
}

func loadConfig() (Config, error) {
	var raw json.RawMessage
	if err := sdk.GetConfig(&raw); err != nil {
		return Config{}, errors.New("starlink_config_read_failed")
	}
	return parseConfig(raw)
}

func parseConfig(raw []byte) (Config, error) {
	root := gjson.ParseBytes(raw)
	if !root.IsObject() {
		return Config{}, errors.New("starlink_config_invalid")
	}

	invocation := root.Get("action_invocation")
	inputs := invocation.Get("input_values")

	for _, key := range forbiddenConfigKeys {
		if root.Get(key).Exists() || inputs.Get(key).Exists() {
			return Config{}, errConfigSecret
		}
	}

	value := func(key string) gjson.Result {
		if v := inputs.Get(key); v.Exists() {
			return v
		}
		return root.Get(key)
	}

	cfg := Config{
		ActionID:              strings.TrimSpace(invocation.Get("action_id").String()),
		InstanceLabel:         strings.TrimSpace(value("instance_label").String()),
		TimeoutMS:             boundedInt(value("timeout_ms"), defaultTimeoutMS, minTimeoutMS, maxTimeoutMS),
		MaxRequestsPerRun:     boundedInt(value("max_requests_per_run"), defaultMaxRequestsPerRun, 1, maxMaxRequestsPerRun),
		TelemetryBatchSize:    boundedInt(value("telemetry_batch_size"), defaultTelemetryBatchSize, 1, maxTelemetryBatchSize),
		TelemetryMaxLingerMS:  boundedInt(value("telemetry_max_linger_ms"), defaultTelemetryLingerMS, 0, maxTelemetryLingerMS),
		TelemetryMaxIteration: boundedInt(value("telemetry_max_iterations"), defaultTelemetryMaxIteration, 1, maxTelemetryMaxIteration),
		Invocation:            invocation,
	}

	// The server holds a stream request for up to the linger time before it
	// answers, so the request timeout must outlast it.
	if limit := cfg.TimeoutMS - telemetryLingerHeadroomMS; cfg.TelemetryMaxLingerMS > limit {
		cfg.TelemetryMaxLingerMS = max(limit, 0)
	}
	return cfg, nil
}

// boundedInt reads an integer setting, falling back to def when it is absent
// or not a number and clamping it into [lo, hi].
func boundedInt(v gjson.Result, def, lo, hi int) int {
	if !v.Exists() || v.Type != gjson.Number {
		return def
	}
	n := int(v.Int())
	return min(max(n, lo), hi)
}
