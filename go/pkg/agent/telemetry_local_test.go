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
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestApplyLocalOtlpLoggerEndpointAutoFill(t *testing.T) {
	cfg := &logger.Config{OTel: logger.OTelConfig{Enabled: true}}

	ApplyLocalOtlpLoggerEndpoint(cfg, "http://127.0.0.1:4317")

	if cfg.OTel.Endpoint != "127.0.0.1:4317" {
		t.Fatalf("Endpoint = %q, want 127.0.0.1:4317", cfg.OTel.Endpoint)
	}
	if !cfg.OTel.Insecure {
		t.Fatal("Insecure = false, want true for loopback plain-http endpoint")
	}
}

func TestApplyLocalOtlpLoggerEndpointExplicitConfigWins(t *testing.T) {
	cfg := &logger.Config{OTel: logger.OTelConfig{Enabled: true, Endpoint: "collector.example:4317"}}

	ApplyLocalOtlpLoggerEndpoint(cfg, "http://127.0.0.1:4317")

	if cfg.OTel.Endpoint != "collector.example:4317" {
		t.Fatalf("explicit endpoint overridden: %q", cfg.OTel.Endpoint)
	}
	if cfg.OTel.Insecure {
		t.Fatal("Insecure flipped despite explicit endpoint")
	}
}

func TestApplyLocalOtlpLoggerEndpointDisabledStaysUnchanged(t *testing.T) {
	cfg := &logger.Config{OTel: logger.OTelConfig{Enabled: false}}

	ApplyLocalOtlpLoggerEndpoint(cfg, "http://127.0.0.1:4317")

	if cfg.OTel.Enabled || cfg.OTel.Endpoint != "" {
		t.Fatalf("disabled OTel block changed: %+v", cfg.OTel)
	}
}

func TestApplyLocalOtlpLoggerEndpointNoLocalEndpoint(t *testing.T) {
	cfg := &logger.Config{OTel: logger.OTelConfig{Enabled: true}}

	ApplyLocalOtlpLoggerEndpoint(cfg, "  ")

	if cfg.OTel.Endpoint != "" {
		t.Fatalf("Endpoint = %q, want unchanged empty", cfg.OTel.Endpoint)
	}
}

func TestApplyLocalOtlpLoggerEndpointRespectsOptOut(t *testing.T) {
	t.Setenv("SERVICERADAR_TELEMETRY_DISABLED", "1")

	cfg := &logger.Config{OTel: logger.OTelConfig{Enabled: true}}

	ApplyLocalOtlpLoggerEndpoint(cfg, "http://127.0.0.1:4317")

	if cfg.OTel.Endpoint != "" {
		t.Fatalf("Endpoint = %q, want unchanged empty under opt-out", cfg.OTel.Endpoint)
	}
}

func TestApplyLocalOtlpLoggerEndpointHTTPSStaysSecure(t *testing.T) {
	cfg := &logger.Config{OTel: logger.OTelConfig{Enabled: true}}

	ApplyLocalOtlpLoggerEndpoint(cfg, "https://127.0.0.1:4317")

	if cfg.OTel.Endpoint != "127.0.0.1:4317" {
		t.Fatalf("Endpoint = %q, want 127.0.0.1:4317", cfg.OTel.Endpoint)
	}
	if cfg.OTel.Insecure {
		t.Fatal("Insecure = true for https endpoint, want false")
	}
}
