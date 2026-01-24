/*
 * Copyright 2025 Carver Automation Corporation.
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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestParseGatewaySweepConfig_WithDeviceTargets(t *testing.T) {
	log := logger.NewTestLogger()

	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "test-group",
				"sweep_group_id": "sweep-123",
				"targets": ["10.0.0.0/24"],
				"ports": [80, 443, 8080],
				"modes": ["icmp", "tcp"],
				"device_targets": [
					{
						"network": "192.168.1.10",
						"sweep_modes": ["tcp", "icmp"],
						"query_label": "in:devices",
						"source": "armis",
						"metadata": {"device_type": "server"}
					},
					{
						"network": "192.168.1.20/32",
						"sweep_modes": ["icmp"],
						"query_label": "in:devices"
					}
				],
				"schedule": {
					"type": "interval",
					"interval": "5m"
				},
				"settings": {
					"concurrency": 10,
					"timeout": "30s"
				}
			}],
			"config_hash": "abc123"
		}
	}`)

	config, err := parseGatewaySweepConfig(configJSON, log)
	if err != nil {
		t.Fatalf("parseGatewaySweepConfig failed: %v", err)
	}

	if config == nil {
		t.Fatal("expected config, got nil")
	}

	// Verify basic config fields
	if len(config.Networks) != 1 {
		t.Errorf("expected 1 network, got %d", len(config.Networks))
	}

	if len(config.Ports) != 3 {
		t.Errorf("expected 3 ports, got %d", len(config.Ports))
	}

	if len(config.SweepModes) != 2 {
		t.Errorf("expected 2 sweep modes, got %d", len(config.SweepModes))
	}

	// Verify device targets are parsed
	if len(config.DeviceTargets) != 2 {
		t.Fatalf("expected 2 device targets, got %d", len(config.DeviceTargets))
	}

	// Verify first device target
	dt1 := config.DeviceTargets[0]
	if dt1.Network != "192.168.1.10/32" {
		t.Errorf("expected network '192.168.1.10/32', got '%s'", dt1.Network)
	}
	if len(dt1.SweepModes) != 2 {
		t.Errorf("expected 2 sweep modes for device target 1, got %d", len(dt1.SweepModes))
	}
	if dt1.QueryLabel != "in:devices" {
		t.Errorf("expected query_label 'in:devices', got '%s'", dt1.QueryLabel)
	}
	if dt1.Source != "armis" {
		t.Errorf("expected source 'armis', got '%s'", dt1.Source)
	}
	if dt1.Metadata["device_type"] != "server" {
		t.Errorf("expected metadata device_type 'server', got '%s'", dt1.Metadata["device_type"])
	}

	// Verify second device target (already has /32)
	dt2 := config.DeviceTargets[1]
	if dt2.Network != "192.168.1.20/32" {
		t.Errorf("expected network '192.168.1.20/32', got '%s'", dt2.Network)
	}
	if len(dt2.SweepModes) != 1 {
		t.Errorf("expected 1 sweep mode for device target 2, got %d", len(dt2.SweepModes))
	}
	if dt2.SweepModes[0] != models.ModeICMP {
		t.Errorf("expected sweep mode ICMP, got %s", dt2.SweepModes[0])
	}

	// Verify config hash
	if config.ConfigHash != "abc123" {
		t.Errorf("expected config_hash 'abc123', got '%s'", config.ConfigHash)
	}
}

func TestParseGatewaySweepConfig_NoDeviceTargets(t *testing.T) {
	log := logger.NewTestLogger()

	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "test-group",
				"targets": ["10.0.0.0/24"],
				"ports": [80],
				"modes": ["icmp"],
				"schedule": {
					"type": "interval",
					"interval": "5m"
				},
				"settings": {
					"concurrency": 5
				}
			}]
		}
	}`)

	config, err := parseGatewaySweepConfig(configJSON, log)
	if err != nil {
		t.Fatalf("parseGatewaySweepConfig failed: %v", err)
	}

	if config == nil {
		t.Fatal("expected config, got nil")
	}

	// DeviceTargets should be nil/empty when not provided
	if len(config.DeviceTargets) != 0 {
		t.Errorf("expected 0 device targets, got %d", len(config.DeviceTargets))
	}
}

func TestParseGatewaySweepConfig_EmptyPayload(t *testing.T) {
	log := logger.NewTestLogger()

	config, err := parseGatewaySweepConfig([]byte{}, log)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if config != nil {
		t.Error("expected nil config for empty payload")
	}
}

func TestConvertDeviceTargets_NormalizesIPsToCIDR(t *testing.T) {
	log := logger.NewTestLogger()

	targets := []gatewayDeviceTarget{
		{Network: "10.0.0.1", SweepModes: []string{"tcp"}},
		{Network: "10.0.0.2/32", SweepModes: []string{"icmp"}},
		{Network: "invalid", SweepModes: []string{"tcp"}},
		{Network: "", SweepModes: []string{"tcp"}},
	}

	converted := convertDeviceTargets(targets, log)

	// Should have 2 valid targets (invalid and empty should be skipped)
	if len(converted) != 2 {
		t.Fatalf("expected 2 converted targets, got %d", len(converted))
	}

	// First target should be normalized to /32
	if converted[0].Network != "10.0.0.1/32" {
		t.Errorf("expected '10.0.0.1/32', got '%s'", converted[0].Network)
	}

	// Second target should remain as-is
	if converted[1].Network != "10.0.0.2/32" {
		t.Errorf("expected '10.0.0.2/32', got '%s'", converted[1].Network)
	}
}
