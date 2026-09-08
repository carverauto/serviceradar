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
	"encoding/json"

	"github.com/carverauto/serviceradar/proto"
)

func (p *PushLoop) applyPluginConfig(config *proto.PluginConfig) {
	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	p.server.mu.RUnlock()

	if pluginManager == nil {
		p.logger.Warn().Msg("Plugin manager not initialized")
		return
	}

	if config == nil {
		pluginManager.ApplyConfig(nil)
		return
	}

	p.logger.Info().
		Int("assignments", len(config.Assignments)).
		Msg("Received plugin assignments from gateway")

	pluginManager.ApplyConfig(config)
}

func (p *PushLoop) appliedPluginAssignmentPolicyAcks() []*proto.PluginAssignmentPolicyAck {
	if p == nil || p.server == nil {
		return nil
	}

	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	p.server.mu.RUnlock()
	if pluginManager == nil {
		return nil
	}

	return pluginManager.ProxmoxAssignmentPolicyAcks()
}

type pluginConfigEnvelope struct {
	Plugins      *pluginConfigPayload `json:"plugins"`
	PluginConfig *pluginConfigPayload `json:"plugin_config"`
}

type pluginConfigPayload struct {
	Assignments  []pluginAssignmentPayload `json:"assignments"`
	EngineLimits pluginEngineLimitsPayload `json:"engine_limits"`
}

type pluginAssignmentPayload struct {
	AssignmentID  string          `json:"assignment_id"`
	PluginID      string          `json:"plugin_id"`
	PackageID     string          `json:"package_id"`
	Version       string          `json:"version"`
	Name          string          `json:"name"`
	Entrypoint    string          `json:"entrypoint"`
	Runtime       string          `json:"runtime"`
	Outputs       string          `json:"outputs"`
	Capabilities  []string        `json:"capabilities"`
	Params        json.RawMessage `json:"params"`
	Permissions   json.RawMessage `json:"permissions"`
	Resources     json.RawMessage `json:"resources"`
	Enabled       bool            `json:"enabled"`
	IntervalSec   int32           `json:"interval_sec"`
	TimeoutSec    int32           `json:"timeout_sec"`
	WasmObjectKey string          `json:"wasm_object_key"`
	ContentHash   string          `json:"content_hash"`
	SourceType    string          `json:"source_type"`
	SourceRepoURL string          `json:"source_repo_url"`
	SourceCommit  string          `json:"source_commit"`
	DownloadURL   string          `json:"download_url"`
	DownloadToken string          `json:"download_token"`
}

type pluginEngineLimitsPayload struct {
	MaxMemoryMB        int32 `json:"max_memory_mb"`
	MaxCPUMS           int32 `json:"max_cpu_ms"`
	MaxConcurrent      int32 `json:"max_concurrent"`
	MaxOpenConnections int32 `json:"max_open_connections"`
}

func pluginConfigFromConfigJSON(configJSON []byte) *proto.PluginConfig {
	if len(configJSON) == 0 {
		return nil
	}

	var envelope pluginConfigEnvelope
	if err := json.Unmarshal(configJSON, &envelope); err != nil {
		return nil
	}

	payload := envelope.Plugins
	if payload == nil {
		payload = envelope.PluginConfig
	}
	if payload == nil {
		return nil
	}

	config := &proto.PluginConfig{
		Assignments:  make([]*proto.PluginAssignmentConfig, 0, len(payload.Assignments)),
		EngineLimits: pluginEngineLimitsFromJSON(payload.EngineLimits),
	}

	for _, assignment := range payload.Assignments {
		config.Assignments = append(config.Assignments, pluginAssignmentFromJSON(assignment))
	}

	return config
}

func pluginAssignmentFromJSON(assignment pluginAssignmentPayload) *proto.PluginAssignmentConfig {
	return &proto.PluginAssignmentConfig{
		AssignmentId:    assignment.AssignmentID,
		PluginId:        assignment.PluginID,
		PackageId:       assignment.PackageID,
		Version:         assignment.Version,
		Name:            assignment.Name,
		Entrypoint:      assignment.Entrypoint,
		Runtime:         assignment.Runtime,
		Outputs:         assignment.Outputs,
		Capabilities:    assignment.Capabilities,
		ParamsJson:      cloneRawJSON(assignment.Params),
		PermissionsJson: cloneRawJSON(assignment.Permissions),
		ResourcesJson:   cloneRawJSON(assignment.Resources),
		Enabled:         assignment.Enabled,
		IntervalSec:     assignment.IntervalSec,
		TimeoutSec:      assignment.TimeoutSec,
		WasmObjectKey:   assignment.WasmObjectKey,
		ContentHash:     assignment.ContentHash,
		SourceType:      assignment.SourceType,
		SourceRepoUrl:   assignment.SourceRepoURL,
		SourceCommit:    assignment.SourceCommit,
		DownloadUrl:     assignment.DownloadURL,
		DownloadToken:   assignment.DownloadToken,
	}
}

func pluginEngineLimitsFromJSON(limits pluginEngineLimitsPayload) *proto.PluginEngineLimits {
	return &proto.PluginEngineLimits{
		MaxMemoryMb:        limits.MaxMemoryMB,
		MaxCpuMs:           limits.MaxCPUMS,
		MaxConcurrent:      limits.MaxConcurrent,
		MaxOpenConnections: limits.MaxOpenConnections,
	}
}

func cloneRawJSON(raw json.RawMessage) []byte {
	if len(raw) == 0 {
		return nil
	}

	out := make([]byte, len(raw))
	copy(out, raw)
	return out
}
