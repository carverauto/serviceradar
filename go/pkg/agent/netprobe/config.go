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
	gproto "google.golang.org/protobuf/proto"
)

// ParsedVisibilityConfig is the agent-local view of monitoring.VisibilityConfig.
type ParsedVisibilityConfig struct {
	NetprobeConfig     *netprobepb.VisibilityAgentConfig
	BinaryOverridePath string
}

// stringList decodes a JSON array of strings while additionally tolerating the
// documented compatibility form of a plain JSON string: a non-empty string
// (whitespace-trimmed) decodes as a single-element list, and an empty or
// whitespace-only string decodes as an explicit empty list. Core-side delivery
// coerces scalar-string drift against the package config schema before
// shipping (fj#4381); this decoder-side tolerance is defense in depth so
// schema-compatible drift that still slips through degrades gracefully instead
// of wedging config apply with a permanent unmarshal failure (the demo
// flow-attribution outage: `capture_interfaces` persisted as a scalar string
// failed the `[]string` decode on every cycle and the agent never acked
// another config version).
type stringList []string

func (s *stringList) UnmarshalJSON(data []byte) error {
	token := strings.TrimSpace(string(data))
	if token == "null" {
		*s = nil
		return nil
	}

	if strings.HasPrefix(token, `"`) {
		var single string
		if err := json.Unmarshal(data, &single); err != nil {
			return err
		}

		if single = strings.TrimSpace(single); single == "" {
			*s = stringList{}
		} else {
			*s = stringList{single}
		}

		return nil
	}

	var values []string
	if err := json.Unmarshal(data, &values); err != nil {
		return err
	}

	*s = stringList(values)

	return nil
}

type bootstrapConfig struct {
	Enabled                      bool       `json:"enabled"`
	CaptureInterfaces            stringList `json:"capture_interfaces,omitempty"`
	FlowTableMaxEntries          uint32     `json:"flow_table_max_entries,omitempty"`
	ProcessSnapshotIntervalS     uint32     `json:"process_snapshot_interval_s,omitempty"`
	ExternalFlowMatchWindowMs    uint32     `json:"external_flow_match_window_ms,omitempty"`
	FlowAttributionIpcBatch      bool       `json:"flow_attribution_ipc_batch"`
	EmitRawFlowAttributionEvents bool       `json:"emit_raw_flow_attribution_events"`
	// Written so netprobe has it from BOOT, not only once the agent connects and
	// applies config. The payloads that need it (DPI subject selection, the
	// process snapshot's subject) start flowing before the first apply.
	CollectorIP string `json:"collector_ip,omitempty"`
}

type addonConfig struct {
	Enabled                      *bool      `json:"enabled"`
	CaptureInterfaces            stringList `json:"capture_interfaces"`
	DefaultSampleIntervalMs      *uint32    `json:"default_sample_interval_ms"`
	FlowTableMaxEntries          *uint32    `json:"flow_table_max_entries"`
	ProcessSnapshotIntervalS     *uint32    `json:"process_snapshot_interval_s"`
	ExternalFlowMatchWindowMs    *uint32    `json:"external_flow_match_window_ms"`
	FlowAttributionIpcBatch      *bool      `json:"flow_attribution_ipc_batch"`
	EmitRawFlowAttributionEvents *bool      `json:"emit_raw_flow_attribution_events"`
	// Both declared by addons/netprobe/config.schema.json since the manifest
	// was written, and both absent from this struct until now -- so an operator
	// who set DPI or a per-device binding through the add-on surface had it
	// silently ignored. The merge below leaves the base VisibilityConfig value
	// in place for an absent field, which is why this lost capability rather
	// than data, and why nothing ever errored.
	Dpi            *addonDpiConfig      `json:"dpi"`
	DeviceBindings []addonDeviceBinding `json:"device_bindings"`
}

type addonDpiConfig struct {
	Enabled   *bool      `json:"enabled"`
	Protocols stringList `json:"protocols"`
}

type addonFingerprintConfig struct {
	Tcp  *bool `json:"tcp"`
	Tls  *bool `json:"tls"`
	Http *bool `json:"http"`
}

type addonDeviceBinding struct {
	IP               string                  `json:"ip"`
	ProfileID        string                  `json:"profile_id"`
	ProfileName      string                  `json:"profile_name"`
	SampleIntervalMs uint32                  `json:"sample_interval_ms"`
	Fingerprint      *addonFingerprintConfig `json:"fingerprint"`
	Dpi              *addonDpiConfig         `json:"dpi"`
}

func (d *addonDpiConfig) toProto() *netprobepb.DpiConfig {
	if d == nil {
		return nil
	}

	out := &netprobepb.DpiConfig{Protocols: trimStrings(d.Protocols)}
	if d.Enabled != nil {
		out.Enabled = *d.Enabled
	}

	return out
}

func (f *addonFingerprintConfig) toProto() *netprobepb.FingerprintConfig {
	if f == nil {
		return nil
	}

	out := &netprobepb.FingerprintConfig{}
	if f.Tcp != nil {
		out.Tcp = *f.Tcp
	}
	if f.Tls != nil {
		out.Tls = *f.Tls
	}
	if f.Http != nil {
		out.Http = *f.Http
	}

	return out
}

// A binding with no IP addresses nothing, so it is dropped rather than carried
// as an entry that can never match. The schema marks `ip` required; this is the
// runtime half of that.
func deviceBindingsToProto(bindings []addonDeviceBinding) []*netprobepb.DeviceBinding {
	out := make([]*netprobepb.DeviceBinding, 0, len(bindings))
	for _, binding := range bindings {
		ip := strings.TrimSpace(binding.IP)
		if ip == "" {
			continue
		}

		out = append(out, &netprobepb.DeviceBinding{
			Ip:               ip,
			ProfileId:        strings.TrimSpace(binding.ProfileID),
			ProfileName:      strings.TrimSpace(binding.ProfileName),
			SampleIntervalMs: binding.SampleIntervalMs,
			Fingerprint:      binding.Fingerprint.toProto(),
			Dpi:              binding.Dpi.toProto(),
		})
	}

	return out
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
	if addon.Enabled != nil {
		merged.Enabled = *addon.Enabled
	}
	if addon.CaptureInterfaces != nil {
		merged.CaptureInterfaces = trimStrings(addon.CaptureInterfaces)
	}
	if addon.DefaultSampleIntervalMs != nil {
		merged.DefaultSampleIntervalMs = *addon.DefaultSampleIntervalMs
	}
	if addon.FlowTableMaxEntries != nil {
		merged.FlowTableMaxEntries = *addon.FlowTableMaxEntries
	}
	if addon.ProcessSnapshotIntervalS != nil {
		merged.ProcessSnapshotIntervalS = *addon.ProcessSnapshotIntervalS
	}
	if addon.ExternalFlowMatchWindowMs != nil {
		merged.ExternalFlowMatchWindowMs = *addon.ExternalFlowMatchWindowMs
	}
	if addon.FlowAttributionIpcBatch != nil {
		merged.FlowAttributionIpcBatch = *addon.FlowAttributionIpcBatch
	}
	if addon.EmitRawFlowAttributionEvents != nil {
		merged.EmitRawFlowAttributionEvents = *addon.EmitRawFlowAttributionEvents
	}
	if addon.Dpi != nil {
		merged.Dpi = addon.Dpi.toProto()
	}
	// Replaced wholesale rather than merged element-wise: the operator's list IS
	// the intended set, and an element-wise merge would make removing a binding
	// impossible through this surface. Same rule capture_interfaces already
	// follows -- absent keeps the base, present replaces it.
	if addon.DeviceBindings != nil {
		merged.DeviceBindings = deviceBindingsToProto(addon.DeviceBindings)
	}

	return merged, nil
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
		payload.CollectorIP = strings.TrimSpace(cfg.GetCollectorIp())
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
