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

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
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
		return
	}

	// Verify basic config fields
	if len(config.Groups) != 1 {
		t.Fatalf("expected 1 group, got %d", len(config.Groups))
	}

	group := config.Groups[0]

	if len(group.Networks) != 1 {
		t.Errorf("expected 1 network, got %d", len(group.Networks))
	}

	if len(group.Ports) != 3 {
		t.Errorf("expected 3 ports, got %d", len(group.Ports))
	}

	if len(group.SweepModes) != 2 {
		t.Errorf("expected 2 sweep modes, got %d", len(group.SweepModes))
	}

	// Verify device targets are parsed
	if len(group.DeviceTargets) != 2 {
		t.Fatalf("expected 2 device targets, got %d", len(group.DeviceTargets))
	}

	// Verify first device target
	dt1 := group.DeviceTargets[0]
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
	dt2 := group.DeviceTargets[1]
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
		return
	}

	// DeviceTargets should be nil/empty when not provided
	if len(config.Groups) != 1 {
		t.Fatalf("expected 1 group, got %d", len(config.Groups))
	}

	if len(config.Groups[0].DeviceTargets) != 0 {
		t.Errorf("expected 0 device targets, got %d", len(config.Groups[0].DeviceTargets))
	}
}

func TestParseGatewaySweepConfig_DropsARPWithoutKeepingIt(t *testing.T) {
	log := logger.NewTestLogger()

	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "test-group",
				"targets": ["10.0.0.0/24"],
				"ports": [22, 80],
				"modes": ["icmp", "tcp", "arp"],
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

	if config == nil || len(config.Groups) != 1 {
		t.Fatalf("expected 1 group, got %#v", config)
	}

	got := config.Groups[0].SweepModes
	if len(got) != 2 {
		t.Fatalf("expected icmp+tcp after dropping arp, got %v", got)
	}

	if got[0] != models.ModeICMP || got[1] != models.ModeTCP {
		t.Fatalf("expected [icmp tcp], got %v", got)
	}
}

func TestParseGatewaySweepConfig_BannerGrab(t *testing.T) {
	log := logger.NewTestLogger()

	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "test-group",
				"targets": ["10.0.0.0/24"],
				"ports": [22],
				"modes": ["tcp"],
				"banner_grab": {
					"enabled": true,
					"protocols": ["ssh", "http", "invalid", "ssh"],
					"ports": {
						"ssh": [22, 22, 70000],
						"http": [80, 8080]
					},
					"connect_timeout_ms": 1500,
					"read_timeout_ms": 1200,
					"max_banner_bytes": 2048,
					"max_concurrency_per_host": 2,
					"max_global_concurrency": 128,
					"max_probe_rate_per_second": 1000,
					"max_candidate_queue": 4096,
					"match_batch_size": 128,
					"match_batch_max_bytes": 524288,
					"min_reprobe_interval_s": 3600,
					"per_host_rate_limit_ms": 50
				},
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
	if config == nil || len(config.Groups) != 1 {
		t.Fatalf("expected one group, got %#v", config)
	}

	bannerGrab := config.Groups[0].BannerGrab
	if !bannerGrab.Enabled {
		t.Fatal("expected banner grab to be enabled")
	}
	if got, want := bannerGrab.Protocols, []string{"ssh", "http"}; !equalStringSlices(got, want) {
		t.Fatalf("expected protocols %v, got %v", want, got)
	}
	if got, want := bannerGrab.Ports["ssh"], []int{22}; !equalIntSlices(got, want) {
		t.Fatalf("expected ssh ports %v, got %v", want, got)
	}
	if got, want := bannerGrab.Ports["http"], []int{80, 8080}; !equalIntSlices(got, want) {
		t.Fatalf("expected http ports %v, got %v", want, got)
	}

	assertBannerGrabValues(t, bannerGrab)
}

func TestParseGatewaySweepConfig_BannerGrabDefaultsWhenMissing(t *testing.T) {
	log := logger.NewTestLogger()

	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "test-group",
				"targets": ["10.0.0.0/24"],
				"ports": [22],
				"modes": ["tcp"],
				"schedule": {"type": "interval", "interval": "5m"},
				"settings": {"concurrency": 5}
			}]
		}
	}`)

	config, err := parseGatewaySweepConfig(configJSON, log)
	if err != nil {
		t.Fatalf("parseGatewaySweepConfig failed: %v", err)
	}
	if config == nil || len(config.Groups) != 1 {
		t.Fatalf("expected one group, got %#v", config)
	}

	bannerGrab := config.Groups[0].BannerGrab
	if bannerGrab.Enabled {
		t.Fatal("expected banner grab to default disabled")
	}
	if len(bannerGrab.Protocols) != 0 {
		t.Fatalf("expected no default protocols, got %v", bannerGrab.Protocols)
	}
	if len(bannerGrab.Ports) != 0 {
		t.Fatalf("expected no default ports, got %v", bannerGrab.Ports)
	}
	if got, want := bannerGrab.MinReprobeIntervalSec, 86400; got != want {
		t.Fatalf("expected min reprobe interval %d, got %d", want, got)
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

func assertBannerGrabValues(t *testing.T, bannerGrab BannerGrabConfig) {
	t.Helper()

	checks := map[string][2]int{
		"connect_timeout_ms":        {bannerGrab.ConnectTimeoutMS, 1500},
		"read_timeout_ms":           {bannerGrab.ReadTimeoutMS, 1200},
		"max_banner_bytes":          {bannerGrab.MaxBannerBytes, 2048},
		"max_concurrency_per_host":  {bannerGrab.MaxConcurrencyPerHost, 2},
		"max_global_concurrency":    {bannerGrab.MaxGlobalConcurrency, 128},
		"max_probe_rate_per_second": {bannerGrab.MaxProbeRatePerSecond, 1000},
		"max_candidate_queue":       {bannerGrab.MaxCandidateQueue, 4096},
		"match_batch_size":          {bannerGrab.MatchBatchSize, 128},
		"match_batch_max_bytes":     {bannerGrab.MatchBatchMaxBytes, 524288},
		"min_reprobe_interval_s":    {bannerGrab.MinReprobeIntervalSec, 3600},
		"per_host_rate_limit_ms":    {bannerGrab.PerHostRateLimitMillis, 50},
	}

	for field, check := range checks {
		if got, want := check[0], check[1]; got != want {
			t.Fatalf("expected %s=%d, got %d", field, want, got)
		}
	}
}

func equalStringSlices(left []string, right []string) bool {
	if len(left) != len(right) {
		return false
	}

	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}

	return true
}

func equalIntSlices(left []int, right []int) bool {
	if len(left) != len(right) {
		return false
	}

	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}

	return true
}

func TestParseGatewaySweepConfig_MultipleGroups(t *testing.T) {
	log := logger.NewTestLogger()

	configJSON := []byte(`{
		"sweep": {
			"groups": [
				{
					"id": "group-1",
					"targets": ["10.0.1.0/24"],
					"ports": [80],
					"modes": ["icmp"],
					"schedule": {
						"type": "interval",
						"interval": "1h"
					},
					"settings": {
						"concurrency": 10,
						"timeout": "5s"
					}
				},
				{
					"id": "group-2",
					"targets": ["10.0.2.0/24"],
					"ports": [443],
					"modes": ["tcp"],
					"schedule": {
						"type": "interval",
						"interval": "15m"
					},
					"settings": {
						"concurrency": 50,
						"timeout": "30s"
					}
				}
			],
			"config_hash": "merged-hash"
		}
	}`)

	config, err := parseGatewaySweepConfig(configJSON, log)
	if err != nil {
		t.Fatalf("parseGatewaySweepConfig failed: %v", err)
	}

	if len(config.Groups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(config.Groups))
	}

	if config.Groups[0].SweepGroupID != "group-1" {
		t.Errorf("expected sweep_group_id 'group-1', got '%s'", config.Groups[0].SweepGroupID)
	}

	if config.Groups[1].SweepGroupID != "group-2" {
		t.Errorf("expected sweep_group_id 'group-2', got '%s'", config.Groups[1].SweepGroupID)
	}

	if config.ConfigHash != "merged-hash" {
		t.Errorf("expected config_hash 'merged-hash', got '%s'", config.ConfigHash)
	}
}

func TestConvertDeviceTargets_NormalizesIPsToCIDR(t *testing.T) {
	log := logger.NewTestLogger()

	targets := []gatewayDeviceTarget{
		{Network: "10.0.0.1", SweepModes: []string{"tcp"}},
		{Network: "10.0.0.2/32", SweepModes: []string{"icmp"}},
		{Network: "2001:470::5:b19e", SweepModes: []string{"tcp"}},
		{Network: "invalid", SweepModes: []string{"tcp"}},
		{Network: "", SweepModes: []string{"tcp"}},
	}

	converted := convertDeviceTargets(targets, log)

	// Should have 3 valid targets (invalid and empty should be skipped)
	if len(converted) != 3 {
		t.Fatalf("expected 3 converted targets, got %d", len(converted))
	}

	// First target should be normalized to /32
	if converted[0].Network != "10.0.0.1/32" {
		t.Errorf("expected '10.0.0.1/32', got '%s'", converted[0].Network)
	}

	// Second target should remain as-is
	if converted[1].Network != "10.0.0.2/32" {
		t.Errorf("expected '10.0.0.2/32', got '%s'", converted[1].Network)
	}

	// IPv6 host targets should be normalized to /128, not the IPv4-only /32.
	if converted[2].Network != "2001:470::5:b19e/128" {
		t.Errorf("expected '2001:470::5:b19e/128', got '%s'", converted[2].Network)
	}
}

func TestNormalizeTargets_NormalizesIPv6HostsTo128(t *testing.T) {
	log := logger.NewTestLogger()

	targets := normalizeTargets([]string{
		"192.168.1.10",
		"192.168.1.0/24",
		"2001:470::5:b19e",
		"2001:470::5:b000/120",
		"not-an-ip",
	}, log)

	expected := []string{
		"192.168.1.10/32",
		"192.168.1.0/24",
		"2001:470::5:b19e/128",
		"2001:470::5:b000/120",
	}

	if len(targets) != len(expected) {
		t.Fatalf("expected %d targets, got %d: %#v", len(expected), len(targets), targets)
	}

	for i := range expected {
		if targets[i] != expected[i] {
			t.Fatalf("target %d = %q, expected %q", i, targets[i], expected[i])
		}
	}
}
