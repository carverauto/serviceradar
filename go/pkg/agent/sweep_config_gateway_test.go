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
	"encoding/binary"
	"encoding/json"
	"net/netip"
	"slices"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/rs/zerolog"
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

// The range tests below use documentation addresses only (RFC 5737, RFC 3849);
// IPv6 ones are built from integers.

// doc6 returns the IPv6 documentation address whose low 64 bits are low.
func doc6(low uint64) netip.Addr {
	var b [16]byte
	b[0], b[1], b[2], b[3] = 0x20, 0x01, 0x0d, 0xb8
	binary.BigEndian.PutUint64(b[8:], low)

	return netip.AddrFrom16(b)
}

func doc6Prefix(low uint64, bits int) string {
	return netip.PrefixFrom(doc6(low), bits).String()
}

func doc6Range(first, last uint64) string {
	return doc6(first).String() + "-" + doc6(last).String()
}

// mapped4 writes an IPv4 address in its IPv4-mapped IPv6 form.
func mapped4(ipv4 string) string {
	return netip.AddrFrom16(netip.MustParseAddr(ipv4).As16()).String()
}

// sweptAddresses returns, in order, the addresses the sweeper probes for
// networks, using the CIDR expansion the sweeper applies.
func sweptAddresses(t *testing.T, networks []string) []string {
	t.Helper()

	var swept []string
	for _, network := range networks {
		ips, err := scan.ExpandCIDR(network)
		if err != nil {
			t.Fatalf("expand %q: %v", network, err)
		}

		swept = append(swept, ips...)
	}

	return swept
}

// addressesThrough returns every address from first through last.
func addressesThrough(first, last netip.Addr) []string {
	var addresses []string
	for addr := first; ; addr = addr.Next() {
		addresses = append(addresses, addr.String())
		if addr == last {
			return addresses
		}
	}
}

// warnErrorsByField returns the error text of every warn-level log line,
// keyed by the value of field.
func warnErrorsByField(t *testing.T, logs, field string) map[string][]string {
	t.Helper()

	found := make(map[string][]string)
	for _, line := range strings.Split(strings.TrimSpace(logs), "\n") {
		var entry map[string]any
		if json.Unmarshal([]byte(line), &entry) != nil || entry["level"] != "warn" {
			continue
		}

		value, _ := entry[field].(string)
		errText, _ := entry["error"].(string)
		found[value] = append(found[value], errText)
	}

	return found
}

// A first-last range reaches the sweeper as CIDR entries that expand to
// exactly its addresses, both ends included. The sweeper skips the first and
// last address of an IPv4 CIDR other than /32, so each IPv4 block of a range
// also carries its two ends as /32 entries.
func TestNormalizeTargets_ConvertsRangesToSweepNetworks(t *testing.T) {
	tests := []struct {
		name        string
		target      string
		want        []string
		first, last netip.Addr
	}{
		{
			name:   "non-aligned IPv4 range",
			target: "198.51.100.10-198.51.100.50",
			want: []string{
				"198.51.100.10/32", "198.51.100.11/32",
				"198.51.100.12/32", "198.51.100.12/30", "198.51.100.15/32",
				"198.51.100.16/32", "198.51.100.16/28", "198.51.100.31/32",
				"198.51.100.32/32", "198.51.100.32/28", "198.51.100.47/32",
				"198.51.100.48/32", "198.51.100.49/32",
				"198.51.100.50/32",
			},
			first: netip.MustParseAddr("198.51.100.10"),
			last:  netip.MustParseAddr("198.51.100.50"),
		},
		{
			name:   "IPv4 range spanning one whole block keeps both ends",
			target: "192.0.2.0-192.0.2.255",
			want:   []string{"192.0.2.0/32", "192.0.2.0/24", "192.0.2.255/32"},
			first:  netip.MustParseAddr("192.0.2.0"),
			last:   netip.MustParseAddr("192.0.2.255"),
		},
		{
			name:   "single-address IPv4 range",
			target: "203.0.113.7-203.0.113.7",
			want:   []string{"203.0.113.7/32"},
			first:  netip.MustParseAddr("203.0.113.7"),
			last:   netip.MustParseAddr("203.0.113.7"),
		},
		{
			name:   "whitespace around the dash",
			target: "  203.0.113.1 -\t203.0.113.2 ",
			want:   []string{"203.0.113.1/32", "203.0.113.2/32"},
			first:  netip.MustParseAddr("203.0.113.1"),
			last:   netip.MustParseAddr("203.0.113.2"),
		},
		{
			name:   "IPv4-mapped bounds sweep as IPv4, as a single mapped IP does",
			target: mapped4("192.0.2.1") + "-" + mapped4("192.0.2.2"),
			want:   []string{"192.0.2.1/32", "192.0.2.2/32"},
			first:  netip.MustParseAddr("192.0.2.1"),
			last:   netip.MustParseAddr("192.0.2.2"),
		},
		{
			name:   "non-aligned IPv6 range",
			target: doc6Range(0x1, 0x10),
			want: []string{
				doc6Prefix(0x1, 128), doc6Prefix(0x2, 127), doc6Prefix(0x4, 126),
				doc6Prefix(0x8, 125), doc6Prefix(0x10, 128),
			},
			first: doc6(0x1),
			last:  doc6(0x10),
		},
		{
			name:   "IPv6 range at the sweeper's 100,000-address expansion limit",
			target: doc6Range(0x0, 0x1869f),
			want: []string{
				doc6Prefix(0x0, 112), doc6Prefix(0x10000, 113), doc6Prefix(0x18000, 118),
				doc6Prefix(0x18400, 119), doc6Prefix(0x18600, 121), doc6Prefix(0x18680, 123),
			},
			first: doc6(0x0),
			last:  doc6(0x1869f),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeTargets([]string{tt.target}, logger.NewTestLogger())
			if !slices.Equal(got, tt.want) {
				t.Fatalf("normalizeTargets(%q) = %q, want %q", tt.target, got, tt.want)
			}

			if swept, want := sweptAddresses(t, got), addressesThrough(tt.first, tt.last); !slices.Equal(swept, want) {
				t.Fatalf("sweep of %q covers %d addresses, want exactly the %d from %s to %s",
					tt.target, len(swept), len(want), tt.first, tt.last)
			}
		})
	}
}

// An unusable range is dropped with one warning that names it and says why;
// the entries around it still sweep.
func TestNormalizeTargets_DropsInvalidRangesWithOneWarning(t *testing.T) {
	invalid := []string{
		"192.0.2.9-192.0.2.1",                              // first after last
		"192.0.2.1-" + doc6(0x1).String(),                  // mixed address families
		"192.0.2.1-192.0.2.x",                              // unparseable end
		"-192.0.2.1",                                       // missing first
		"192.0.2.1-",                                       // missing last
		"192.0.2.1-192.0.2.5-192.0.2.9",                    // more than one dash
		doc6(0x1).String() + "%eth0-" + doc6(0x2).String(), // zoned bound
		doc6Range(0x0, 0x186a0),                            // 100,001 addresses, above the sweeper's IPv6 limit
	}

	out := &syncBuffer{}
	log := &recordingLogger{Logger: zerolog.New(out)}

	got := normalizeTargets(append([]string{"198.51.100.7"}, invalid...), log)
	if want := []string{"198.51.100.7/32"}; !slices.Equal(got, want) {
		t.Fatalf("normalizeTargets kept %q, want only %q", got, want)
	}

	warnings := warnErrorsByField(t, out.String(), "target")
	for _, entry := range invalid {
		if errs := warnings[entry]; len(errs) != 1 || errs[0] == "" {
			t.Errorf("want one warning naming %q with the reason, got errors %q", entry, errs)
		}
	}

	if t.Failed() {
		t.Logf("logs:\n%s", out.String())
	}
}

// Single IPs and CIDRs normalize as they did before ranges were accepted.
func TestNormalizeTargets_KeepsSingleIPAndCIDRHandling(t *testing.T) {
	got := normalizeTargets([]string{
		" 192.0.2.10 ",
		"198.51.100.0/24",
		"198.51.100.5/24", // host bits set: passed through, the sweeper masks it
		doc6(0x5).String(),
		doc6Prefix(0x0, 120),
		mapped4("203.0.113.1"),
		"192.0.2.0/33",
		"192.0.2.256",
	}, logger.NewTestLogger())

	want := []string{
		"192.0.2.10/32",
		"198.51.100.0/24",
		"198.51.100.5/24",
		doc6Prefix(0x5, 128),
		doc6Prefix(0x0, 120),
		"203.0.113.1/32",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("normalizeTargets = %q, want %q", got, want)
	}
}

// A device target written as a range becomes one device target per sweep
// network, each keeping the device's modes and labels.
func TestConvertDeviceTargets_SplitsRanges(t *testing.T) {
	converted := convertDeviceTargets([]gatewayDeviceTarget{
		{
			Network:    "203.0.113.4-203.0.113.5",
			SweepModes: []string{"icmp"},
			QueryLabel: "in:devices",
			Source:     "netbox",
			Metadata:   map[string]string{"device_uid": "sr:range-device"},
		},
		{Network: "203.0.113.9", SweepModes: []string{"tcp"}},
	}, logger.NewTestLogger())

	networks := make([]string, 0, len(converted))
	for _, target := range converted {
		networks = append(networks, target.Network)
	}

	if want := []string{"203.0.113.4/32", "203.0.113.5/32", "203.0.113.9/32"}; !slices.Equal(networks, want) {
		t.Fatalf("device target networks = %q, want %q", networks, want)
	}

	for _, target := range converted[:2] {
		if !slices.Equal(target.SweepModes, []models.SweepMode{models.ModeICMP}) ||
			target.QueryLabel != "in:devices" || target.Source != "netbox" ||
			target.Metadata["device_uid"] != "sr:range-device" {
			t.Errorf("split device target %s lost its modes or labels: %+v", target.Network, target)
		}
	}
}

func TestParseGatewaySweepConfig_ConvertsRangeTargets(t *testing.T) {
	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "range-group",
				"targets": ["192.0.2.1-192.0.2.3", "198.51.100.0/24"],
				"ports": [22],
				"modes": ["tcp"],
				"schedule": {"type": "interval", "interval": "5m"}
			}],
			"config_hash": "range-hash"
		}
	}`)

	config, err := parseGatewaySweepConfig(configJSON, logger.NewTestLogger())
	if err != nil {
		t.Fatalf("parseGatewaySweepConfig failed: %v", err)
	}

	if len(config.Groups) != 1 {
		t.Fatalf("expected 1 group, got %d", len(config.Groups))
	}

	want := []string{"192.0.2.1/32", "192.0.2.2/32", "192.0.2.3/32", "198.51.100.0/24"}
	if got := config.Groups[0].Networks; !slices.Equal(got, want) {
		t.Fatalf("group networks = %q, want %q", got, want)
	}
}

// Targets that do not come through the gateway payload -- the sweep.json file
// and a models.Config passed to UpdateConfig -- reach the sweeper through
// buildSweepModelConfigFromGroup, which normalizes them the same way.
func TestBuildSweepModelConfigFromGroup_NormalizesTargets(t *testing.T) {
	out := &syncBuffer{}
	log := &recordingLogger{Logger: zerolog.New(out)}

	group := sweepGroupConfigFromSweepConfig(&SweepConfig{
		Networks: []string{"192.0.2.1-192.0.2.2", "198.51.100.0/24", "192.0.2.9", "192.0.2.9-192.0.2.1"},
		DeviceTargets: []models.DeviceTarget{
			{Network: "203.0.113.4-203.0.113.5", QueryLabel: "in:devices"},
			{Network: "203.0.113.9"},
		},
	})

	modelConfig, err := buildSweepModelConfigFromGroup(&ServerConfig{AgentID: "agent-1"}, group, log)
	if err != nil {
		t.Fatalf("buildSweepModelConfigFromGroup failed: %v", err)
	}

	if want := []string{"192.0.2.1/32", "192.0.2.2/32", "198.51.100.0/24", "192.0.2.9/32"}; !slices.Equal(modelConfig.Networks, want) {
		t.Fatalf("networks = %q, want %q", modelConfig.Networks, want)
	}

	deviceNetworks := make([]string, 0, len(modelConfig.DeviceTargets))
	for _, target := range modelConfig.DeviceTargets {
		deviceNetworks = append(deviceNetworks, target.Network)
	}

	if want := []string{"203.0.113.4/32", "203.0.113.5/32", "203.0.113.9/32"}; !slices.Equal(deviceNetworks, want) {
		t.Fatalf("device target networks = %q, want %q", deviceNetworks, want)
	}

	if errs := warnErrorsByField(t, out.String(), "target")["192.0.2.9-192.0.2.1"]; len(errs) != 1 {
		t.Fatalf("want one warning naming the reversed range, got %d\nlogs:\n%s", len(errs), out.String())
	}
}

// A gateway target is normalized when the payload is parsed and again when
// its group is built; an invalid entry is still reported once.
func TestGatewayTargets_InvalidRangeWarnsOnceAcrossParseAndBuild(t *testing.T) {
	out := &syncBuffer{}
	log := &recordingLogger{Logger: zerolog.New(out)}

	configJSON := []byte(`{
		"sweep": {
			"groups": [{
				"id": "range-group",
				"targets": ["192.0.2.1-192.0.2.2", "192.0.2.9-192.0.2.1"],
				"schedule": {"type": "interval", "interval": "5m"}
			}]
		}
	}`)

	config, err := parseGatewaySweepConfig(configJSON, log)
	if err != nil {
		t.Fatalf("parseGatewaySweepConfig failed: %v", err)
	}

	modelConfig, err := buildSweepModelConfigFromGroup(&ServerConfig{AgentID: "agent-1"}, config.Groups[0], log)
	if err != nil {
		t.Fatalf("buildSweepModelConfigFromGroup failed: %v", err)
	}

	if want := []string{"192.0.2.1/32", "192.0.2.2/32"}; !slices.Equal(modelConfig.Networks, want) {
		t.Fatalf("networks = %q, want %q", modelConfig.Networks, want)
	}

	if errs := warnErrorsByField(t, out.String(), "target")["192.0.2.9-192.0.2.1"]; len(errs) != 1 {
		t.Fatalf("want one warning naming the reversed range, got %d\nlogs:\n%s", len(errs), out.String())
	}
}
