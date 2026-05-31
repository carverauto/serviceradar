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
	"path/filepath"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/proto"
)

// addonCapabilities returns the capability identifiers advertised by add-ons that
// are currently running, so the control plane can reconcile active add-ons.
func addonCapabilities(statuses []agentaddon.Status) []string {
	var capabilities []string
	for _, status := range statuses {
		if status.State != agentaddon.StateRunning {
			continue
		}
		capabilities = append(capabilities, status.Capabilities...)
	}
	return capabilities
}

// Add-on delivery/supervision identifiers carried in AddonAssignmentConfig.
// These mirror the control-plane Ash enums.
const (
	addonDeliveryPushedArtifact = "pushed_artifact"

	addonSupervisionAgentSidecar    = "agent_sidecar"
	addonSupervisionConfigToggle    = "config_toggle"
	addonSupervisionSystemdService  = "systemd_service"
	addonSupervisionSystemdTimer    = "systemd_timer"
	addonSupervisionEphemeralHelper = "ephemeral_helper"
)

// addonDispatch classifies how the agent handles an assignment's supervision model.
type addonDispatch int

const (
	// addonDispatchSidecar: run as a supervised go-plugin subprocess.
	addonDispatchSidecar addonDispatch = iota
	// addonDispatchConfigToggle: a capability compiled into the agent; the assignment
	// only selects it, and the capability self-configures from agent config, so there
	// is nothing for the add-on supervisor to launch.
	addonDispatchConfigToggle
	// addonDispatchExternalUnimplemented: a recognized model (systemd-*/ephemeral) that
	// this agent build does not yet manage.
	addonDispatchExternalUnimplemented
	// addonDispatchUnsupported: an unknown supervision model.
	addonDispatchUnsupported
)

// classifyAddonSupervision maps a supervision model to how this agent dispatches it.
func classifyAddonSupervision(supervision string) addonDispatch {
	switch supervision {
	case addonSupervisionAgentSidecar:
		return addonDispatchSidecar
	case addonSupervisionConfigToggle:
		return addonDispatchConfigToggle
	case addonSupervisionSystemdService, addonSupervisionSystemdTimer, addonSupervisionEphemeralHelper:
		return addonDispatchExternalUnimplemented
	default:
		return addonDispatchUnsupported
	}
}

// rememberAddonSpec records a freshly staged, fully verified add-on spec as the
// last-known-good for its id, so a later transient delivery failure can reuse it.
func (p *PushLoop) rememberAddonSpec(spec agentaddon.Spec) {
	p.addonLastGoodMu.Lock()
	defer p.addonLastGoodMu.Unlock()

	if p.addonLastGood == nil {
		p.addonLastGood = make(map[string]agentaddon.Spec)
	}

	p.addonLastGood[spec.ID] = spec
}

// lastGoodAddonSpec returns the last-known-good spec for an add-on id, if any.
func (p *PushLoop) lastGoodAddonSpec(id string) (agentaddon.Spec, bool) {
	p.addonLastGoodMu.Lock()
	defer p.addonLastGoodMu.Unlock()

	spec, ok := p.addonLastGood[id]

	return spec, ok
}

// pruneAddonCache drops last-known-good entries for add-on ids not in keep, so a
// removed add-on does not retain a stale spec that a later re-add could fall back to.
func (p *PushLoop) pruneAddonCache(keep map[string]bool) {
	p.addonLastGoodMu.Lock()
	defer p.addonLastGoodMu.Unlock()

	for id := range p.addonLastGood {
		if !keep[id] {
			delete(p.addonLastGood, id)
		}
	}
}

// applyAddonAssignments reconciles the agent's supervised native add-ons to the
// assignments delivered in the gateway config. Enabled assignments are launched
// and supervised as go-plugin subprocesses; disabled or removed ones are stopped.
func (p *PushLoop) applyAddonAssignments(ctx context.Context, assignments []*proto.AddonAssignmentConfig) {
	if p.server == nil {
		return
	}

	p.server.mu.RLock()
	manager := p.server.addonManager
	configDir := p.server.configDir
	p.server.mu.RUnlock()
	if manager == nil {
		return
	}

	// Merge an operator-managed local override (break-glass / dev) over the pushed
	// assignments before reconciling. A malformed file is ignored so a bad local edit
	// cannot break pushed delivery. Skip when no config dir is known (avoid reading a
	// relative path from the process working directory).
	if configDir != "" {
		overridePath := addonLocalOverridePath(configDir)
		if merged, err := applyLocalAddonOverrides(assignments, overridePath); err != nil {
			p.logger.Warn().
				Err(err).
				Str("path", overridePath).
				Msg("Ignoring malformed local add-on override file")
		} else {
			assignments = merged
		}
	}

	specs := make([]agentaddon.Spec, 0, len(assignments))
	for _, a := range assignments {
		if a == nil || !a.GetEnabled() {
			continue
		}

		// Default to the only delivery/supervision pair this agent implements so
		// an older control plane that omits these fields keeps working.
		delivery := a.GetDelivery()
		if delivery == "" {
			delivery = addonDeliveryPushedArtifact
		}
		supervision := a.GetSupervision()
		if supervision == "" {
			supervision = addonSupervisionAgentSidecar
		}

		// Dispatch by supervision model. Only agent_sidecar runs as a supervised
		// go-plugin subprocess; the others are recognized explicitly so a legitimate
		// model is not mislabeled "unsupported" and the desired-vs-observed gap is
		// honest.
		switch classifyAddonSupervision(supervision) {
		case addonDispatchSidecar:
			// Handled below: stage (if needed) and build a supervised spec.
		case addonDispatchConfigToggle:
			// Compiled-in capability selected by this assignment; it self-configures
			// from agent config, so there is nothing for the supervisor to launch.
			p.logger.Info().
				Str("addon", a.GetAddonId()).
				Msg("Config-toggle add-on acknowledged; capability is compiled into the agent")

			continue
		case addonDispatchExternalUnimplemented:
			p.logger.Warn().
				Str("addon", a.GetAddonId()).
				Str("delivery", delivery).
				Str("supervision", supervision).
				Msg("Add-on supervision model recognized but not yet implemented by this agent; assignment not applied")

			continue
		case addonDispatchUnsupported:
			p.logger.Warn().
				Str("addon", a.GetAddonId()).
				Str("delivery", delivery).
				Str("supervision", supervision).
				Msg("Add-on supervision model not supported by this agent; assignment not applied")

			continue
		}

		binaryPath := a.GetBinaryPath()
		freshlyStaged := false

		// For pushed_artifact delivery, fetch + verify + stage the signed artifact
		// from object storage and run the resolved staged binary. compiled_in /
		// os_package rely on binary_path already being present on the host.
		if delivery == addonDeliveryPushedArtifact && a.GetArtifactObjectKey() != "" {
			p.server.mu.RLock()
			store := p.server.objectStore
			p.server.mu.RUnlock()

			root := resolveAddonArtifactRoot("")
			addonDir := filepath.Join(root, a.GetAddonId())
			// Capture the currently-active version before staging so a failed
			// capability application can roll `current` back to it.
			priorTarget, _ := readAddonCurrentTarget(addonDir)

			resolved, err := stageAddonArtifact(ctx, store, root, a)
			if err != nil {
				// Delivery/verification failed. Reuse the cached last-known-good spec
				// so a running add-on keeps running exactly as it was (same binary,
				// args, and config) rather than pairing an old binary with new config.
				// A running add-on always has a cache entry (set when it last staged
				// successfully); with no entry the add-on was not running here, so skip
				// it until delivery succeeds rather than guess at an on-disk binary.
				cached, hit := p.lastGoodAddonSpec(a.GetAddonId())
				if !hit {
					p.logger.Warn().
						Err(err).
						Str("addon", a.GetAddonId()).
						Str("object_key", a.GetArtifactObjectKey()).
						Msg("Failed to stage pushed-artifact add-on and no last-known-good assignment; not applied")

					continue
				}

				p.logger.Warn().
					Err(err).
					Str("addon", a.GetAddonId()).
					Msg("Pushed-artifact add-on delivery failed; keeping last-known-good assignment")

				specs = append(specs, cached)

				continue
			}

			if a.GetArtifactSignature() == "" {
				p.logger.Warn().
					Str("addon", a.GetAddonId()).
					Msg("Pushed-artifact add-on activated without a signature (artifact signing pending build pipeline)")
			}

			// Apply the manifest's declared Linux file capabilities to the freshly
			// staged binary via the root-owned agent-updater (the non-root agent never
			// applies them itself). On failure, roll `current` back to the prior version
			// so we never launch a new binary without its required capabilities, and
			// fall back to the last-known-good assignment.
			if caps := a.GetOsCapabilities(); len(caps) > 0 {
				if capErr := applyStagedAddonCapabilitiesViaUpdater(ctx, a.GetAddonId(), addonBinaryName(a), caps); capErr != nil {
					if rbErr := rollbackAddonCurrent(root, a.GetAddonId(), priorTarget); rbErr != nil {
						p.logger.Error().
							Err(rbErr).
							Str("addon", a.GetAddonId()).
							Msg("Failed to roll back add-on after capability application failure")
					}

					cached, hit := p.lastGoodAddonSpec(a.GetAddonId())
					if !hit {
						p.logger.Warn().
							Err(capErr).
							Str("addon", a.GetAddonId()).
							Msg("Failed to apply add-on capabilities and no last-known-good assignment; not applied")

						continue
					}

					p.logger.Warn().
						Err(capErr).
						Str("addon", a.GetAddonId()).
						Msg("Add-on capability application failed; rolled back and kept last-known-good assignment")

					specs = append(specs, cached)

					continue
				}
			}

			binaryPath = resolved
			freshlyStaged = true
		}

		if binaryPath == "" {
			p.logger.Warn().
				Str("addon", a.GetAddonId()).
				Str("delivery", delivery).
				Msg("Add-on sidecar assignment missing a binary path; not applied")
			continue
		}

		spec := agentaddon.Spec{
			ID:           a.GetAddonId(),
			Version:      a.GetVersion(),
			BinaryPath:   binaryPath,
			Args:         a.GetArgs(),
			ConfigJSON:   a.GetConfigJson(),
			Capabilities: a.GetCapabilities(),
		}

		// Cache the fully verified, freshly staged spec as last-known-good so a later
		// transient delivery failure can reuse it unchanged.
		if freshlyStaged {
			p.rememberAddonSpec(spec)
		}

		specs = append(specs, spec)
	}

	// Evict last-known-good cache entries for add-ons no longer assigned, so a removed
	// then re-added add-on cannot fall back to a stale spec on a transient failure.
	present := make(map[string]bool, len(assignments))
	for _, a := range assignments {
		if a != nil {
			present[a.GetAddonId()] = true
		}
	}
	p.pruneAddonCache(present)

	if err := manager.Apply(ctx, specs); err != nil {
		p.logger.Error().Err(err).Int("addons", len(specs)).Msg("Failed to apply add-on assignments")
		return
	}

	if len(specs) > 0 {
		p.logger.Info().Int("addons", len(specs)).Msg("Applied native add-on assignments")
	}
}
