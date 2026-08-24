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
	"fmt"
	"net/http"
	"strings"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
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

const kubernetesAgentID = "k8s-agent"

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
	sequence := p.nextConfigSequence()

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

	p.applyConfigResponseWithSequence(ctx, configResp, "poll", sequence)
}

func (p *PushLoop) applyConfigResponse(ctx context.Context, configResp *proto.AgentConfigResponse, source string) bool {
	return p.applyConfigResponseWithSequence(
		ctx,
		configResp,
		source,
		p.nextConfigSequence(),
	)
}

func (p *PushLoop) nextConfigSequence() uint64 {
	return p.configSequence.Add(1)
}

func (p *PushLoop) applyConfigResponseWithSequence(
	ctx context.Context,
	configResp *proto.AgentConfigResponse,
	source string,
	sequence uint64,
) bool {
	if configResp == nil {
		return true
	}

	// A config response is one transaction: in particular, resolving effective add-on
	// assignments, writing visibility bootstrap state, and activating native add-ons must
	// never interleave with another poll/control response. Otherwise response B can replace
	// the bootstrap while response A is still activating its netprobe unit.
	p.configApplyMu.Lock()
	defer p.configApplyMu.Unlock()

	// Config versions are content hashes and the response timestamp is generated from the
	// control plane's wall clock, so neither can order concurrent poll and control-stream
	// compilations. Instead, callers allocate an agent-local sequence before starting a poll
	// request or immediately on receiving a control response. Once a higher sequence begins an
	// apply transaction, a delayed lower sequence cannot replace it. A later retry receives a new
	// sequence and remains eligible.
	if sequence < p.latestConfigSequence {
		p.logger.Warn().
			Uint64("config_sequence", sequence).
			Uint64("latest_config_sequence", p.latestConfigSequence).
			Int64("config_timestamp", configResp.GetConfigTimestamp()).
			Str("version", configResp.GetConfigVersion()).
			Str("source", source).
			Msg("Ignoring stale config response")

		// A control-stream caller must not ACK a version that was not applied.
		return false
	}
	if sequence > p.latestConfigSequence {
		p.latestConfigSequence = sequence
	}

	// If config hasn't changed, nothing to do
	if configResp.NotModified {
		p.logger.Debug().Str("version", p.getConfigVersion()).Msg("Config not modified")
		return true
	}

	// The control stream pushes a fresh (not_modified:false) config on every dependency
	// write on the gateway side, even when the agent's compiled config is unchanged. The
	// config version hash is deterministic, so a version equal to the one we already
	// applied means an identical config: skip the full re-apply pipeline (sweep clear,
	// sysmon, plugin assignments, netprobe re-attach) to avoid a control-stream apply
	// storm. The caller still ACKs on a true return. getConfigVersion() is only set after a
	// fully-successful apply, so a deferred/partial apply (which leaves the old version)
	// will not be short-circuited and is still retried.
	if v := configResp.ConfigVersion; v != "" && v == p.getConfigVersion() {
		p.logger.Debug().
			Str("version", v).
			Str("source", source).
			Msg("Config version unchanged; skipping redundant re-apply")

		return true
	}

	p.applyConfigIntervals(configResp)

	// The control plane re-streams the SAME deterministic config version on every dependency
	// write (not_modified:false), and a genuinely-transient section keeps that version
	// uncommitted, so the gateway re-streams it on every poll. Re-running the full idempotent
	// pipeline (sweep clear, mapper, sysmon, SNMP, plugins, checks) on every resend is an
	// apply storm. Because the version is a deterministic hash of the whole config, an equal
	// version means identical inputs for those sections, so run them only on the FIRST attempt
	// of a version — lastAttemptedConfigVersion is recorded once an attempt reaches the end of
	// the heavy pipeline below (see comment there). The deferrable sections (Bumblebee,
	// endpoint inventory, add-ons, visibility) always run so a transient failure still retries.
	firstAttempt := configResp.ConfigVersion == "" ||
		configResp.ConfigVersion != p.getLastAttemptedConfigVersion()

	if firstAttempt {
		p.applySweepConfig(ctx, configResp.ConfigJson)
		p.applyMapperConfig(configResp.ConfigJson)
	}

	// Apply every config section independently. A section that cannot apply yet only DEFERS
	// the config-version update so the gateway resends it — it must NOT short-circuit and
	// block the unrelated sections that follow. A PERMANENT failure (one that a resend of the
	// identical config cannot fix — a parse error, a missing agent server, a fixed-path write
	// failure) is recorded as persistent per-section state (escalated once, skipped while its
	// payload is unchanged, reported on the config ack) but does NOT defer: wedging the
	// version commit on it would freeze the whole config apply and make the gateway re-stream
	// the same version on every poll forever (fj #4301). Only a TRANSIENT failure (one that
	// may clear on its own) defers — and it defers WITHOUT skipping the remaining sections,
	// so one flaky section can never starve the others in the same cycle.
	deferred := false
	version := configResp.ConfigVersion

	bumblebeeHash := hashConfigSectionPayload(
		marshalConfigSectionMessage(configResp.BumblebeeConfig),
		configResp.ConfigJson,
	)
	if p.applyConfigSection(configSectionBumblebee, version, bumblebeeHash, func() (addonDeliveryDisposition, error) {
		return p.applyBumblebeeConfig(ctx, configResp.BumblebeeConfig, configResp.ConfigJson)
	}) == addonDeliveryTransientFailure {
		p.logger.Warn().
			Str("version", version).
			Str("source", source).
			Msg("Deferring config version update because Bumblebee config did not apply")
		deferred = true
	}

	endpointInventoryHash := hashConfigSectionPayload(
		marshalConfigSectionMessage(configResp.EndpointInventoryConfig),
		configResp.ConfigJson,
	)
	if p.applyConfigSection(configSectionEndpointInventory, version, endpointInventoryHash, func() (addonDeliveryDisposition, error) {
		return p.applyEndpointInventoryConfig(ctx, configResp.EndpointInventoryConfig, configResp.ConfigJson)
	}) == addonDeliveryTransientFailure {
		p.logger.Warn().
			Str("version", version).
			Str("source", source).
			Msg("Deferring config version update because endpoint inventory config did not apply")
		deferred = true
	}
	if firstAttempt && p.syncRuntime != nil {
		p.syncRuntime.ApplyConfig(configResp.ConfigJson)
	}

	// Resolve local overrides before either consumer runs. In particular, a local
	// netprobe override must participate in visibility bootstrap/attach gating before
	// native add-on reconciliation is allowed to activate its systemd unit.
	effectiveAddons := p.effectiveAddonAssignments(configResp.GetAddons())

	// The visibility payload includes the add-on assignments because the netprobe
	// assignment's config_json is merged into the visibility config (the incident shape:
	// a type-invalid capture_interfaces wedged the whole apply pre-#4301). Apply visibility
	// before native add-ons so a systemd-managed netprobe always starts or restarts against
	// the bootstrap config from this response, rather than the previous response.
	visibilityHashParts := append(
		[][]byte{marshalConfigSectionMessage(configResp.VisibilityConfig)},
		marshalAddonAssignmentsForHash(effectiveAddons)...,
	)
	visibilityDisposition := p.applyConfigSection(configSectionVisibility, version, hashConfigSectionPayload(visibilityHashParts...), func() (addonDeliveryDisposition, error) {
		return p.applyVisibilityConfig(ctx, configResp.VisibilityConfig, effectiveAddons)
	})
	if visibilityDisposition == addonDeliveryTransientFailure {
		p.logger.Warn().
			Str("version", version).
			Str("source", source).
			Msg("Deferring config version update because visibility config did not apply")
		deferred = true
	}

	// Apply native add-on assignments after visibility has written any startup-sensitive
	// bootstrap config. Independent telemetry add-ons still start even when visibility is
	// deferred because section failures do not short-circuit the rest of this apply cycle.
	// A transient assignment failure defers the version like every other section — it no
	// longer early-returns, so the sysmon/SNMP/plugin/check sections below still
	// apply in the same cycle. The payload hash is empty on purpose: assignments carry
	// their own per-add-on failure state + backoff and must always reconcile
	// systemd/ephemeral desired state.
	activationBlocks := make(map[string]bool)
	if visibilityDisposition != addonDeliverySucceeded {
		if netprobe := netprobeSystemdAssignment(effectiveAddons); netprobe != nil {
			activationBlocks[netprobe.GetAddonId()] = true
		}
	}
	if p.applyConfigSection(configSectionAddons, version, "", func() (addonDeliveryDisposition, error) {
		return p.applyEffectiveAddonAssignmentsWithActivationBlocks(ctx, effectiveAddons, activationBlocks)
	}) == addonDeliveryTransientFailure {
		p.logger.Warn().
			Str("version", version).
			Str("source", source).
			Msg("Deferring config version update because add-on assignments did not apply")
		deferred = true
	}

	if firstAttempt {
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
		// A full config response is authoritative for every section. In
		// particular, an older control plane that omits the typed plugin field
		// (or sends an undecodable JSON fallback) must not leave assignments from
		// the previous config running while the agent commits the new version.
		// ApplyConfig(nil) is the fail-closed empty desired state and also cancels
		// streaming executions whose assignment generation was revoked.
		p.applyPluginConfig(pluginConfig)
	}

	if firstAttempt {
		// Apply check configs (icmp checks supported)
		p.applyCheckConfigs(configResp.Checks)
	}

	// Record that this version made it through the full idempotent pipeline at least once, so
	// a subsequent resend of the SAME (still-uncommitted) version skips the heavy re-apply
	// above while the deferrable sections keep retrying. Every section is evaluated every
	// cycle now (no early returns), so the heavy pass always completes before this point.
	if configResp.ConfigVersion != "" {
		p.setLastAttemptedConfigVersion(configResp.ConfigVersion)
	}

	// Defer the version update if any section could not apply yet, so the gateway resends and
	// the agent retries the still-pending sections — the sections that DID apply stay applied.
	if deferred {
		return false
	}

	// Update version
	p.setConfigVersion(configResp.ConfigVersion)
	p.logger.Info().
		Str("version", p.getConfigVersion()).
		Str("source", source).
		Msg("Applied new config from gateway")

	return true
}

// applyConfigIntervals updates the push/heartbeat and config-poll intervals from the config
// response, clamping each to safe bounds.
func (p *PushLoop) applyConfigIntervals(configResp *proto.AgentConfigResponse) {
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
}

// errConfigSectionNoAgentServer is recorded as a permanent config-section failure when a
// section cannot apply because the agent server is unavailable. The server is set at agent
// construction and never appears mid-run, so a resend of the same config cannot fix it.
var errConfigSectionNoAgentServer = errors.New("agent server not available")

// errBumblebeeCatalogMissing is recorded as a permanent failure when a Bumblebee config is
// enabled but carries no catalog assignment — a control-plane inconsistency that a resend of
// the identical config version cannot resolve.
var errBumblebeeCatalogMissing = errors.New("bumblebee config enabled without a catalog assignment")

// errNetprobeVisibilityConfigMissing is recorded as a permanent failure when a
// systemd-managed netprobe assignment has no visibility configuration to apply.
var errNetprobeVisibilityConfigMissing = errors.New("netprobe assignment requires visibility config")

// logBumblebeeCatalogFailure logs a TRANSIENT Bumblebee catalog staging failure with its
// assignment context. Permanent staging failures are not logged here: they are recorded
// as persistent per-section state and escalated once by recordConfigSectionFailure.
func (p *PushLoop) logBumblebeeCatalogFailure(catalog *bumblebee.CatalogAssignment, err error) {
	p.logger.Warn().
		Err(err).
		Str("section", configSectionBumblebee).
		Bool("permanent", false).
		Str("snapshot_ref", catalog.SnapshotRef).
		Str("object_key", catalog.ObjectKey).
		Str("download_url", catalog.DownloadURL).
		Msg("Failed to stage Bumblebee catalog assignment")
}

// classifyBumblebeeCatalogError maps a Bumblebee catalog staging error to a delivery
// disposition, mirroring classifyAddonDeliveryError: an incomplete reference or sha256
// mismatch is PERMANENT (a resend of the identical assignment cannot fix it), a 4xx gateway
// download is PERMANENT (the object is absent/rejected) and an oversize catalog is a
// PERMANENT budget violation, while a missing object store, a 5xx download, or any
// connectivity/IO error is TRANSIENT and may clear on its own.
func classifyBumblebeeCatalogError(err error) addonDeliveryDisposition {
	switch {
	case errors.Is(err, bumblebee.ErrCatalogAssignmentIncomplete),
		errors.Is(err, bumblebee.ErrCatalogHashMismatch),
		errors.Is(err, errBumblebeeCatalogTooLarge):
		return addonDeliveryPermanentFailure
	case errors.Is(err, bumblebee.ErrCatalogObjectStoreUnavailable):
		return addonDeliveryTransientFailure
	}

	if errors.Is(err, errBumblebeeCatalogDownloadFailed) {
		if code, ok := gatewayArtifactStatusCode(err); ok &&
			code >= http.StatusBadRequest && code < http.StatusInternalServerError {
			return addonDeliveryPermanentFailure
		}

		return addonDeliveryTransientFailure
	}

	return addonDeliveryTransientFailure
}

func (p *PushLoop) applyBumblebeeConfig(
	ctx context.Context,
	protoConfig *proto.BumblebeeConfig,
	configJSON []byte,
) (addonDeliveryDisposition, error) {
	cfg, err := resolveGatewayBumblebeeConfig(protoConfig, configJSON)
	if err != nil {
		// A structurally-fixed payload that fails to parse will fail identically on every
		// resend of the same config version: permanent, so record it but do not defer.
		return addonDeliveryPermanentFailure, fmt.Errorf("parse bumblebee config from gateway: %w", err)
	}
	if cfg == nil {
		return addonDeliverySucceeded, nil
	}
	if p.server == nil {
		// The agent server is set at construction and never appears mid-run: permanent.
		return addonDeliveryPermanentFailure, errConfigSectionNoAgentServer
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
		statusCfg := &BumblebeeStatusConfig{
			Enabled:     true,
			CatalogPath: catalogPath,
			ProfilePath: profilePath,
			TmpDir:      tmpDir,
		}
		if serverConfig != nil && serverConfig.Bumblebee != nil {
			statusCfg.SpoolPath = serverConfig.Bumblebee.SpoolPath
		}
		p.server.ensureBumblebeeSpoolService(statusCfg)

		if cfg.Catalog == nil {
			// Enabled with no catalog is a control-plane config inconsistency for this exact
			// version; a resend of the identical config cannot supply one: permanent.
			return addonDeliveryPermanentFailure, errBumblebeeCatalogMissing
		}

		downloader := objectStore
		if strings.TrimSpace(cfg.Catalog.DownloadURL) != "" {
			downloader = gatewayArtifactDownloader{
				client:      p.gatewayArtifactDownloadHTTPClient(cfg.Catalog.DownloadURL),
				downloadURL: cfg.Catalog.DownloadURL,
				token:       cfg.Catalog.DownloadToken,
				objectKey:   cfg.Catalog.ObjectKey,
				maxBytes:    maxBumblebeeCatalogBytes,
				statusErr:   errBumblebeeCatalogDownloadFailed,
				tooLargeErr: errBumblebeeCatalogTooLarge,
			}
		}

		result, err := bumblebee.StageCatalogAssignment(
			ctx,
			downloader,
			catalogPath,
			tmpDir,
			*cfg.Catalog,
		)
		if err != nil {
			// Catalog staging is a download+verify, so split it like an add-on artifact
			// delivery: an incomplete reference / sha mismatch / 4xx is permanent (record +
			// do not defer), while a missing object store / 5xx / connectivity error is
			// transient (defer + retry on the next poll).
			disposition := classifyBumblebeeCatalogError(err)
			if disposition == addonDeliveryTransientFailure {
				p.logBumblebeeCatalogFailure(cfg.Catalog, err)
			}
			return disposition, fmt.Errorf("stage bumblebee catalog assignment (snapshot_ref=%s object_key=%s): %w",
				cfg.Catalog.SnapshotRef, cfg.Catalog.ObjectKey, err)
		}

		if result.Changed {
			p.logger.Info().
				Str("snapshot_ref", result.SnapshotRef).
				Str("path", result.Path).
				Str("sha256", result.SHA256).
				Msg("Staged Bumblebee catalog assignment")
		}
	}

	if !cfg.Enabled && strings.EqualFold(strings.TrimSpace(agentID), kubernetesAgentID) {
		p.logger.Info().
			Str("agent_id", agentID).
			Msg("Skipping disabled Bumblebee runtime profile for Kubernetes agent")
		return addonDeliverySucceeded, nil
	}

	if changed, err := bumblebee.WriteRuntimeProfile(profilePath, tmpDir, cfg.runtimeProfile(agentID)); err != nil {
		// The profile path and contents are fixed for this version, so a resend writes the
		// same bytes to the same path and fails the same way: permanent (record, do not
		// defer). A real underlying fault (e.g. disk) is picked up on the next config change.
		return addonDeliveryPermanentFailure, fmt.Errorf("write bumblebee runtime profile: %w", err)
	} else if changed {
		p.logger.Info().
			Str("profile_path", profilePath).
			Bool("enabled", cfg.Enabled).
			Msg("Wrote Bumblebee runtime profile")
	}

	return addonDeliverySucceeded, nil
}

func (p *PushLoop) applyEndpointInventoryConfig(
	_ context.Context,
	protoConfig *proto.EndpointInventoryConfig,
	configJSON []byte,
) (addonDeliveryDisposition, error) {
	cfg, err := resolveGatewayEndpointInventoryConfig(protoConfig, configJSON)
	if err != nil {
		// A structurally-fixed payload that fails to parse will fail identically on every
		// resend of the same config version: permanent, so record it but do not defer. This
		// is the fj #4301 wedge — endpoint inventory is enabled-by-default, so a defer here
		// blocked the version commit and made the gateway re-stream the same version forever.
		return addonDeliveryPermanentFailure, fmt.Errorf("parse endpoint inventory config from gateway: %w", err)
	}
	if cfg == nil {
		return addonDeliverySucceeded, nil
	}
	if p.server == nil {
		// The agent server is set at construction and never appears mid-run: permanent.
		return addonDeliveryPermanentFailure, errConfigSectionNoAgentServer
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

	if cfg.Enabled {
		statusCfg := &EndpointInventoryStatusConfig{
			Enabled:     true,
			ProfilePath: profilePath,
			TmpDir:      tmpDir,
		}
		if serverConfig != nil && serverConfig.EndpointInventory != nil {
			statusCfg.ConfigPath = serverConfig.EndpointInventory.ConfigPath
			statusCfg.SpoolPath = serverConfig.EndpointInventory.SpoolPath
			statusCfg.CacheDir = serverConfig.EndpointInventory.CacheDir
		}
		p.server.ensureEndpointInventorySpoolService(statusCfg)
	}

	if !cfg.Enabled && strings.EqualFold(strings.TrimSpace(agentID), kubernetesAgentID) {
		p.logger.Info().
			Str("agent_id", agentID).
			Msg("Skipping disabled endpoint inventory runtime profile for Kubernetes agent")
		return addonDeliverySucceeded, nil
	}

	if changed, err := endpointinventory.WriteRuntimeProfile(profilePath, tmpDir, cfg.runtimeProfile(agentID)); err != nil {
		// The profile path and contents are fixed for this version, so a resend writes the
		// same bytes to the same path and fails the same way: permanent (record, do not
		// defer). A real underlying fault (e.g. disk) is picked up on the next config change.
		return addonDeliveryPermanentFailure, fmt.Errorf("write endpoint inventory runtime profile: %w", err)
	} else if changed {
		p.logger.Info().
			Str("profile_path", profilePath).
			Bool("enabled", cfg.Enabled).
			Msg("Wrote endpoint inventory runtime profile")
	}

	return addonDeliverySucceeded, nil
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

// stampCollectorIP records WHERE netprobe is running, for the payloads that
// need a subject: DPI endpoint selection and the process snapshot.
//
// Extracted so it is testable. The rule it enforces is one line but easy to get
// wrong: the address comes from getSourceIP(), never from config.HostIP.
// `host_ip` in agent.json is an onboard-time pin, and a re-IP'd host leaves it
// pointing at an address that is no longer on any local interface -- while
// getSourceIP() keeps the pin only while it is still live and otherwise
// re-detects, which is what Hello, PushStatus, SNMP, plugin signals and
// workload identity all already use.
//
// Getting it wrong fails SILENTLY. netprobe stamps the stale address as the
// subject of every process snapshot, core matches it against no device, and the
// enrichment-only rule correctly drops the payload -- so nothing errors, nothing
// warns, and the schema simply never appears.
func (p *PushLoop) stampCollectorIP(cfg *netprobepb.VisibilityAgentConfig) {
	if cfg == nil {
		return
	}

	cfg.CollectorIp = p.getSourceIP()
}

func (p *PushLoop) applyVisibilityConfig(
	ctx context.Context,
	cfg *proto.VisibilityConfig,
	addons []*proto.AddonAssignmentConfig,
) (addonDeliveryDisposition, error) {
	if p.server == nil {
		return addonDeliverySucceeded, nil
	}
	addons = p.filterUnsupportedHostVisibilityAssignments(addons)
	if !p.hostSupportsNetworkVisibility() {
		p.server.mu.RLock()
		netprobeSidecar := p.server.netprobeSidecar
		sidecarManager := p.server.sidecarManager
		p.server.mu.RUnlock()
		if sidecarManager != nil {
			p.stopNetprobeManager(ctx, sidecarManager, "host network visibility unsupported")
		}
		if netprobeSidecar != nil {
			netprobeSidecar.SetDesiredConfig(ctx, nil)
		}
		p.logger.Info().Msg("Host network visibility unsupported; netprobe attach state cleared")

		return addonDeliverySucceeded, nil
	}
	if cfg == nil {
		if addon := netprobeSystemdAssignment(addons); addon != nil {
			return addonDeliveryPermanentFailure, &addonConfigApplyError{
				addonID: addon.GetAddonId(),
				err:     errNetprobeVisibilityConfigMissing,
			}
		}

		return addonDeliverySucceeded, nil
	}

	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	sidecarManager := p.server.sidecarManager
	sidecarStatus := p.server.sidecarStatus
	p.server.mu.RUnlock()
	if netprobeSidecar == nil || sidecarManager == nil {
		return addonDeliverySucceeded, nil
	}

	parsed := agentnetprobe.ParseVisibilityConfig(cfg)

	// Stamped from the agent's own view of where it is, not from the gateway payload:
	// this is runtime context about WHERE netprobe is running, and the agent is
	// the only thing that knows it. netprobe cannot derive it -- picking an
	// address off a capture interface would be a guess that disagrees with the
	// identity the agent already reports under -- and core has no attested
	// collector address either. Without it netprobe cannot choose a DPI event's
	// subject endpoint or name the host a process snapshot describes.
	//
	// Set after the gateway parse and before the add-on JSON merge, so an
	// operator cannot override it with a different host's address.
	//
	// getSourceIP(), NOT config.HostIP. `host_ip` in agent.json is a bootstrap
	// pin written at onboard time, and a re-IP'd host leaves it pointing at an
	// address that is no longer on any local interface. getSourceIP() keeps the
	// pin only while it is still live and otherwise re-detects -- which is what
	// every other outbound path already uses (Hello, PushStatus, SNMP, plugin
	// signals, workload identity). Reading the raw pin here made netprobe label
	// DPI subjects and process snapshots with a stale address: on a lab host
	// whose pin said 192.168.2.243 while the interface held 192.168.1.171,
	// nothing matched, and every process snapshot was correctly dropped by the
	// enrichment-only rule for naming a device that does not exist.
	p.stampCollectorIP(parsed.NetprobeConfig)

	netprobeAddon := netprobeSystemdAssignment(addons)
	systemdManaged := netprobeAddon != nil
	if systemdManaged {
		merged, err := agentnetprobe.ApplyAddonConfigJSON(
			parsed.NetprobeConfig,
			netprobeAddon.GetConfigJson(),
		)
		if err != nil {
			// A malformed add-on config JSON is structurally fixed for this version, so it
			// fails identically on every resend: permanent (record, do not defer). The
			// failure is attributed to the netprobe add-on so the fleet view shows it as
			// unhealthy instead of running-on-bootstrap-config reading as healthy.
			return addonDeliveryPermanentFailure, &addonConfigApplyError{
				addonID: netprobeAddon.GetAddonId(),
				err:     fmt.Errorf("merge netprobe add-on config: %w", err),
			}
		}
		parsed.NetprobeConfig = merged
	}

	if systemdManaged {
		if err := agentnetprobe.WriteBootstrapConfig(
			netprobeConfigPath(sidecarStatus),
			parsed.NetprobeConfig,
		); err != nil {
			// Bootstrap I/O failures are environmental (mount/permission/disk state) and may
			// clear without a payload change. Defer and retry while activation remains blocked
			// so netprobe never restarts against stale startup config.
			return addonDeliveryTransientFailure, &addonConfigApplyError{
				addonID: netprobeAddon.GetAddonId(),
				err:     fmt.Errorf("write netprobe bootstrap config: %w", err),
			}
		}
		return p.applyVisibilityConfigSystemd(ctx, netprobeSidecar, sidecarManager, parsed.NetprobeConfig)
	}

	p.stopNetprobeManager(ctx, sidecarManager, "netprobe add-on assignment absent")
	netprobeSidecar.SetDesiredConfig(ctx, nil)
	p.logger.Info().Msg("Netprobe add-on assignment absent; attach manager stopped")

	return addonDeliverySucceeded, nil
}

// applyVisibilityConfigSystemd handles netprobe delivered as a systemd-service add-on: systemd
// owns the process, so the agent attaches (connects for health + event ingest, never launching)
// and hands the config to the sidecar, which (re)applies it over IPC on every (re)connect. It
// accepts a not-yet-running netprobe: the unit is installed later in this same config apply
// and the full config is delivered once it connects. Starting the attach lifecycle itself must
// succeed first; otherwise the visibility section defers and systemd activation remains blocked.
func (p *PushLoop) applyVisibilityConfigSystemd(
	ctx context.Context,
	netprobeSidecar *agentnetprobe.Sidecar,
	sidecarManager sidecarLifecycleManager,
	cfg *netprobepb.VisibilityAgentConfig,
) (addonDeliveryDisposition, error) {
	if started, _ := sidecarManager.Mode(); !started {
		if err := sidecarManager.StartAttach(ctx); err != nil && !errors.Is(err, agentnetprobe.ErrAttachManagerStarted) {
			p.logger.Error().Err(err).Msg("Failed to start netprobe attach manager")

			return addonDeliveryTransientFailure, &addonConfigApplyError{
				addonID: agentnetprobe.DefaultSidecarName,
				err:     fmt.Errorf("start netprobe attach manager: %w", err),
			}
		}
	}

	netprobeSidecar.SetDesiredConfig(ctx, cfg)
	p.logger.Info().
		Bool("enabled", cfg.GetEnabled()).
		Int("device_bindings", len(cfg.GetDeviceBindings())).
		Msg("Netprobe is systemd-managed; attached and handed desired visibility config")

	return addonDeliverySucceeded, nil
}

// stopNetprobeManager stops the sidecar manager (best-effort, bounded) so it can be restarted
// after the netprobe add-on assignment is removed.
func (p *PushLoop) stopNetprobeManager(ctx context.Context, sidecarManager sidecarLifecycleManager, reason string) {
	if started, _ := sidecarManager.Mode(); !started {
		return
	}
	stopCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := sidecarManager.Stop(stopCtx); err != nil {
		p.logger.Warn().Err(err).Str("reason", reason).Msg("Failed to stop netprobe attach manager")
	}
}

// netprobeSystemdAssignmentPresent reports whether the gateway config carries an enabled
// netprobe AddonAssignment with systemd supervision — the switch that enables the
// systemd-service add-on lifecycle and agent attach loop.
func netprobeSystemdAssignmentPresent(addons []*proto.AddonAssignmentConfig) bool {
	return netprobeSystemdAssignment(addons) != nil
}

func netprobeSystemdAssignment(addons []*proto.AddonAssignmentConfig) *proto.AddonAssignmentConfig {
	for _, addon := range addons {
		if addon == nil {
			continue
		}
		if addon.GetAddonId() == agentnetprobe.DefaultSidecarName &&
			addon.GetEnabled() &&
			classifyAddonSupervision(addon.GetSupervision()) == addonDispatchSystemd {
			return addon
		}
	}

	return nil
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
