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
	"context"
	"errors"
	"strings"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

type icmpCheckConfig struct {
	ID       string
	Name     string
	Target   string
	DeviceID string
	Interval time.Duration
	Timeout  time.Duration
	Enabled  bool
}

type icmpCheckResult struct {
	CheckID        string  `json:"check_id"`
	CheckName      string  `json:"check_name"`
	Target         string  `json:"target"`
	DeviceID       string  `json:"device_id,omitempty"`
	Available      bool    `json:"available"`
	ResponseTimeNs int64   `json:"response_time_ns"`
	PacketLoss     float64 `json:"packet_loss"`
	Timestamp      int64   `json:"timestamp"`
	Error          string  `json:"error,omitempty"`
}

// configPollLoop periodically polls for config updates.
func (p *PushLoop) configPollLoop(ctx context.Context) {
	// Wait for initial enrollment before polling
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for !p.isEnrolled() {
		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		case <-ticker.C:
			// Keep waiting
		}
	}

	// Use a resettable timer so updated intervals take effect
	timer := time.NewTimer(p.getConfigPollInterval())
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			p.logger.Debug().Msg("Config poll loop stopping")
			return
		case <-p.stopCh:
			p.logger.Debug().Msg("Config poll loop stopping due to Stop()")
			return
		case <-timer.C:
			if p.gateway.IsConnected() && p.isEnrolled() {
				p.fetchAndApplyConfig(ctx)
			}
			timer.Reset(p.getConfigPollInterval())
		}
	}
}

// fetchAndApplyConfig fetches config from gateway and applies it.
func (p *PushLoop) fetchAndApplyConfig(ctx context.Context) {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()
	configReq := &proto.AgentConfigRequest{
		AgentId:       agentID,
		ConfigVersion: p.getConfigVersion(),
	}

	configResp, err := p.gateway.GetConfig(ctx, configReq)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to fetch config from gateway")
		return
	}

	p.applyConfigResponse(ctx, configResp, "poll")
}

func (p *PushLoop) applyConfigResponse(ctx context.Context, configResp *proto.AgentConfigResponse, source string) bool {
	if configResp == nil {
		return true
	}

	// If config hasn't changed, nothing to do
	if configResp.NotModified {
		p.logger.Debug().Str("version", p.getConfigVersion()).Msg("Config not modified")
		return true
	}

	// Update intervals from config response
	if configResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(configResp.HeartbeatIntervalSec) * time.Second
		if newInterval < time.Second {
			newInterval = time.Second
		}
		if newInterval > time.Hour {
			newInterval = time.Hour
		}
		if newInterval != p.getInterval() {
			p.setInterval(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Updated push interval from config")
			if !p.isStatusDebounceConfigured() {
				p.setStatusDebounceInterval(newInterval)
			}
		}
		if !p.isStatusHeartbeatConfigured() {
			p.setStatusHeartbeatInterval(newInterval)
		}
	}

	if configResp.ConfigPollIntervalSec > 0 {
		newPollInterval := time.Duration(configResp.ConfigPollIntervalSec) * time.Second
		// Safety bounds to avoid gateway/agent overload or "never poll" configurations.
		const (
			minConfigPollInterval = 30 * time.Second
			maxConfigPollInterval = 24 * time.Hour
		)
		if newPollInterval < minConfigPollInterval {
			newPollInterval = minConfigPollInterval
		} else if newPollInterval > maxConfigPollInterval {
			newPollInterval = maxConfigPollInterval
		}
		if newPollInterval != p.getConfigPollInterval() {
			p.setConfigPollInterval(newPollInterval)
			p.logger.Info().Dur("interval", newPollInterval).Msg("Updated config poll interval")
		}
	}

	p.applySweepConfig(ctx, configResp.ConfigJson)
	p.applyMapperConfig(configResp.ConfigJson)
	if !p.applyBumblebeeConfig(ctx, configResp.BumblebeeConfig, configResp.ConfigJson) {
		p.logger.Warn().
			Str("version", configResp.ConfigVersion).
			Str("source", source).
			Msg("Deferring config version update because Bumblebee config did not apply")
		return false
	}
	if !p.applyEndpointInventoryConfig(ctx, configResp.EndpointInventoryConfig, configResp.ConfigJson) {
		p.logger.Warn().
			Str("version", configResp.ConfigVersion).
			Str("source", source).
			Msg("Deferring config version update because endpoint inventory config did not apply")
		return false
	}
	if p.syncRuntime != nil {
		p.syncRuntime.ApplyConfig(configResp.ConfigJson)
	}
	if !p.applyVisibilityConfig(ctx, configResp.VisibilityConfig, netprobeSystemdAssignmentPresent(configResp.GetAddons())) {
		p.logger.Warn().
			Str("version", configResp.ConfigVersion).
			Str("source", source).
			Msg("Deferring config version update because visibility config did not apply")
		return false
	}

	// Apply sysmon config if present
	if configResp.SysmonConfig != nil {
		p.applySysmonConfig(configResp.SysmonConfig)
	}

	// Apply SNMP config if present
	if configResp.SnmpConfig != nil {
		p.applySNMPConfig(ctx, configResp.SnmpConfig)
	}

	// Apply plugin config if present. Older generated clients may not decode
	// the typed proto field, so keep a JSON fallback in config_json.
	pluginConfig := configResp.PluginConfig
	if pluginConfig == nil {
		pluginConfig = pluginConfigFromConfigJSON(configResp.ConfigJson)
	}
	if pluginConfig != nil {
		p.applyPluginConfig(pluginConfig)
	}

	// Apply native add-on (feature set) assignments if present.
	p.applyAddonAssignments(ctx, configResp.GetAddons())

	// Apply check configs (icmp checks supported)
	p.applyCheckConfigs(configResp.Checks)

	// Update version
	p.setConfigVersion(configResp.ConfigVersion)
	p.logger.Info().
		Str("version", p.getConfigVersion()).
		Str("source", source).
		Msg("Applied new config from gateway")

	return true
}

func (p *PushLoop) applyBumblebeeConfig(
	ctx context.Context,
	protoConfig *proto.BumblebeeConfig,
	configJSON []byte,
) bool {
	cfg, err := resolveGatewayBumblebeeConfig(protoConfig, configJSON)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to parse Bumblebee config from gateway")
		return false
	}
	if cfg == nil {
		return true
	}
	if p.server == nil {
		p.logger.Warn().Msg("Cannot apply Bumblebee config without agent server")
		return false
	}

	p.server.mu.RLock()
	objectStore := p.server.objectStore
	serverConfig := p.server.config
	p.server.mu.RUnlock()

	agentID := ""
	catalogPath := bumblebee.DefaultConfig().CatalogPath
	profilePath := bumblebee.DefaultConfig().ProfilePath
	tmpDir := bumblebee.DefaultConfig().TmpDir
	if serverConfig != nil {
		agentID = serverConfig.AgentID
	}
	if serverConfig != nil && serverConfig.Bumblebee != nil {
		catalogPath = serverConfig.Bumblebee.effectiveCatalogPath()
		profilePath = serverConfig.Bumblebee.effectiveProfilePath()
		tmpDir = serverConfig.Bumblebee.effectiveTmpDir()
	}

	if cfg.Enabled {
		if cfg.Catalog == nil {
			p.logger.Warn().Msg("Bumblebee config is enabled but has no catalog assignment")
			return false
		}

		result, err := bumblebee.StageCatalogAssignment(ctx, objectStore, catalogPath, tmpDir, *cfg.Catalog)
		if err != nil {
			p.logger.Warn().
				Err(err).
				Str("snapshot_ref", cfg.Catalog.SnapshotRef).
				Str("object_key", cfg.Catalog.ObjectKey).
				Msg("Failed to stage Bumblebee catalog assignment")
			return false
		}

		if result.Changed {
			p.logger.Info().
				Str("snapshot_ref", result.SnapshotRef).
				Str("path", result.Path).
				Str("sha256", result.SHA256).
				Msg("Staged Bumblebee catalog assignment")
		}
	}

	if changed, err := bumblebee.WriteRuntimeProfile(profilePath, tmpDir, cfg.runtimeProfile(agentID)); err != nil {
		p.logger.Warn().
			Err(err).
			Str("profile_path", profilePath).
			Msg("Failed to write Bumblebee runtime profile")
		return false
	} else if changed {
		p.logger.Info().
			Str("profile_path", profilePath).
			Bool("enabled", cfg.Enabled).
			Msg("Wrote Bumblebee runtime profile")
	}

	return true
}

func (p *PushLoop) applyEndpointInventoryConfig(
	_ context.Context,
	protoConfig *proto.EndpointInventoryConfig,
	configJSON []byte,
) bool {
	cfg, err := resolveGatewayEndpointInventoryConfig(protoConfig, configJSON)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to parse endpoint inventory config from gateway")
		return false
	}
	if cfg == nil {
		return true
	}
	if p.server == nil {
		p.logger.Warn().Msg("Cannot apply endpoint inventory config without agent server")
		return false
	}

	p.server.mu.RLock()
	serverConfig := p.server.config
	p.server.mu.RUnlock()

	agentID := ""
	profilePath := endpointinventory.DefaultConfig().ProfilePath
	tmpDir := endpointinventory.DefaultConfig().TmpDir
	if serverConfig != nil {
		agentID = serverConfig.AgentID
	}
	if serverConfig != nil && serverConfig.EndpointInventory != nil {
		profilePath = serverConfig.EndpointInventory.effectiveProfilePath()
		tmpDir = serverConfig.EndpointInventory.effectiveTmpDir()
	}

	if changed, err := endpointinventory.WriteRuntimeProfile(profilePath, tmpDir, cfg.runtimeProfile(agentID)); err != nil {
		p.logger.Warn().
			Err(err).
			Str("profile_path", profilePath).
			Msg("Failed to write endpoint inventory runtime profile")
		return false
	} else if changed {
		p.logger.Info().
			Str("profile_path", profilePath).
			Bool("enabled", cfg.Enabled).
			Msg("Wrote endpoint inventory runtime profile")
	}

	return true
}

func (p *PushLoop) applyMapperConfig(configJSON []byte) {
	mapperConfig, err := parseGatewayMapperConfig(configJSON)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to parse mapper config from gateway")
		return
	}

	if mapperConfig == nil {
		p.logger.Debug().
			Int("config_json_bytes", len(configJSON)).
			Msg("Gateway config did not include mapper configuration")
		return
	}

	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	cfg := p.server.config
	p.server.mu.RUnlock()

	compiled, err := buildMapperEngineConfig(mapperConfig, cfg, p.logger)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build mapper config from gateway payload")
		return
	}

	if mapperSvc == nil {
		p.logger.Info().
			Int("scheduled_jobs", len(mapperConfig.ScheduledJobs)).
			Msg("Initializing mapper service from gateway config")

		service, err := NewMapperService(compiled, p.logger)
		if err != nil {
			p.logger.Error().Err(err).Msg("Failed to initialize mapper service")
			return
		}
		mapperSvc = service
		p.server.mu.Lock()
		p.server.mapperService = mapperSvc
		p.server.mu.Unlock()
	}

	if mapperConfig.ConfigHash != "" && mapperSvc.GetConfigHash() == mapperConfig.ConfigHash {
		p.logger.Debug().Str("config_hash", mapperConfig.ConfigHash).Msg("Mapper config unchanged")
		return
	}

	if err := mapperSvc.ApplyMapperConfig(compiled, mapperConfig.ConfigHash); err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply mapper config from gateway")
		return
	}

	p.logger.Info().
		Str("config_hash", mapperConfig.ConfigHash).
		Int("scheduled_jobs", len(mapperConfig.ScheduledJobs)).
		Msg("Applied mapper config from gateway")
}

func (p *PushLoop) applyVisibilityConfig(ctx context.Context, cfg *proto.VisibilityConfig, systemdManaged bool) bool {
	if cfg == nil || p.server == nil {
		return true
	}

	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	sidecarManager := p.server.sidecarManager
	sidecarStatus := p.server.sidecarStatus
	p.server.mu.RUnlock()
	if netprobeSidecar == nil || sidecarManager == nil {
		return true
	}

	parsed := agentnetprobe.ParseVisibilityConfig(cfg)
	if err := agentnetprobe.WriteBootstrapConfig(
		netprobeConfigPath(sidecarStatus),
		parsed.NetprobeConfig,
	); err != nil {
		p.logger.Error().Err(err).Msg("Failed to write netprobe bootstrap config")
		return false
	}

	if systemdManaged {
		return p.applyVisibilityConfigSystemd(ctx, netprobeSidecar, sidecarManager, parsed.NetprobeConfig)
	}

	return p.applyVisibilityConfigLaunched(ctx, netprobeSidecar, sidecarManager, parsed.NetprobeConfig)
}

// applyVisibilityConfigSystemd handles netprobe delivered as a systemd-service add-on: systemd
// owns the process, so the agent attaches (connects for health + event ingest, never launching)
// and hands the config to the sidecar, which (re)applies it over IPC on every (re)connect. It
// never blocks on / fails for a not-yet-running netprobe — the unit is installed later in this
// same config apply (applyAddonAssignments), and the full config is delivered once netprobe
// connects (the bootstrap file only carries basic startup fields, not device bindings).
func (p *PushLoop) applyVisibilityConfigSystemd(
	ctx context.Context,
	netprobeSidecar *agentnetprobe.Sidecar,
	sidecarManager sidecarLifecycleManager,
	cfg *netprobepb.VisibilityAgentConfig,
) bool {
	if started, attach := sidecarManager.Mode(); started && !attach {
		// Coming from the agent-launched path: stop the child so systemd owns the socket.
		p.stopNetprobeManager(ctx, sidecarManager, "switching netprobe to systemd attach mode")
	}
	if started, _ := sidecarManager.Mode(); !started {
		if err := sidecarManager.StartAttach(ctx); err != nil && !errors.Is(err, sidecar.ErrManagerStarted) {
			p.logger.Error().Err(err).Msg("Failed to start netprobe sidecar manager in attach mode")
		}
	}

	netprobeSidecar.SetDesiredConfig(ctx, cfg)
	p.logger.Info().
		Bool("enabled", cfg.GetEnabled()).
		Int("device_bindings", len(cfg.GetDeviceBindings())).
		Msg("Netprobe is systemd-managed; attached and handed desired visibility config")

	return true
}

// applyVisibilityConfigLaunched is the base path: with no netprobe AddonAssignment the agent
// launches + supervises netprobe itself, gated on the VisibilityConfig having capture work.
func (p *PushLoop) applyVisibilityConfigLaunched(
	ctx context.Context,
	netprobeSidecar *agentnetprobe.Sidecar,
	sidecarManager sidecarLifecycleManager,
	cfg *netprobepb.VisibilityAgentConfig,
) bool {
	if started, attach := sidecarManager.Mode(); started && attach {
		// Assignment was removed: drop attach mode and clear the apply-on-connect config so
		// the agent relaunches netprobe and applies config explicitly below.
		p.stopNetprobeManager(ctx, sidecarManager, "netprobe assignment removed; reverting to agent-launched")
		netprobeSidecar.SetDesiredConfig(ctx, nil)
	}

	if !netprobeConfigHasWork(cfg) {
		stopCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		if err := sidecarManager.Stop(stopCtx); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to stop disabled netprobe sidecar manager")
		}
		p.logger.Info().Msg("Netprobe visibility config disabled or has no capture work")
		return true
	}

	if err := sidecarManager.Start(ctx); err != nil && !errors.Is(err, sidecar.ErrManagerStarted) {
		p.logger.Error().Err(err).Msg("Failed to start netprobe sidecar manager")
		return false
	}

	applyCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	configHash, err := netprobeSidecar.ApplyConfig(applyCtx, cfg)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply visibility config to netprobe sidecar")
		return false
	}

	p.logger.Info().
		Str("config_hash", configHash).
		Int("device_bindings", len(cfg.GetDeviceBindings())).
		Int("capture_interfaces", len(cfg.GetCaptureInterfaces())).
		Msg("Applied visibility config to netprobe sidecar")

	return true
}

// stopNetprobeManager stops the sidecar manager (best-effort, bounded) so it can be restarted
// in the other mode.
func (p *PushLoop) stopNetprobeManager(ctx context.Context, sidecarManager sidecarLifecycleManager, reason string) {
	stopCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := sidecarManager.Stop(stopCtx); err != nil {
		p.logger.Warn().Err(err).Str("reason", reason).Msg("Failed to stop netprobe sidecar manager during mode switch")
	}
}

// netprobeSystemdAssignmentPresent reports whether the gateway config carries an enabled
// netprobe AddonAssignment with systemd supervision — the switch that moves netprobe off the
// always-on agent-launched visibility path onto the systemd-service add-on lifecycle.
func netprobeSystemdAssignmentPresent(addons []*proto.AddonAssignmentConfig) bool {
	for _, addon := range addons {
		if addon == nil {
			continue
		}
		if addon.GetAddonId() == agentnetprobe.DefaultSidecarName &&
			addon.GetEnabled() &&
			classifyAddonSupervision(addon.GetSupervision()) == addonDispatchSystemd {
			return true
		}
	}

	return false
}

// netprobeConfigHasWork reports whether netprobe should be running. Enabling netprobe is
// enough on its own: the eBPF kprobe process-attribution path (the flow->PID source that
// feeds attributed flows) runs with no capture interfaces at all. Packet capture / DPI is
// purely additive — it only engages when capture_interfaces or device_bindings are set — so
// requiring them to launch netprobe broke attribution-only ("one-touch") enablement.
func netprobeConfigHasWork(cfg *netprobepb.VisibilityAgentConfig) bool {
	return cfg != nil && cfg.GetEnabled()
}

func netprobeConfigPath(provider sidecarStatusProvider) string {
	if provider == nil {
		return ""
	}

	for _, status := range provider.Status() {
		if strings.EqualFold(status.Name, agentnetprobe.DefaultSidecarName) {
			return status.ConfigPath
		}
	}

	return ""
}

func (p *PushLoop) applySweepConfig(ctx context.Context, configJSON []byte) {
	sweepSvc := p.findSweepResultsProvider()
	if sweepSvc == nil {
		return
	}

	sweepConfig, err := parseGatewaySweepConfig(configJSON, p.logger)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to parse sweep config from gateway")
		return
	}

	if sweepConfig == nil {
		return
	}

	if sweepConfig.ConfigHash != "" && sweepSvc.GetConfigHash() == sweepConfig.ConfigHash {
		p.logger.Debug().Str("config_hash", sweepConfig.ConfigHash).Msg("Sweep config unchanged")
		return
	}

	p.server.mu.RLock()
	cfg := p.server.config
	p.server.mu.RUnlock()

	if updater, ok := sweepSvc.(SweepGroupConfigContextUpdater); ok {
		if err := updater.UpdateSweepGroupsContext(ctx, sweepConfig); err != nil {
			p.logger.Error().Err(err).Msg("Failed to apply sweep group config from gateway")
			return
		}

		p.logger.Info().
			Str("config_hash", sweepConfig.ConfigHash).
			Int("group_count", len(sweepConfig.Groups)).
			Msg("Applied sweep group config from gateway")
		return
	}

	if updater, ok := sweepSvc.(SweepGroupConfigUpdater); ok {
		if err := updater.UpdateSweepGroups(sweepConfig); err != nil {
			p.logger.Error().Err(err).Msg("Failed to apply sweep group config from gateway")
			return
		}

		p.logger.Info().
			Str("config_hash", sweepConfig.ConfigHash).
			Int("group_count", len(sweepConfig.Groups)).
			Msg("Applied sweep group config from gateway")
		return
	}

	if len(sweepConfig.Groups) == 0 {
		p.logger.Info().Msg("No sweep groups configured; skipping sweep update")
		return
	}

	groupConfig := sweepConfig.Groups[0]
	sweepModelConfig, err := buildSweepModelConfigFromGroup(cfg, groupConfig, p.logger)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build sweep config from gateway payload")
		return
	}

	if updater, ok := sweepSvc.(interface{ UpdateConfig(*models.Config) error }); ok {
		if err := updater.UpdateConfig(sweepModelConfig); err != nil {
			p.logger.Error().Err(err).Msg("Failed to apply sweep config from gateway")
			return
		}

		p.logger.Info().
			Str("config_hash", sweepConfig.ConfigHash).
			Int("networks", len(groupConfig.Networks)).
			Int("device_targets", len(groupConfig.DeviceTargets)).
			Int("ports", len(groupConfig.Ports)).
			Msg("Applied sweep config from gateway")
	}
}

// applySysmonConfig applies sysmon configuration from the gateway to the embedded sysmon service.
func (p *PushLoop) applySysmonConfig(protoConfig *proto.SysmonConfig) {
	p.server.mu.RLock()
	sysmonSvc := p.server.sysmonService
	p.server.mu.RUnlock()

	if sysmonSvc == nil {
		p.logger.Debug().Msg("Sysmon service not initialized, skipping config apply")
		return
	}

	cfg := protoToSysmonConfig(protoConfig)

	if err := sysmonSvc.ApplyRemoteConfig(cfg); err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply sysmon config from gateway")
		return
	}

	p.logger.Info().
		Str("profile_id", protoConfig.ProfileId).
		Str("profile_name", protoConfig.ProfileName).
		Str("config_source", protoConfig.ConfigSource).
		Bool("enabled", cfg.Enabled).
		Str("sample_interval", cfg.SampleInterval).
		Bool("cpu", cfg.CollectCPU).
		Bool("memory", cfg.CollectMemory).
		Bool("disk", cfg.CollectDisk).
		Bool("network", cfg.CollectNetwork).
		Bool("processes", cfg.CollectProcesses).
		Msg("Applied sysmon config from gateway")
}

// protoToSysmonConfig converts a proto SysmonConfig to a sysmon.Config.
func protoToSysmonConfig(proto *proto.SysmonConfig) sysmon.Config {
	if proto == nil {
		return sysmon.DefaultConfig()
	}

	cfg := sysmon.Config{
		Enabled:          proto.Enabled,
		SampleInterval:   proto.SampleInterval,
		CollectCPU:       proto.CollectCpu,
		CollectMemory:    proto.CollectMemory,
		CollectDisk:      proto.CollectDisk,
		CollectNetwork:   proto.CollectNetwork,
		CollectProcesses: proto.CollectProcesses,
		ProcessLimit:     int(proto.ProcessLimit),
		DiskPaths:        proto.DiskPaths,
		DiskExcludePaths: proto.DiskExcludePaths,
		Thresholds:       proto.Thresholds,
	}

	// Apply defaults for any unset values
	return cfg.MergeWithDefaults()
}

// applySNMPConfig applies SNMP configuration from the gateway to the embedded SNMP service.
func (p *PushLoop) applySNMPConfig(ctx context.Context, protoConfig *proto.SNMPConfig) {
	p.server.mu.RLock()
	snmpSvc := p.server.snmpService
	p.server.mu.RUnlock()

	if snmpSvc == nil {
		p.logger.Debug().Msg("SNMP service not initialized, skipping config apply")
		return
	}

	if ctx == nil {
		ctx = context.Background()
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	if err := snmpSvc.ApplyProtoConfig(ctx, protoConfig); err != nil {
		p.logger.Warn().Err(err).Msg("Failed to apply SNMP config")
	}
}

func (p *PushLoop) applyCheckConfigs(checks []*proto.AgentCheckConfig) {
	parsed := make(map[string]*icmpCheckConfig)

	for _, check := range checks {
		cfg := parseICMPCheckConfig(check)
		if cfg == nil {
			continue
		}
		parsed[cfg.ID] = cfg
	}

	p.icmpMu.Lock()
	p.icmpChecks = parsed
	for id := range p.icmpLastRun {
		if _, ok := parsed[id]; !ok {
			delete(p.icmpLastRun, id)
		}
	}
	p.icmpMu.Unlock()

	if len(parsed) > 0 {
		p.logger.Info().Int("icmp_checks", len(parsed)).Msg("Applied ICMP check config from gateway")
	} else if len(checks) > 0 {
		p.logger.Debug().Msg("Gateway checks did not include any ICMP checks")
	}

	// Apply MTR check configs from the same check list.
	p.applyMtrCheckConfigs(checks)
}

func parseICMPCheckConfig(check *proto.AgentCheckConfig) *icmpCheckConfig {
	if check == nil {
		return nil
	}

	checkType := strings.ToLower(strings.TrimSpace(check.CheckType))
	if checkType != "icmp" && checkType != "ping" {
		return nil
	}

	if !check.Enabled {
		return nil
	}

	target := strings.TrimSpace(check.Target)
	if target == "" {
		return nil
	}

	checkID := strings.TrimSpace(check.CheckId)
	if checkID == "" {
		return nil
	}

	interval := time.Duration(check.IntervalSec) * time.Second
	timeout := time.Duration(check.TimeoutSec) * time.Second

	deviceID := ""
	if check.Settings != nil {
		if value, ok := check.Settings["device_id"]; ok {
			deviceID = strings.TrimSpace(value)
		}
		if deviceID == "" {
			if value, ok := check.Settings["device_uid"]; ok {
				deviceID = strings.TrimSpace(value)
			}
		}
	}

	return &icmpCheckConfig{
		ID:       checkID,
		Name:     strings.TrimSpace(check.Name),
		Target:   target,
		DeviceID: deviceID,
		Interval: interval,
		Timeout:  timeout,
		Enabled:  check.Enabled,
	}
}
