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
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
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
	addonDeliveryPushedArtifact  = "pushed_artifact"
	defaultNetprobeIPCSocketPath = "/run/serviceradar/netprobe/ipc.sock"

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
	// addonDispatchEphemeral: stage + capability-grant a one-shot helper binary and make
	// it available (by resolved path) for on-demand invocation by its consumer (e.g.
	// remote-access spawns it per session); the agent does not run or supervise it.
	addonDispatchEphemeral
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
		return addonDispatchEphemeral
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

	// When the control plane supplied a gateway download_url, fetch the artifact over
	// HTTPS through the agent-gateway artifact endpoint instead of touching the object
	// store directly. External agents (no kv_address, hence no objectStore) rely on
	// this path. Verification (sha256 + ed25519
	// signature) is applied to the fetched bytes regardless of which path produced them.
	httpClient := p.gatewayAddonHTTPClient(a)

	root := resolveAddonArtifactRoot("")
	addonDir := filepath.Join(root, a.GetAddonId())
	// Capture the currently-active version before staging so a failed capability
	// application can roll `current` back to it.
	priorTarget, _ := readAddonCurrentTarget(addonDir)

	resolved, err := stageAddonArtifactWithClient(ctx, store, httpClient, root, a)
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

// gatewayAddonHTTPClient returns the mTLS HTTPS client used to fetch a pushed-artifact
// add-on through the agent-gateway artifact endpoint, or nil when the assignment has
// no gateway download_url (the direct object-store path is used instead).
func (p *PushLoop) gatewayAddonHTTPClient(a *proto.AddonAssignmentConfig) *http.Client {
	if strings.TrimSpace(a.GetDownloadUrl()) == "" {
		return nil
	}

	return p.gatewayArtifactDownloadHTTPClient(a.GetDownloadUrl())
}

func (p *PushLoop) gatewayArtifactDownloadHTTPClient(downloadURL string) *http.Client {
	if strings.TrimSpace(downloadURL) == "" {
		return nil
	}
	if p == nil || p.server == nil || p.server.config == nil {
		if !gatewayArtifactDownloadRequiresMTLS(downloadURL) {
			return defaultGatewayArtifactHTTPClient()
		}
		return nil
	}

	if !gatewayArtifactDownloadRequiresMTLS(downloadURL) {
		return defaultGatewayArtifactHTTPClient()
	}

	return p.server.gatewayArtifactHTTPClient()
}

func gatewayArtifactDownloadRequiresMTLS(downloadURL string) bool {
	parsed, err := url.Parse(strings.TrimSpace(downloadURL))
	if err != nil {
		return true
	}

	return strings.EqualFold(parsed.Scheme, httpsScheme)
}

// errAddonAssignmentsDeferred is the section-level error reported when one or more
// add-on assignments failed transiently this cycle (the version defers and retries).
var errAddonAssignmentsDeferred = errors.New("one or more add-on assignments had transient delivery failures")

// errAddonAssignmentsPermanent is the section-level error wrapped around the aggregated
// per-add-on permanent delivery failures reported on the config ack.
var errAddonAssignmentsPermanent = errors.New("one or more add-on assignments failed permanently")

// applyAddonAssignments reconciles the agent's native add-ons to the assignments
// delivered in the gateway config. agent-sidecar add-ons are launched as supervised
// go-plugin subprocesses; systemd-service/systemd-timer add-ons are installed + enabled
// via the root-owned agent-updater; disabled or removed ones are stopped/uninstalled.
//
// The returned disposition follows the section failure model: transient delivery
// failures defer the config-version ack (retry next cycle); permanent per-add-on
// failures are recorded + backed off and reported in the section status without
// blocking the ack; everything else is a success.
func (p *PushLoop) applyAddonAssignments(
	ctx context.Context,
	assignments []*proto.AddonAssignmentConfig,
) (addonDeliveryDisposition, error) {
	return p.applyAddonAssignmentsWithActivationBlocks(ctx, assignments, nil)
}

// applyAddonAssignmentsWithActivationBlocks preserves blocked systemd add-ons as desired
// without starting or restarting them. The visibility section uses this when netprobe's
// startup config failed, allowing unrelated add-ons to reconcile against the same response
// while netprobe remains on its last-known-good runtime.
func (p *PushLoop) applyAddonAssignmentsWithActivationBlocks(
	ctx context.Context,
	assignments []*proto.AddonAssignmentConfig,
	activationBlocks map[string]bool,
) (addonDeliveryDisposition, error) {
	return p.applyEffectiveAddonAssignmentsWithActivationBlocks(
		ctx,
		p.effectiveAddonAssignments(assignments),
		activationBlocks,
	)
}

// effectiveAddonAssignments resolves the operator-managed local override once so every
// consumer of a gateway response (notably visibility and native add-on reconciliation)
// makes lifecycle decisions from the same assignment set.
func (p *PushLoop) effectiveAddonAssignments(
	assignments []*proto.AddonAssignmentConfig,
) []*proto.AddonAssignmentConfig {
	if p == nil {
		return assignments
	}
	effective := assignments
	if p.server == nil {
		return p.filterUnsupportedHostVisibilityAssignments(effective)
	}

	p.server.mu.RLock()
	configDir := p.server.configDir
	p.server.mu.RUnlock()
	if configDir != "" {
		overridePath := addonLocalOverridePath(configDir)
		merged, err := applyLocalAddonOverrides(assignments, overridePath)
		if err != nil {
			p.logger.Warn().
				Err(err).
				Str("path", overridePath).
				Msg("Ignoring malformed local add-on override file")
		} else {
			effective = merged
		}
	}

	return p.filterUnsupportedHostVisibilityAssignments(effective)
}

// filterUnsupportedHostVisibilityAssignments removes every netprobe assignment when the
// current host cannot safely provide eBPF host-network visibility. Filtering happens after
// local overrides are merged so neither a stale control-plane response nor an operator-local
// override can bypass the runtime capability boundary.
func (p *PushLoop) filterUnsupportedHostVisibilityAssignments(
	assignments []*proto.AddonAssignmentConfig,
) []*proto.AddonAssignmentConfig {
	if p.hostSupportsNetworkVisibility() {
		return assignments
	}

	filtered := make([]*proto.AddonAssignmentConfig, 0, len(assignments))
	for _, assignment := range assignments {
		if assignment != nil && strings.EqualFold(
			strings.TrimSpace(assignment.GetAddonId()),
			agentnetprobe.DefaultSidecarName,
		) {
			continue
		}
		filtered = append(filtered, assignment)
	}

	return filtered
}

// applyEffectiveAddonAssignmentsWithActivationBlocks reconciles an already-resolved
// assignment set. applyConfigResponse uses this after visibility has consumed the same
// effective assignments, preventing a local netprobe override from bypassing bootstrap
// ordering or activation blocking.
func (p *PushLoop) applyEffectiveAddonAssignmentsWithActivationBlocks(
	ctx context.Context,
	assignments []*proto.AddonAssignmentConfig,
	activationBlocks map[string]bool,
) (addonDeliveryDisposition, error) {
	assignments = p.filterUnsupportedHostVisibilityAssignments(assignments)
	if p.server == nil {
		return addonDeliverySucceeded, nil
	}

	p.server.mu.RLock()
	manager := p.server.addonManager
	serverConfig := p.server.config
	p.server.mu.RUnlock()
	if manager == nil {
		return addonDeliverySucceeded, nil
	}
	if serverConfig != nil && strings.EqualFold(strings.TrimSpace(serverConfig.AgentID), kubernetesAgentID) {
		if len(assignments) > 0 {
			p.logger.Info().
				Int("addons", len(assignments)).
				Str("agent_id", serverConfig.AgentID).
				Msg("Skipping native add-on assignments for Kubernetes agent")
		}
		return addonDeliverySucceeded, nil
	}

	// Serialize the whole reconcile: applyAddonAssignments is invoked from the
	// independent config-poll, control-stream, and enroll goroutines, and the systemd
	// install/track/uninstall sequence mutates shared state that must reconcile
	// atomically (the sidecar path is already atomic inside manager.Apply).
	p.addonReconcileMu.Lock()
	defer p.addonReconcileMu.Unlock()

	// Rehydrate systemd add-on tracking from the staging root once per process, so a
	// restart can still uninstall the units of an add-on that is later disabled/removed
	// (the in-memory map is otherwise empty after a restart).
	p.systemdRehydrateOnce.Do(p.rehydrateSystemdAddons)

	specs := make([]agentaddon.Spec, 0, len(assignments))
	desiredSystemd := make(map[string]bool)
	desiredEphemeral := make(map[string]bool)
	// blockAck stays true only while every assignment either succeeded or failed in a
	// way that may clear on its own (transient). A PERMANENT artifact-delivery failure
	// (404 not-found, sha mismatch, invalid signature, incomplete reference, …) is
	// recorded as per-add-on failure status and backed off, but does NOT block the
	// config-version ack: the assignment is broken upstream, so wedging the whole config
	// apply would only freeze every other config section behind a permanently-404ing
	// artifact (the live ns05 bug).
	blockAck := false
	now := time.Now()

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
			if spec, ok, disposition := p.buildSidecarAddonSpec(ctx, a, delivery, now); ok {
				specs = append(specs, spec)
				if disposition == addonDeliveryTransientFailure {
					blockAck = true
				}
			} else if disposition == addonDeliveryTransientFailure {
				blockAck = true
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
			if activationBlocks[a.GetAddonId()] {
				p.logger.Debug().
					Str("addon", a.GetAddonId()).
					Msg("Systemd add-on activation blocked until startup config applies")
				continue
			}
			if p.applySystemdAddon(ctx, a, delivery, supervision, now) == addonDeliveryTransientFailure {
				blockAck = true
			}
		case addonDispatchEphemeral:
			// Mark desired regardless of this round's outcome so a transient delivery
			// failure does not deregister a still-desired helper.
			desiredEphemeral[a.GetAddonId()] = true
			if p.applyEphemeralAddon(ctx, a, delivery, now) == addonDeliveryTransientFailure {
				blockAck = true
			}
		case addonDispatchUnsupported:
			// An unsupported supervision model is permanent (the agent will never grow
			// support mid-run), so record it and move on rather than wedging the ack.
			p.logger.Warn().
				Str("addon", a.GetAddonId()).
				Str("delivery", delivery).
				Str("supervision", supervision).
				Msg("Add-on supervision model not supported by this agent; assignment not applied")
			p.recordAddonDeliveryFailure(a, errAddonSupervisionUnsupported, now)
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
	// Drop delivery-failure records (and their backoff) for add-ons no longer assigned.
	p.pruneAddonDeliveryFailures(present)

	// Uninstall systemd units for add-ons that are no longer desired (disabled/removed).
	p.reconcileSystemdAddons(ctx, desiredSystemd)

	// Deregister ephemeral helpers that are no longer desired so consumers stop using
	// them (the staged binary stays on disk; there is nothing system-level to tear down).
	p.reconcileEphemeralHelpers(desiredEphemeral)

	if err := manager.Apply(ctx, specs); err != nil {
		// A supervisor apply failure is environmental (an exec/launch race, a busy
		// supervisor), not a structurally-broken assignment, so classify it TRANSIENT:
		// the version defers and the reconcile retries next cycle. It must not wedge the
		// apply pipeline — the caller keeps evaluating the remaining config sections.
		p.logger.Error().Err(err).Int("addons", len(specs)).Msg("Failed to apply add-on assignments")
		return addonDeliveryTransientFailure, fmt.Errorf("apply add-on assignments via supervisor: %w", err)
	}

	if len(specs) > 0 {
		p.logger.Info().Int("addons", len(specs)).Msg("Applied native add-on assignments")
	}

	// Only transient delivery failures defer the config-version ack. Permanent ones were
	// recorded as per-add-on failure status and backed off above, so the agent acks the
	// config version and stops re-applying the whole config every poll.
	if blockAck {
		return addonDeliveryTransientFailure, errAddonAssignmentsDeferred
	}

	// Surface still-standing permanent per-add-on failures as the section status carried
	// on the config ack (the per-add-on detail also rides the AddonStatus read model).
	if reason := p.assignedAddonPermanentFailureSummary(); reason != "" {
		return addonDeliveryPermanentFailure, fmt.Errorf("%w: %s", errAddonAssignmentsPermanent, reason)
	}

	return addonDeliverySucceeded, nil
}

// assignedAddonPermanentFailureSummary aggregates the recorded permanent delivery
// failures for currently-assigned add-ons into one human-readable reason string (empty
// when there are none). pruneAddonDeliveryFailures has already dropped unassigned ids.
func (p *PushLoop) assignedAddonPermanentFailureSummary() string {
	failures := p.addonDeliveryFailureSnapshot()
	if len(failures) == 0 {
		return ""
	}

	ids := make([]string, 0, len(failures))
	for id := range failures {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, id+": "+failures[id].reason)
	}

	return strings.Join(parts, "; ")
}

// buildSidecarAddonSpec stages an agent-sidecar add-on and returns its supervised
// go-plugin spec. On a delivery/capability failure it falls back to the last-known-good
// spec (so a running add-on keeps running unchanged) or, with no cached spec, skips it.
// The second returned bool reports whether a spec should be supervised. The third return
// is the delivery disposition: only a transient failure defers the config-version ack;
// a permanent failure (recorded + backed off in deliverAddonArtifact) keeps any running
// process alive on its last-known-good spec but lets the ack proceed.
func (p *PushLoop) buildSidecarAddonSpec(
	ctx context.Context,
	a *proto.AddonAssignmentConfig,
	delivery string,
	now time.Time,
) (agentaddon.Spec, bool, addonDeliveryDisposition) {
	freshlyStaged := delivery == addonDeliveryPushedArtifact && a.GetArtifactObjectKey() != ""

	binaryPath, disposition, err := p.deliverAddonArtifact(ctx, a, delivery, now)
	if err != nil {
		// Delivery/verification/capability failed (or is in backoff). Reuse the cached
		// last-known-good spec so a running add-on keeps running exactly as it was rather
		// than pairing an old binary with new config; with no cached spec the add-on was
		// not running here, so skip it until delivery succeeds.
		cached, hit := p.lastGoodAddonSpec(a.GetAddonId())
		if !hit {
			p.logSidecarDeliveryFailure(a, err, disposition,
				"Failed to deliver pushed-artifact add-on and no last-known-good assignment; not applied")

			return agentaddon.Spec{}, false, disposition
		}

		p.logSidecarDeliveryFailure(a, err, disposition,
			"Pushed-artifact add-on delivery failed; keeping last-known-good assignment")

		return cached, true, disposition
	}

	if binaryPath == "" {
		p.logger.Warn().
			Str("addon", a.GetAddonId()).
			Str("delivery", delivery).
			Msg("Add-on sidecar assignment missing a binary path; not applied")

		return agentaddon.Spec{}, false, addonDeliverySucceeded
	}

	spec := agentaddon.Spec{
		AssignmentID: a.GetAddonId(),
		ID:           a.GetAddonId(),
		Version:      a.GetVersion(),
		BinaryPath:   binaryPath,
		Args:         a.GetArgs(),
		ConfigJSON:   a.GetConfigJson(),
		Capabilities: a.GetCapabilities(),
		DownloadURL:  a.GetDownloadUrl(),
		Resources:    addonResourcesFromProto(a.GetResources()),
	}

	// Cache the fully verified, freshly staged spec as last-known-good so a later
	// transient delivery failure can reuse it unchanged.
	if freshlyStaged {
		p.rememberAddonSpec(spec)
	}

	return spec, true, addonDeliverySucceeded
}

// addonResourcesFromProto maps the manifest-declared resource limits delivered on
// the proto assignment to the supervisor's Resources struct. A nil message (no
// limits in the manifest) yields the zero value, which the supervisor treats as
// unbounded.
func addonResourcesFromProto(r *proto.AddonResources) agentaddon.Resources {
	if r == nil {
		return agentaddon.Resources{}
	}

	return agentaddon.Resources{
		CPUMaxPercent:   r.GetCpuMaxPercent(),
		MemoryMaxBytes:  r.GetMemoryMaxBytes(),
		MemoryHighBytes: r.GetMemoryHighBytes(),
		TasksMax:        int(r.GetTasksMax()),
		Slice:           r.GetSlice(),
	}
}

// logSidecarDeliveryFailure logs an add-on delivery failure at a severity matching its
// disposition: a permanent failure (404/sha/signature) is expected to recur until the
// artifact is fixed/uploaded, so it is logged at info to avoid warn-spam every poll,
// while a transient failure stays at warn.
func (p *PushLoop) logSidecarDeliveryFailure(
	a *proto.AddonAssignmentConfig,
	err error,
	disposition addonDeliveryDisposition,
	msg string,
) {
	event := p.logger.Warn()
	if disposition == addonDeliveryPermanentFailure {
		event = p.logger.Info()
	}
	event.
		Err(err).
		Str("addon", a.GetAddonId()).
		Bool("permanent", disposition == addonDeliveryPermanentFailure).
		Msg(msg)
}

// applySystemdAddon stages a systemd-supervised add-on and then installs + enables its
// bundled systemd units via the root-owned agent-updater. The unit files ride inside the
// signed staged bundle; the agent discovers them (reading its own staging area) and names
// them to the updater, which re-resolves + escape-guards each before installing. On a
// delivery, discovery, or install failure it rolls `current` back to the prior version
// and leaves any already-installed units untouched (reconciliation keeps them because the
// add-on is still desired).
func (p *PushLoop) applySystemdAddon(
	ctx context.Context,
	a *proto.AddonAssignmentConfig,
	delivery, supervision string,
	now time.Time,
) addonDeliveryDisposition {
	return p.applySystemdAddonAtRoot(
		ctx,
		a,
		delivery,
		supervision,
		now,
		"",
		p.systemdAddonRuntimeReady,
		p.deliverAddonArtifact,
		installStagedAddonSystemdUnitsViaUpdater,
	)
}

type systemdAddonRuntimeReadyFn func(context.Context, *proto.AddonAssignmentConfig, string) bool
type deliverAddonArtifactFn func(context.Context, *proto.AddonAssignmentConfig, string, time.Time) (string, addonDeliveryDisposition, error)

// applySystemdAddonAtRoot is the testable core of applySystemdAddon. Production always
// supplies the fixed runtime root and privileged updater; focused tests use a temporary
// staging root and recorder functions to verify the unchanged-vs-reconcile decision.
func (p *PushLoop) applySystemdAddonAtRoot(
	ctx context.Context,
	a *proto.AddonAssignmentConfig,
	delivery, supervision string,
	now time.Time,
	runtimeRoot string,
	runtimeReady systemdAddonRuntimeReadyFn,
	deliver deliverAddonArtifactFn,
	install installUnitsFn,
) addonDeliveryDisposition {
	if delivery == addonDeliveryPushedArtifact && a.GetArtifactObjectKey() != "" &&
		p.systemdAddonAssignmentCurrent(a, runtimeRoot) && runtimeReady(ctx, a, supervision) {
		p.logger.Debug().
			Str("addon", a.GetAddonId()).
			Str("version", a.GetVersion()).
			Msg("Systemd add-on already staged and installed; skipping unchanged package activation")
		p.clearAddonDeliveryFailure(a.GetAddonId())

		return addonDeliverySucceeded
	}

	root := resolveAddonArtifactRoot(runtimeRoot)
	priorTarget, _ := readAddonCurrentTarget(filepath.Join(root, a.GetAddonId()))

	if _, disposition, err := deliver(ctx, a, delivery, now); err != nil {
		p.logSidecarDeliveryFailure(a, err, disposition,
			"Systemd add-on delivery failed; leaving current state unchanged")

		return disposition
	}

	if err := applyStagedAddonRuntimeConfig(runtimeRoot, a); err != nil {
		if rbErr := rollbackAddonCurrent(root, a.GetAddonId(), priorTarget); rbErr != nil {
			p.logger.Error().Err(rbErr).Str("addon", a.GetAddonId()).Msg("Rollback failed after systemd add-on config write failure")
		}
		// A staged runtime-config write failure (e.g. ambiguous/missing config) will not
		// fix itself on the next poll; record it and let the ack proceed.
		disposition := classifyAddonDeliveryError(err)
		if disposition == addonDeliveryPermanentFailure {
			p.recordAddonDeliveryFailure(a, err, now)
		}
		p.logSidecarDeliveryFailure(a, err, disposition,
			"Systemd add-on config write failed; leaving current state unchanged")

		return disposition
	}

	if !p.reconcileStagedSystemdUnits(ctx, a, supervision, runtimeRoot, priorTarget, install) {
		// Unit discovery/install failure: treat as transient (the agent-updater may be
		// momentarily unavailable) so the ack defers and the install is retried promptly.
		return addonDeliveryTransientFailure
	}

	p.clearAddonDeliveryFailure(a.GetAddonId())

	return addonDeliverySucceeded
}

func (p *PushLoop) systemdAddonAssignmentCurrent(a *proto.AddonAssignmentConfig, runtimeRoot string) bool {
	addonID := strings.TrimSpace(a.GetAddonId())
	wantSHA := strings.ToLower(strings.TrimSpace(a.GetArtifactSha256()))
	if addonID == "" || wantSHA == "" || !safeAddonSegment(addonID) {
		return false
	}

	version := addonStagedVersion(a, wantSHA)
	if !safeAddonSegment(version) {
		return false
	}

	units := p.systemdAddonUnits(addonID)
	if len(units) == 0 {
		return false
	}

	root := resolveAddonArtifactRoot(runtimeRoot)
	addonDir := filepath.Join(root, addonID)
	versionDir := filepath.Join(addonDir, addonVersionsDir, version)

	binName := addonBinaryName(a)
	return stagedAddonArtifactCurrent(addonDir, versionDir, version, binName, wantSHA, a.GetArtifactSignature()) &&
		systemdAddonActivationCurrent(
			versionDir,
			version,
			binName,
			wantSHA,
			a.GetArtifactSignature(),
			addonAssignmentConfigSHA256(a.GetConfigJson()),
			units,
		)
}

// systemdAddonRuntimeReady reports whether the add-on's primary unit is active and any
// required runtime endpoint is present. The staged-artifact/activation-metadata checks in
// systemdAddonAssignmentCurrent only prove the bundle is on disk. In particular, legacy
// agent units can remove netprobe's shared runtime tree during an agent self-update while
// systemd still reports netprobe active. Requiring the IPC socket makes the new agent's
// next poll reinstall and restart netprobe through the old updater, healing each legacy-unit
// restart until a package upgrade permanently installs the agent service drop-in.
func (p *PushLoop) systemdAddonRuntimeReady(ctx context.Context, a *proto.AddonAssignmentConfig, supervision string) bool {
	units := p.systemdAddonUnits(a.GetAddonId())
	if len(units) == 0 {
		return false
	}

	enable, err := pickPrimarySystemdUnit(units, supervision)
	if err != nil || strings.TrimSpace(enable) == "" {
		return false
	}

	active := p.systemdAddonUnitReady(ctx, enable)
	if active && supervision == addonSupervisionSystemdTimer {
		// A waiting timer can look healthy while the last oneshot exec failed
		// (SELinux 203/EXEC). Treat that as not-ready so reconcile reinstalls
		// and relabels instead of skipping an unchanged package forever.
		for _, unit := range units {
			if !strings.HasSuffix(strings.TrimSpace(unit), ".service") {
				continue
			}
			if p.readSystemdAddonUnitStatus(unit).state == agentaddon.StateUnhealthy {
				active = false
				break
			}
		}
	}
	socketPath := ""
	if a.GetAddonId() == agentnetprobe.DefaultSidecarName && supervision == addonSupervisionSystemdService {
		socketPath = p.netprobeIPCSocketPath()
	}
	if systemdAddonRuntimeEndpointReady(active, a.GetAddonId(), supervision, socketPath) {
		return true
	}

	event := p.logger.Warn().
		Str("addon", a.GetAddonId()).
		Str("unit", enable)
	if active && socketPath != "" {
		event.Str("socket", socketPath).
			Msg("Add-on systemd unit is active but its IPC socket is missing; reconciling (reinstall + restart)")
	} else {
		event.Msg("Add-on systemd unit is missing or inactive; reconciling (reinstall + enable)")
	}

	return false
}

// systemdAddonUnitReady uses the same parsed timer health used by add-on status
// reporting. systemctl is-active alone treats elapsed timers and waiting timers
// without a finite next trigger as ready, preventing assignment reconciliation from
// repairing their schedules. Services retain the cheaper is-active probe.
func (p *PushLoop) systemdAddonUnitReady(ctx context.Context, unit string) bool {
	if strings.HasSuffix(strings.TrimSpace(unit), ".timer") {
		return p.readSystemdAddonUnitStatus(unit).state == agentaddon.StateRunning
	}

	return systemdUnitActive(ctx, unit)
}

func (p *PushLoop) netprobeIPCSocketPath() string {
	if p != nil && p.server != nil && p.server.sidecarStatus != nil {
		for _, status := range p.server.sidecarStatus.Status() {
			if status.Name == agentnetprobe.DefaultSidecarName && strings.TrimSpace(status.SocketPath) != "" {
				return strings.TrimSpace(status.SocketPath)
			}
		}
	}

	return defaultNetprobeIPCSocketPath
}

func systemdAddonRuntimeEndpointReady(active bool, addonID, supervision, socketPath string) bool {
	if !active {
		return false
	}
	if addonID != agentnetprobe.DefaultSidecarName || supervision != addonSupervisionSystemdService {
		return true
	}

	info, err := os.Stat(socketPath)
	return err == nil && info.Mode()&os.ModeSocket != 0
}

// systemdUnitActive reports whether a systemd unit is currently active. is-active is a
// non-privileged read, so the agent can probe host state directly; a missing unit file
// also reports inactive, so this catches both the never-installed and stopped cases.
func systemdUnitActive(ctx context.Context, unit string) bool {
	if validateAddonUnitName(unit) != nil {
		return false
	}

	checkCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	return runSystemctl(checkCtx, "is-active", "--quiet", unit) == nil
}

// installUnitsFn installs + enables an add-on's staged systemd units via the root-owned
// agent-updater. Indirected so reconcileStagedSystemdUnits's rollback paths are testable
// without the updater.
type installUnitsFn func(ctx context.Context, addonID string, units []string, enable string, resources agentaddon.Resources) error

// reconcileStagedSystemdUnits installs + enables the freshly staged add-on's systemd units
// and, on any discovery/selection/install failure, rolls `current` back to priorTarget so a
// failed activation never leaves a half-installed/enabled unit or a running-but-incapable
// process. install is indirected (installUnitsFn) so the failure->rollback paths are testable
// without the root-owned agent-updater; runtimeRoot is "" in production (the default staging
// root) and a temp dir under test.
func (p *PushLoop) reconcileStagedSystemdUnits(
	ctx context.Context,
	a *proto.AddonAssignmentConfig,
	supervision, runtimeRoot, priorTarget string,
	install installUnitsFn,
) bool {
	root := resolveAddonArtifactRoot(runtimeRoot)

	rollback := func(reason string, err error) {
		if rbErr := rollbackAddonCurrent(root, a.GetAddonId(), priorTarget); rbErr != nil {
			p.logger.Error().Err(rbErr).Str("addon", a.GetAddonId()).Msg("Rollback failed after " + reason)
		}
		p.logger.Warn().Err(err).Str("addon", a.GetAddonId()).Msg(reason)
	}

	units, err := discoverStagedAddonUnits(runtimeRoot, a.GetAddonId())
	if err != nil {
		rollback("could not enumerate staged systemd units; not applied", err)
		return false
	}
	if len(units) == 0 {
		rollback("no systemd units in staged bundle; not applied", ErrAddonSystemdNoUnitsDiscovered)
		return false
	}

	enable, err := pickPrimarySystemdUnit(units, supervision)
	if err != nil {
		rollback("could not select systemd unit to enable; not applied", err)
		return false
	}

	// Relabel here, in the agent, and not only inside the root-owned updater.
	//
	// The agent self-updates (the packaged /usr/local/bin/serviceradar-agent is a shim
	// that execs the staged release), but serviceradar-agent-updater is a setuid-root
	// binary owned by the RPM and is NEVER replaced by a release activation. A host
	// that has self-updated for months still runs whatever updater its original package
	// shipped, so a privileged fix added to the updater simply never arrives: hosts in
	// the field were still on the pre-1.4.39 updater, whose install path has no relabel
	// at all, leaving every staged binary var_lib_t and every start at 203/EXEC.
	//
	// The agent's own uid owns the staged tree and can relabel it, so doing it here
	// makes the fix travel with the component that actually updates. The updater still
	// relabels too when it is new enough; chcon is idempotent and both calls are
	// best-effort, so this is additive, never a regression on a host without SELinux.
	relabel := p.relabelStagedAddonExecutables
	if relabel == nil {
		relabel = relabelStagedAddonExecutables
	}
	relabel(runtimeRoot, a.GetAddonId())

	if err := install(ctx, a.GetAddonId(), units, enable, addonResourcesFromProto(a.GetResources())); err != nil {
		rollback("failed to install systemd add-on units; rolled back", err)
		return false
	}

	if wantSHA := strings.ToLower(strings.TrimSpace(a.GetArtifactSha256())); wantSHA != "" {
		version := addonStagedVersion(a, wantSHA)
		if err := writeAddonSystemdActivationMetadata(filepath.Join(root, a.GetAddonId(), addonVersionsDir, version), addonSystemdActivationMetadata{
			AddonID:        a.GetAddonId(),
			Version:        version,
			BinaryName:     addonBinaryName(a),
			ArtifactSHA256: wantSHA,
			Signature:      strings.TrimSpace(a.GetArtifactSignature()),
			ConfigSHA256:   addonAssignmentConfigSHA256(a.GetConfigJson()),
			Units:          units,
			Enable:         enable,
		}); err != nil {
			p.rememberSystemdAddon(a.GetAddonId(), units)
			p.logger.Warn().
				Err(err).
				Str("addon", a.GetAddonId()).
				Msg("Installed systemd add-on but failed to record durable activation metadata; will retry activation")
			return false
		}
	}

	// If an update renamed or dropped unit files, uninstall the previously-installed
	// units the new bundle no longer ships so they do not leak on the host.
	if stale := stringsNotIn(p.systemdAddonUnits(a.GetAddonId()), units); len(stale) > 0 {
		if err := uninstallAddonSystemdUnitsViaUpdater(ctx, stale); err != nil {
			p.logger.Warn().
				Err(err).
				Str("addon", a.GetAddonId()).
				Strs("units", stale).
				Msg("Failed to remove stale systemd units after add-on update")
		}
	}

	p.rememberSystemdAddon(a.GetAddonId(), units)
	p.logger.Info().
		Str("addon", a.GetAddonId()).
		Str("enable", enable).
		Int("units", len(units)).
		Msg("Installed systemd add-on")

	return true
}

// systemdAddonUnits returns the unit names currently tracked as installed for an add-on.
func (p *PushLoop) systemdAddonUnits(id string) []string {
	p.systemdAddonsMu.Lock()
	defer p.systemdAddonsMu.Unlock()

	return p.installedSystemdAddons[id]
}

// rehydrateSystemdAddons repopulates the in-memory installed-systemd-units tracking from
// the on-disk staging root (each add-on's current/ dir), so after an agent restart the
// reconciler still knows which add-ons own systemd units and can uninstall them when an
// assignment is later disabled or removed.
func (p *PushLoop) rehydrateSystemdAddons() {
	p.rehydrateSystemdAddonsFromRoot(resolveAddonArtifactRoot(""))
}

func (p *PushLoop) rehydrateSystemdAddonsFromRoot(addonsRoot string) {
	discovered := discoverInstalledSystemdAddons(addonsRoot)
	if len(discovered) == 0 {
		return // no staging root / no systemd add-ons to rehydrate
	}

	p.systemdAddonsMu.Lock()
	defer p.systemdAddonsMu.Unlock()

	if p.installedSystemdAddons == nil {
		p.installedSystemdAddons = make(map[string][]string)
	}
	for id, units := range discovered {
		if _, exists := p.installedSystemdAddons[id]; !exists {
			p.installedSystemdAddons[id] = units
		}
	}
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
		uninstall := p.uninstallSystemdAddonUnits
		if uninstall == nil {
			uninstall = uninstallAddonSystemdUnitsViaUpdater
		}
		if err := uninstall(ctx, units); err != nil {
			p.logger.Error().Err(err).Str("addon", id).Msg("Failed to uninstall systemd add-on units")
			continue
		}

		p.systemdAddonsMu.Lock()
		delete(p.installedSystemdAddons, id)
		p.systemdAddonsMu.Unlock()

		p.logger.Info().Str("addon", id).Int("units", len(units)).Msg("Uninstalled systemd add-on (no longer assigned)")
	}
}

// applyEphemeralAddon stages an ephemeral-helper add-on (a one-shot binary the agent does
// not run itself) and registers its resolved path so the consuming subsystem (e.g.
// remote-access spawning rdp-adapter per session) can look it up. On a delivery/capability
// failure it leaves any previously-registered path in place (the add-on stays desired, so
// reconciliation will not deregister it) and retries on the next round.
func (p *PushLoop) applyEphemeralAddon(
	ctx context.Context,
	a *proto.AddonAssignmentConfig,
	delivery string,
	now time.Time,
) addonDeliveryDisposition {
	resolved, disposition, err := p.deliverAddonArtifact(ctx, a, delivery, now)
	if err != nil {
		p.logSidecarDeliveryFailure(a, err, disposition,
			"Ephemeral-helper add-on delivery failed; leaving current state unchanged")

		return disposition
	}

	if resolved == "" {
		p.logger.Warn().
			Str("addon", a.GetAddonId()).
			Str("delivery", delivery).
			Msg("Ephemeral-helper add-on missing a binary path; not applied")

		return addonDeliverySucceeded
	}

	p.rememberEphemeralHelper(a.GetAddonId(), resolved)
	p.logger.Info().
		Str("addon", a.GetAddonId()).
		Str("path", resolved).
		Msg("Staged ephemeral-helper add-on (available for on-demand invocation)")

	return addonDeliverySucceeded
}

// rememberEphemeralHelper records the resolved binary path of a staged ephemeral-helper
// add-on so consumers can resolve it by id.
func (p *PushLoop) rememberEphemeralHelper(id, path string) {
	p.ephemeralHelpersMu.Lock()
	defer p.ephemeralHelpersMu.Unlock()

	if p.availableEphemeralHelpers == nil {
		p.availableEphemeralHelpers = make(map[string]string)
	}
	p.availableEphemeralHelpers[id] = path
}

// reconcileEphemeralHelpers deregisters ephemeral helpers that are no longer desired
// (assignment disabled/removed), so a consumer no longer resolves a stale path. The
// staged binary is left on disk (harmless; nothing system-level was installed).
func (p *PushLoop) reconcileEphemeralHelpers(desired map[string]bool) {
	p.ephemeralHelpersMu.Lock()
	defer p.ephemeralHelpersMu.Unlock()

	for id := range p.availableEphemeralHelpers {
		if !desired[id] {
			delete(p.availableEphemeralHelpers, id)
			p.logger.Info().Str("addon", id).Msg("Deregistered ephemeral-helper add-on (no longer assigned)")
		}
	}
}

// EphemeralHelperPath returns the resolved staged binary path for an ephemeral-helper
// add-on, if one is currently available. Consumers (e.g. remote-access) use it to invoke
// the helper on demand.
func (p *PushLoop) EphemeralHelperPath(id string) (string, bool) {
	p.ephemeralHelpersMu.Lock()
	defer p.ephemeralHelpersMu.Unlock()

	path, ok := p.availableEphemeralHelpers[id]

	return path, ok
}
