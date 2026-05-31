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
	// addonDispatchSystemd: install + enable the add-on's bundled systemd units
	// (service/timer) via the root-owned agent-updater; not an agent subprocess.
	addonDispatchSystemd
	// addonDispatchExternalUnimplemented: a recognized model (ephemeral-helper) that
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
	case addonSupervisionSystemdService, addonSupervisionSystemdTimer:
		return addonDispatchSystemd
	case addonSupervisionEphemeralHelper:
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

// stageAndCapability stages a pushed-artifact add-on (fetch + verify + versioned stage +
// atomic current symlink) and applies its declared Linux file capabilities to the staged
// binary via the root-owned agent-updater, rolling `current` back to the prior version if
// capability application fails. It returns the resolved binary path; for non-pushed
// delivery it returns the assignment's binary_path unchanged. A non-nil error means the
// add-on must not be (re)activated this round; the caller decides the fallback for its
// supervision model.
func (p *PushLoop) stageAndCapability(ctx context.Context, a *proto.AddonAssignmentConfig, delivery string) (string, error) {
	// compiled_in / os_package rely on binary_path already being present on the host.
	if delivery != addonDeliveryPushedArtifact || a.GetArtifactObjectKey() == "" {
		return a.GetBinaryPath(), nil
	}

	p.server.mu.RLock()
	store := p.server.objectStore
	p.server.mu.RUnlock()

	root := resolveAddonArtifactRoot("")
	addonDir := filepath.Join(root, a.GetAddonId())
	// Capture the currently-active version before staging so a failed capability
	// application can roll `current` back to it.
	priorTarget, _ := readAddonCurrentTarget(addonDir)

	resolved, err := stageAddonArtifact(ctx, store, root, a)
	if err != nil {
		return "", err
	}

	if a.GetArtifactSignature() == "" {
		p.logger.Warn().
			Str("addon", a.GetAddonId()).
			Msg("Pushed-artifact add-on activated without a signature (artifact signing pending build pipeline)")
	}

	// Apply the manifest's declared Linux file capabilities to the freshly staged binary
	// via the root-owned agent-updater (the non-root agent never applies them itself).
	if caps := a.GetOsCapabilities(); len(caps) > 0 {
		if capErr := applyStagedAddonCapabilitiesViaUpdater(ctx, a.GetAddonId(), addonBinaryName(a), caps); capErr != nil {
			if rbErr := rollbackAddonCurrent(root, a.GetAddonId(), priorTarget); rbErr != nil {
				p.logger.Error().
					Err(rbErr).
					Str("addon", a.GetAddonId()).
					Msg("Failed to roll back add-on after capability application failure")
			}

			return "", capErr
		}
	}

	return resolved, nil
}

// applyAddonAssignments reconciles the agent's native add-ons to the assignments
// delivered in the gateway config. agent-sidecar add-ons are launched as supervised
// go-plugin subprocesses; systemd-service/systemd-timer add-ons are installed + enabled
// via the root-owned agent-updater; disabled or removed ones are stopped/uninstalled.
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
	desiredSystemd := make(map[string]bool)

	for _, a := range assignments {
		if a == nil || !a.GetEnabled() {
			continue
		}

		// Default to the only delivery/supervision pair older control planes omit.
		delivery := a.GetDelivery()
		if delivery == "" {
			delivery = addonDeliveryPushedArtifact
		}
		supervision := a.GetSupervision()
		if supervision == "" {
			supervision = addonSupervisionAgentSidecar
		}

		switch classifyAddonSupervision(supervision) {
		case addonDispatchSidecar:
			if spec, ok := p.buildSidecarAddonSpec(ctx, a, delivery); ok {
				specs = append(specs, spec)
			}
		case addonDispatchConfigToggle:
			// Compiled-in capability selected by this assignment; it self-configures
			// from agent config, so there is nothing for the supervisor to launch.
			p.logger.Info().
				Str("addon", a.GetAddonId()).
				Msg("Config-toggle add-on acknowledged; capability is compiled into the agent")
		case addonDispatchSystemd:
			// Mark desired regardless of this round's outcome so a transient delivery
			// failure does not cause a running unit to be uninstalled by reconciliation.
			desiredSystemd[a.GetAddonId()] = true
			p.applySystemdAddon(ctx, a, delivery, supervision)
		case addonDispatchExternalUnimplemented:
			p.logger.Warn().
				Str("addon", a.GetAddonId()).
				Str("delivery", delivery).
				Str("supervision", supervision).
				Msg("Add-on supervision model recognized but not yet implemented by this agent; assignment not applied")
		case addonDispatchUnsupported:
			p.logger.Warn().
				Str("addon", a.GetAddonId()).
				Str("delivery", delivery).
				Str("supervision", supervision).
				Msg("Add-on supervision model not supported by this agent; assignment not applied")
		}
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

	// Uninstall systemd units for add-ons that are no longer desired (disabled/removed).
	p.reconcileSystemdAddons(ctx, desiredSystemd)

	if err := manager.Apply(ctx, specs); err != nil {
		p.logger.Error().Err(err).Int("addons", len(specs)).Msg("Failed to apply add-on assignments")
		return
	}

	if len(specs) > 0 {
		p.logger.Info().Int("addons", len(specs)).Msg("Applied native add-on assignments")
	}
}

// buildSidecarAddonSpec stages an agent-sidecar add-on and returns its supervised
// go-plugin spec. On a delivery/capability failure it falls back to the last-known-good
// spec (so a running add-on keeps running unchanged) or, with no cached spec, skips it.
// The returned bool reports whether a spec should be supervised.
func (p *PushLoop) buildSidecarAddonSpec(ctx context.Context, a *proto.AddonAssignmentConfig, delivery string) (agentaddon.Spec, bool) {
	freshlyStaged := delivery == addonDeliveryPushedArtifact && a.GetArtifactObjectKey() != ""

	binaryPath, err := p.stageAndCapability(ctx, a, delivery)
	if err != nil {
		// Delivery/verification/capability failed. Reuse the cached last-known-good spec
		// so a running add-on keeps running exactly as it was rather than pairing an old
		// binary with new config; with no cached spec the add-on was not running here, so
		// skip it until delivery succeeds.
		cached, hit := p.lastGoodAddonSpec(a.GetAddonId())
		if !hit {
			p.logger.Warn().
				Err(err).
				Str("addon", a.GetAddonId()).
				Msg("Failed to deliver pushed-artifact add-on and no last-known-good assignment; not applied")

			return agentaddon.Spec{}, false
		}

		p.logger.Warn().
			Err(err).
			Str("addon", a.GetAddonId()).
			Msg("Pushed-artifact add-on delivery failed; keeping last-known-good assignment")

		return cached, true
	}

	if binaryPath == "" {
		p.logger.Warn().
			Str("addon", a.GetAddonId()).
			Str("delivery", delivery).
			Msg("Add-on sidecar assignment missing a binary path; not applied")

		return agentaddon.Spec{}, false
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

	return spec, true
}

// applySystemdAddon stages a systemd-supervised add-on and then installs + enables its
// bundled systemd units via the root-owned agent-updater. The unit files ride inside the
// signed staged bundle; the agent discovers them (reading its own staging area) and names
// them to the updater, which re-resolves + escape-guards each before installing. On a
// delivery, discovery, or install failure it rolls `current` back to the prior version
// and leaves any already-installed units untouched (reconciliation keeps them because the
// add-on is still desired).
func (p *PushLoop) applySystemdAddon(ctx context.Context, a *proto.AddonAssignmentConfig, delivery, supervision string) {
	root := resolveAddonArtifactRoot("")
	priorTarget, _ := readAddonCurrentTarget(filepath.Join(root, a.GetAddonId()))

	if _, err := p.stageAndCapability(ctx, a, delivery); err != nil {
		p.logger.Warn().
			Err(err).
			Str("addon", a.GetAddonId()).
			Msg("Systemd add-on delivery failed; leaving current state unchanged")

		return
	}

	rollback := func(reason string, err error) {
		if rbErr := rollbackAddonCurrent(root, a.GetAddonId(), priorTarget); rbErr != nil {
			p.logger.Error().Err(rbErr).Str("addon", a.GetAddonId()).Msg("Rollback failed after " + reason)
		}
		p.logger.Warn().Err(err).Str("addon", a.GetAddonId()).Msg(reason)
	}

	units, err := discoverStagedAddonUnits("", a.GetAddonId())
	if err != nil {
		rollback("could not enumerate staged systemd units; not applied", err)
		return
	}
	if len(units) == 0 {
		rollback("no systemd units in staged bundle; not applied", ErrAddonSystemdNoUnitsDiscovered)
		return
	}

	enable, err := pickPrimarySystemdUnit(units, supervision)
	if err != nil {
		rollback("could not select systemd unit to enable; not applied", err)
		return
	}

	if err := installStagedAddonSystemdUnitsViaUpdater(ctx, a.GetAddonId(), units, enable); err != nil {
		rollback("failed to install systemd add-on units; rolled back", err)
		return
	}

	p.rememberSystemdAddon(a.GetAddonId(), units)
	p.logger.Info().
		Str("addon", a.GetAddonId()).
		Str("enable", enable).
		Int("units", len(units)).
		Msg("Installed systemd add-on")
}

// rememberSystemdAddon records the units installed for a systemd-supervised add-on so
// reconciliation can uninstall them if the add-on is later disabled/removed.
func (p *PushLoop) rememberSystemdAddon(id string, units []string) {
	p.systemdAddonsMu.Lock()
	defer p.systemdAddonsMu.Unlock()

	if p.installedSystemdAddons == nil {
		p.installedSystemdAddons = make(map[string][]string)
	}
	p.installedSystemdAddons[id] = units
}

// reconcileSystemdAddons uninstalls the units of systemd add-ons that are no longer
// desired (disabled or unassigned), via the root-owned agent-updater.
func (p *PushLoop) reconcileSystemdAddons(ctx context.Context, desired map[string]bool) {
	p.systemdAddonsMu.Lock()
	toRemove := systemdAddonsToRemove(p.installedSystemdAddons, desired)
	p.systemdAddonsMu.Unlock()

	for id, units := range toRemove {
		if err := uninstallAddonSystemdUnitsViaUpdater(ctx, units); err != nil {
			p.logger.Error().Err(err).Str("addon", id).Msg("Failed to uninstall systemd add-on units")
			continue
		}

		p.systemdAddonsMu.Lock()
		delete(p.installedSystemdAddons, id)
		p.systemdAddonsMu.Unlock()

		p.logger.Info().Str("addon", id).Int("units", len(units)).Msg("Uninstalled systemd add-on (no longer assigned)")
	}
}
