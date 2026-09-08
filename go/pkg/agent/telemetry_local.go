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

package agent

import (
	"strings"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// ApplyLocalOtlpLoggerEndpoint wires the agent's own telemetry to a
// co-resident OTLP collector (refactor-otel-signal-correlation 10.5) with
// "auto" semantics:
//
//   - explicit config wins: a non-empty logging.otel.endpoint is never
//     touched;
//   - local endpoint used when present: when the OTel block is enabled with
//     an empty endpoint (previously a hard error), the local collector
//     endpoint fills it in;
//   - else unchanged: a disabled OTel block stays disabled — the helper
//     never turns telemetry on by itself.
//
// localEndpoint follows the OTEL_EXPORTER_OTLP_ENDPOINT URL convention
// ("http://127.0.0.1:4317"); the logger's otlploggrpc exporter wants
// host:port, so the scheme is stripped and a plain-http endpoint marks the
// connection insecure (loopback plaintext). SERVICERADAR_TELEMETRY_DISABLED
// opts the agent out, matching the env injected into add-on subprocesses.
func ApplyLocalOtlpLoggerEndpoint(logCfg *logger.Config, localEndpoint string) {
	localEndpoint = strings.TrimSpace(localEndpoint)
	if logCfg == nil || localEndpoint == "" {
		return
	}

	if agentaddon.TelemetryDisabledFromEnv() {
		return
	}

	if !logCfg.OTel.Enabled {
		return // unchanged: operator did not enable OTel logging
	}

	if strings.TrimSpace(logCfg.OTel.Endpoint) != "" {
		return // explicit config wins
	}

	endpoint := localEndpoint
	insecure := true

	switch {
	case strings.HasPrefix(localEndpoint, "https://"):
		endpoint = strings.TrimPrefix(localEndpoint, "https://")
		insecure = false
	case strings.HasPrefix(localEndpoint, "http://"):
		endpoint = strings.TrimPrefix(localEndpoint, "http://")
	}

	logCfg.OTel.Endpoint = endpoint
	logCfg.OTel.Insecure = insecure
}
