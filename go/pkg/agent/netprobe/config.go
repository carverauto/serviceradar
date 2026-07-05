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
	"strconv"
	"strings"

	monitoringpb "github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	gproto "google.golang.org/protobuf/proto"
)

// ParsedVisibilityConfig is the agent-local view of monitoring.VisibilityConfig.
type ParsedVisibilityConfig struct {
	NetprobeConfig     *netprobepb.VisibilityAgentConfig
	BinaryOverridePath string
}

type bootstrapConfig struct {
	Enabled                      bool     `json:"enabled"`
	CaptureInterfaces            []string `json:"capture_interfaces,omitempty"`
	FlowTableMaxEntries          uint32   `json:"flow_table_max_entries,omitempty"`
	ProcessSnapshotIntervalS     uint32   `json:"process_snapshot_interval_s,omitempty"`
	ExternalFlowMatchWindowMs    uint32   `json:"external_flow_match_window_ms,omitempty"`
	FlowAttributionIpcBatch      bool     `json:"flow_attribution_ipc_batch"`
	EmitRawFlowAttributionEvents bool     `json:"emit_raw_flow_attribution_events"`
}

type addonConfig struct {
	Enabled                      optionalBool         `json:"enabled"`
	CaptureInterfaces            captureInterfaceList `json:"capture_interfaces"`
	DefaultSampleIntervalMs      optionalUint32       `json:"default_sample_interval_ms"`
	FlowTableMaxEntries          optionalUint32       `json:"flow_table_max_entries"`
	ProcessSnapshotIntervalS     optionalUint32       `json:"process_snapshot_interval_s"`
	ExternalFlowMatchWindowMs    optionalUint32       `json:"external_flow_match_window_ms"`
	FlowAttributionIpcBatch      optionalBool         `json:"flow_attribution_ipc_batch"`
	EmitRawFlowAttributionEvents optionalBool         `json:"emit_raw_flow_attribution_events"`
}

type captureInterfaceList []string

type optionalBool struct {
	set   bool
	value bool
}

type optionalUint32 struct {
	set   bool
	value uint32
}

func defaultVisibilityAgentConfig() *netprobepb.VisibilityAgentConfig {
	return &netprobepb.VisibilityAgentConfig{
		FlowAttributionIpcBatch:      true,
		EmitRawFlowAttributionEvents: true,
	}
}

// ParseVisibilityConfig converts monitoring visibility config into netprobe IPC config.
func ParseVisibilityConfig(cfg *monitoringpb.VisibilityConfig) ParsedVisibilityConfig {
	if cfg == nil {
		return ParsedVisibilityConfig{
			NetprobeConfig: defaultVisibilityAgentConfig(),
		}
	}

	parsed := ParsedVisibilityConfig{
		NetprobeConfig: &netprobepb.VisibilityAgentConfig{
			Enabled:                      cfg.GetEnabled(),
			CaptureInterfaces:            trimStrings(cfg.GetCaptureInterfaces()),
			Dpi:                          parseDPIConfig(cfg.GetDpi()),
			DefaultSampleIntervalMs:      cfg.GetDefaultSampleIntervalMs(),
			FlowTableMaxEntries:          cfg.GetFlowTableMaxEntries(),
			FlowAttributionIpcBatch:      true,
			EmitRawFlowAttributionEvents: true,
			DeviceBindings:               parseDeviceBindings(cfg.GetDeviceBindings()),
		},
		BinaryOverridePath: strings.TrimSpace(cfg.GetBinaryOverrides().GetPath()),
	}

	return parsed
}

func ApplyAddonConfigJSON(
	cfg *netprobepb.VisibilityAgentConfig,
	configJSON []byte,
) (*netprobepb.VisibilityAgentConfig, error) {
	if cfg == nil {
		cfg = defaultVisibilityAgentConfig()
	}
	if len(strings.TrimSpace(string(configJSON))) == 0 {
		return cfg, nil
	}

	var addon addonConfig
	if err := json.Unmarshal(configJSON, &addon); err != nil {
		return nil, fmt.Errorf("parse netprobe add-on config: %w", err)
	}

	merged := cloneVisibilityConfig(cfg)
	if addon.Enabled.set {
		merged.Enabled = addon.Enabled.value
	}
	if addon.CaptureInterfaces != nil {
		merged.CaptureInterfaces = trimStrings([]string(addon.CaptureInterfaces))
	}
	if addon.DefaultSampleIntervalMs.set {
		merged.DefaultSampleIntervalMs = addon.DefaultSampleIntervalMs.value
	}
	if addon.FlowTableMaxEntries.set {
		merged.FlowTableMaxEntries = addon.FlowTableMaxEntries.value
	}
	if addon.ProcessSnapshotIntervalS.set {
		merged.ProcessSnapshotIntervalS = addon.ProcessSnapshotIntervalS.value
	}
	if addon.ExternalFlowMatchWindowMs.set {
		merged.ExternalFlowMatchWindowMs = addon.ExternalFlowMatchWindowMs.value
	}
	if addon.FlowAttributionIpcBatch.set {
		merged.FlowAttributionIpcBatch = addon.FlowAttributionIpcBatch.value
	}
	if addon.EmitRawFlowAttributionEvents.set {
		merged.EmitRawFlowAttributionEvents = addon.EmitRawFlowAttributionEvents.value
	}

	return merged, nil
}

func (b *optionalBool) UnmarshalJSON(data []byte) error {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" || trimmed == "null" {
		*b = optionalBool{}
		return nil
	}

	var value bool
	if err := json.Unmarshal(data, &value); err == nil {
		*b = optionalBool{set: true, value: value}
		return nil
	}

	var raw string
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		*b = optionalBool{}
		return nil
	}

	parsed, err := strconv.ParseBool(raw)
	if err != nil {
		return err
	}
	*b = optionalBool{set: true, value: parsed}
	return nil
}

func (u *optionalUint32) UnmarshalJSON(data []byte) error {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" || trimmed == "null" {
		*u = optionalUint32{}
		return nil
	}

	var value uint32
	if err := json.Unmarshal(data, &value); err == nil {
		*u = optionalUint32{set: true, value: value}
		return nil
	}

	var raw string
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		*u = optionalUint32{}
		return nil
	}

	parsed, err := strconv.ParseUint(raw, 10, 32)
	if err != nil {
		return err
	}
	*u = optionalUint32{set: true, value: uint32(parsed)}
	return nil
}

func (l *captureInterfaceList) UnmarshalJSON(data []byte) error {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" || trimmed == "null" {
		*l = nil
		return nil
	}

	var values []string
	if err := json.Unmarshal(data, &values); err == nil {
		*l = captureInterfaceList(values)
		return nil
	}

	var single string
	if err := json.Unmarshal(data, &single); err != nil {
		return err
	}

	values = strings.FieldsFunc(single, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r'
	})
	*l = captureInterfaceList(values)
	return nil
}

func WriteBootstrapConfig(path string, cfg *netprobepb.VisibilityAgentConfig) error {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}

	payload := bootstrapConfig{
		FlowAttributionIpcBatch:      true,
		EmitRawFlowAttributionEvents: true,
	}
	if cfg != nil {
		payload.Enabled = cfg.GetEnabled()
		payload.CaptureInterfaces = trimStrings(cfg.GetCaptureInterfaces())
		payload.FlowTableMaxEntries = cfg.GetFlowTableMaxEntries()
		payload.ProcessSnapshotIntervalS = cfg.GetProcessSnapshotIntervalS()
		payload.ExternalFlowMatchWindowMs = cfg.GetExternalFlowMatchWindowMs()
		payload.FlowAttributionIpcBatch = cfg.GetFlowAttributionIpcBatch()
		payload.EmitRawFlowAttributionEvents = cfg.GetEmitRawFlowAttributionEvents()
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

func cloneVisibilityConfig(cfg *netprobepb.VisibilityAgentConfig) *netprobepb.VisibilityAgentConfig {
	return gproto.Clone(cfg).(*netprobepb.VisibilityAgentConfig)
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
