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

package netprobe

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	monitoringpb "github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

// ParsedVisibilityConfig is the agent-local view of monitoring.VisibilityConfig.
type ParsedVisibilityConfig struct {
	NetprobeConfig     *netprobepb.VisibilityAgentConfig
	BinaryOverridePath string
}

type bootstrapConfig struct {
	Enabled           bool     `json:"enabled"`
	CaptureInterfaces []string `json:"capture_interfaces"`
}

// ParseVisibilityConfig converts monitoring visibility config into netprobe IPC config.
func ParseVisibilityConfig(cfg *monitoringpb.VisibilityConfig) ParsedVisibilityConfig {
	if cfg == nil {
		return ParsedVisibilityConfig{
			NetprobeConfig: &netprobepb.VisibilityAgentConfig{},
		}
	}

	parsed := ParsedVisibilityConfig{
		NetprobeConfig: &netprobepb.VisibilityAgentConfig{
			Enabled:                 cfg.GetEnabled(),
			CaptureInterfaces:       trimStrings(cfg.GetCaptureInterfaces()),
			DefaultSampleIntervalMs: cfg.GetDefaultSampleIntervalMs(),
			DeviceBindings:          parseDeviceBindings(cfg.GetDeviceBindings()),
		},
		BinaryOverridePath: strings.TrimSpace(cfg.GetBinaryOverrides().GetPath()),
	}

	return parsed
}

func WriteBootstrapConfig(path string, cfg *netprobepb.VisibilityAgentConfig) error {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}

	payload := bootstrapConfig{}
	if cfg != nil {
		payload.Enabled = cfg.GetEnabled()
		payload.CaptureInterfaces = trimStrings(cfg.GetCaptureInterfaces())
	}

	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal netprobe bootstrap config: %w", err)
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return fmt.Errorf("create netprobe config dir: %w", err)
	}
	if err := os.WriteFile(path, data, 0o640); err != nil {
		return fmt.Errorf("write netprobe bootstrap config: %w", err)
	}

	return nil
}

func parseDeviceBindings(bindings []*monitoringpb.VisibilityDeviceBinding) []*netprobepb.DeviceBinding {
	if len(bindings) == 0 {
		return nil
	}

	parsed := make([]*netprobepb.DeviceBinding, 0, len(bindings))
	for _, binding := range bindings {
		if binding == nil {
			continue
		}
		parsed = append(parsed, &netprobepb.DeviceBinding{
			Ip:               strings.TrimSpace(binding.GetIp()),
			ProfileId:        strings.TrimSpace(binding.GetProfileId()),
			ProfileName:      strings.TrimSpace(binding.GetProfileName()),
			Fingerprint:      parseFingerprintConfig(binding.GetFingerprint()),
			SampleIntervalMs: binding.GetSampleIntervalMs(),
		})
	}

	return parsed
}

func parseFingerprintConfig(cfg *monitoringpb.VisibilityFingerprintConfig) *netprobepb.FingerprintConfig {
	if cfg == nil {
		return nil
	}

	return &netprobepb.FingerprintConfig{
		Tcp:  cfg.GetTcp(),
		Tls:  cfg.GetTls(),
		Http: cfg.GetHttp(),
	}
}

func compactStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	compacted := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			compacted = append(compacted, value)
		}
	}

	return compacted
}

func trimStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	trimmed := make([]string, 0, len(values))
	for _, value := range values {
		trimmed = append(trimmed, strings.TrimSpace(value))
	}

	return trimmed
}
