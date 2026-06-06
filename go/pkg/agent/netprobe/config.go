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
	Enabled             bool     `json:"enabled"`
	CaptureInterfaces   []string `json:"capture_interfaces,omitempty"`
	FlowTableMaxEntries uint32   `json:"flow_table_max_entries,omitempty"`
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
			Dpi:                     parseDPIConfig(cfg.GetDpi()),
			DefaultSampleIntervalMs: cfg.GetDefaultSampleIntervalMs(),
			FlowTableMaxEntries:     cfg.GetFlowTableMaxEntries(),
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
		payload.FlowTableMaxEntries = cfg.GetFlowTableMaxEntries()
	}

	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal netprobe bootstrap config: %w", err)
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return fmt.Errorf("create netprobe config dir: %w", err)
	}
	if err := writeFileAtomic(path, data, 0o640); err != nil {
		return fmt.Errorf("write netprobe bootstrap config: %w", err)
	}

	return nil
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}

	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()

	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	cleanup = false

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
			Dpi:              parseDPIConfig(binding.GetDpi()),
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

func parseDPIConfig(cfg *monitoringpb.VisibilityDpiConfig) *netprobepb.DpiConfig {
	if cfg == nil {
		return nil
	}

	return &netprobepb.DpiConfig{
		Enabled:   cfg.GetEnabled(),
		Protocols: trimStrings(cfg.GetProtocols()),
	}
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
