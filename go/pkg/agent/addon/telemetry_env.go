/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// telemetry_env.go implements the self-telemetry env convention
// (refactor-otel-signal-correlation, 10.5): when the otel-collector add-on is
// part of the desired add-on set, every OTHER spawned add-on subprocess gets
// OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_EXPORTER_OTLP_PROTOCOL pointed at the
// collector's loopback OTLP/gRPC listener, so co-resident add-ons export
// their own telemetry through the durable edge relay without per-add-on
// configuration.
//
// Injection keys off the collector being CONFIGURED (present in the desired
// set), not its momentary health: a subprocess environment is immutable after
// spawn and all add-ons (including the collector) launch in the same Apply,
// so gating on health would leave siblings spawned during collector bring-up
// permanently unconfigured. The endpoint is a deterministic loopback address
// and OTLP exporters retry until the listener accepts, which yields the same
// effective "configured+healthy" behavior without restart churn.

package addon

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

const (
	// OtelCollectorAddonID is the add-on id of the edge OTLP collector
	// (addons/otel-collector/addon.yaml). It is both the source of the local
	// OTLP endpoint and the loop guard: the collector must never be told to
	// export its own telemetry to itself.
	OtelCollectorAddonID = "otel-collector"

	// envOtlpEndpoint/envOtlpProtocol are the standard OpenTelemetry SDK
	// exporter variables injected into spawned add-on processes.
	envOtlpEndpoint = "OTEL_EXPORTER_OTLP_ENDPOINT"
	envOtlpProtocol = "OTEL_EXPORTER_OTLP_PROTOCOL"

	// envTelemetryDisabled is the documented ServiceRadar telemetry opt-out
	// (TELEMETRY.md): when set to 1/true in the agent's environment, no
	// self-telemetry endpoint is injected into add-on processes.
	envTelemetryDisabled = "SERVICERADAR_TELEMETRY_DISABLED"

	// defaultOtlpGrpcPort matches server.port's default in
	// addons/otel-collector/config.schema.json.
	defaultOtlpGrpcPort = 4317
)

// TelemetryDisabledFromEnv reports whether SERVICERADAR_TELEMETRY_DISABLED
// opts this process out of self-telemetry. Shared with the agent's own
// logger wiring so the opt-out covers the agent and its add-ons alike.
func TelemetryDisabledFromEnv() bool {
	return telemetryOptedOut(os.Getenv(envTelemetryDisabled))
}

// telemetryOptedOut reports whether an opt-out env value disables telemetry,
// accepting the same truthy spellings as the logger env helpers.
func telemetryOptedOut(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// localOtlpEndpointFromSpecs derives the loopback OTLP/gRPC endpoint from the
// otel-collector add-on's delivered configuration when the collector is part
// of the desired add-on set, or "" when it is not. The port comes from the
// collector config's server.port (default 4317); the host is always loopback
// because the collector runs co-resident with the agent.
func localOtlpEndpointFromSpecs(specs []Spec) string {
	for _, spec := range specs {
		if spec.ID != OtelCollectorAddonID {
			continue
		}

		return fmt.Sprintf("http://127.0.0.1:%d", otlpGrpcPortFromConfig(spec.ConfigJSON))
	}

	return ""
}

// otlpGrpcPortFromConfig extracts server.port from the otel-collector
// add-on's delivered config JSON (addons/otel-collector/config.schema.json).
// Absent, malformed, or out-of-range input falls back to the schema default
// so a bad config degrades to the conventional port instead of disabling
// self-telemetry.
func otlpGrpcPortFromConfig(configJSON []byte) int {
	if len(configJSON) == 0 {
		return defaultOtlpGrpcPort
	}

	var cfg struct {
		Server struct {
			Port *int `json:"port"`
		} `json:"server"`
	}

	if err := json.Unmarshal(configJSON, &cfg); err != nil {
		return defaultOtlpGrpcPort
	}

	if cfg.Server.Port == nil || *cfg.Server.Port <= 0 || *cfg.Server.Port > 65535 {
		return defaultOtlpGrpcPort
	}

	return *cfg.Server.Port
}

// addonProcessEnv builds the environment for a spawned add-on subprocess from
// the agent's own environment. It returns baseEnv unchanged when:
//
//   - localEndpoint is "" (no otel-collector add-on configured),
//   - the add-on IS the otel-collector itself (loop guard),
//   - SERVICERADAR_TELEMETRY_DISABLED opts out in baseEnv, or
//   - baseEnv already carries OTEL_EXPORTER_OTLP_ENDPOINT (an operator-set
//     endpoint on the agent process is explicit config and wins).
//
// Otherwise it appends OTEL_EXPORTER_OTLP_ENDPOINT=localEndpoint and
// OTEL_EXPORTER_OTLP_PROTOCOL=grpc to a copy of baseEnv.
func addonProcessEnv(baseEnv []string, addonID, localEndpoint string) []string {
	if localEndpoint == "" || addonID == OtelCollectorAddonID {
		return baseEnv
	}

	for _, kv := range baseEnv {
		key, value, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}

		switch key {
		case envTelemetryDisabled:
			if telemetryOptedOut(value) {
				return baseEnv
			}
		case envOtlpEndpoint:
			return baseEnv
		}
	}

	env := make([]string, 0, len(baseEnv)+2)
	env = append(env, baseEnv...)
	env = append(env,
		envOtlpEndpoint+"="+localEndpoint,
		envOtlpProtocol+"=grpc",
	)

	return env
}
