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

package mapper

import (
	"context"
	"strings"
)

// runDiscoveryJob executes staged discovery with strict identity-before-topology ordering.
func (e *DiscoveryEngine) runDiscoveryJob(ctx context.Context, job *DiscoveryJob) {
	e.logger.Info().Str("job_id", job.ID).Strs("seeds", job.Params.Seeds).
		Str("type", string(job.Params.Type)).Str("mode", job.Params.Mode).Msg("Running discovery for job")

	recordStageTransition(job, DiscoveryStagePrepare, DiscoveryStageStatusStarted, "expanding seeds")
	initialSeeds := e.expandSeeds(job.Params.Seeds)
	if len(initialSeeds) == 0 {
		recordStageTransition(job, DiscoveryStagePrepare, DiscoveryStageStatusFailed, "no valid targets after seed expansion")
		e.handleEmptyTargetList(job)
		return
	}
	recordStageTransition(job, DiscoveryStagePrepare, DiscoveryStageStatusCompleted, "targets prepared")

	if shouldProbeProxmoxCandidates(job) {
		apiCtx, cancel := context.WithTimeout(ctx, defaultUniFiPhaseTimeout)
		devices := e.probeProxmoxCandidates(apiCtx, job, initialSeeds)
		cancel()

		if len(devices) > 0 {
			job.mu.Lock()
			for _, device := range devices {
				e.addOrUpdateDeviceToResults(job, device)
			}
			job.mu.Unlock()
		}
	}

	recordStageTransition(job, DiscoveryStageIdentity, DiscoveryStageStatusStarted, "identity collection started")
	allPotentialSNMPTargets := make(map[string]bool)
	for _, seed := range initialSeeds {
		allPotentialSNMPTargets[seed] = true
	}
	if shouldRunUniFiDiscovery(job) {
		uniFiTargets := e.handleUniFiDiscoveryPhase(ctx, job, initialSeeds)
		if uniFiTargets != nil {
			allPotentialSNMPTargets = uniFiTargets
		}
	}

	if shouldRunSNMPDiscovery(job) {
		if !e.setupAndExecuteSNMPPolling(job, allPotentialSNMPTargets, initialSeeds, snmpPollingModeIdentity) {
			recordStageTransition(job, DiscoveryStageIdentity, DiscoveryStageStatusFailed, "identity polling canceled or failed")
			e.finalizeJobStatus(job)
			return
		}
	}
	recordStageTransition(job, DiscoveryStageIdentity, DiscoveryStageStatusCompleted, "identity collection complete")

	recordStageTransition(job, DiscoveryStageEnrich, DiscoveryStageStatusStarted, "enrichment started")
	if shouldRunSNMPDiscovery(job) {
		if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeInterfaces {
			if !e.setupAndExecuteSNMPPolling(job, allPotentialSNMPTargets, initialSeeds, snmpPollingModeEnrichment) {
				recordStageTransition(job, DiscoveryStageEnrich, DiscoveryStageStatusFailed, "enrichment polling canceled or failed")
				e.finalizeJobStatus(job)
				return
			}
		}
	}
	if shouldProbeProxmoxCandidates(job) {
		apiCtx, cancel := context.WithTimeout(ctx, defaultUniFiPhaseTimeout)
		e.probeProxmoxKnownDeviceCandidates(apiCtx, job)
		cancel()
	}
	recordStageTransition(job, DiscoveryStageEnrich, DiscoveryStageStatusCompleted, "enrichment complete")

	// Hard invariant: topology resolution starts only after identity reconciliation completes.
	e.reconcileIdentity(job)
	job.mu.RLock()
	transitions := append([]DiscoveryStageTransition(nil), job.Results.Contract.StageTransitions...)
	job.mu.RUnlock()
	if !topologyStageReady(transitions) {
		recordStageTransition(job, DiscoveryStageTopology, DiscoveryStageStatusFailed, "identity/enrichment prerequisite missing")
		e.finalizeJobStatus(job)
		return
	}

	recordStageTransition(job, DiscoveryStageTopology, DiscoveryStageStatusStarted, "topology discovery started")
	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeTopology {
		if shouldRunUniFiDiscovery(job) {
			e.triggerUniFiTopologyDiscovery(ctx, job, initialSeeds)
		}

		if shouldRunSNMPDiscovery(job) {
			if !e.setupAndExecuteSNMPPolling(job, allPotentialSNMPTargets, initialSeeds, snmpPollingModeTopology) {
				recordStageTransition(job, DiscoveryStageTopology, DiscoveryStageStatusFailed, "topology polling canceled or failed")
				e.finalizeJobStatus(job)
				return
			}

			if recursiveSNMPTargetsEnabled(job) {
				ok, failedMode := e.pollRecursiveSNMPTargets(job, allPotentialSNMPTargets, initialSeeds)
				if !ok {
					failureMessage := "recursive topology polling canceled or failed"
					if failedMode == snmpPollingModeEnrichment {
						failureMessage = "recursive enrichment polling canceled or failed"
					}
					recordStageTransition(job, DiscoveryStageTopology, DiscoveryStageStatusFailed, failureMessage)
					e.finalizeJobStatus(job)
					return
				}
			}

			// The per-target observed join runs at each target's own walk, so
			// an FDB owner walked before the ARP owner never saw the mapping.
			// Replay the join against the final shared map after the last
			// topology pass (recursive or not).
			e.reconcileObservedFDBJoins(job)
		}
	}
	recordStageTransition(job, DiscoveryStageTopology, DiscoveryStageStatusCompleted, "topology complete")

	recordStageTransition(job, DiscoveryStageFinalize, DiscoveryStageStatusStarted, "finalizing job")
	e.finalizeJobStatus(job)
	recordStageTransition(job, DiscoveryStageFinalize, DiscoveryStageStatusCompleted, "job finalized")
}

func shouldRunUniFiDiscovery(job *DiscoveryJob) bool {
	if job == nil || job.Params == nil {
		return true
	}

	mode := strings.TrimSpace(strings.ToLower(job.Params.Mode))
	if mode == "" {
		return true
	}

	switch mode {
	case "snmp", "snmp_only", "snmp-only":
		return false
	default:
		return true
	}
}

func shouldRunSNMPDiscovery(job *DiscoveryJob) bool {
	if job == nil || job.Params == nil {
		return true
	}

	mode := strings.TrimSpace(strings.ToLower(job.Params.Mode))
	if mode == "" {
		return true
	}

	switch mode {
	case "api", "api_only", "api-only":
		return false
	default:
		return true
	}
}

const maxRecursiveSNMPRounds = 8

// pollRecursiveSNMPTargets SNMP-walks neighbors learned from LLDP/CDP (and
// eligible L2 evidence) until a round adds no new IPv4 management addresses.
// One round is not enough for a mesh: EDGE-1 yields CORE-1/EDGE-2, and CORE-2
// only appears after those boxes are walked.
func (e *DiscoveryEngine) pollRecursiveSNMPTargets(
	job *DiscoveryJob, knownTargets map[string]bool, initialSeeds []string,
) (bool, snmpPollingMode) {
	for round := 1; round <= maxRecursiveSNMPRounds; round++ {
		recursiveTargets := e.collectRecursiveSNMPTargets(job, knownTargets)
		if len(recursiveTargets) == 0 {
			return true, ""
		}

		if e.logger != nil {
			e.logger.Info().
				Str("job_id", job.ID).
				Int("round", round).
				Int("targets", len(recursiveTargets)).
				Msg("Recursive SNMP expansion")
		}

		for target := range recursiveTargets {
			knownTargets[target] = true
		}

		for _, mode := range recursivePollingModes(job.Params.Type) {
			if !e.setupAndExecuteSNMPPolling(job, recursiveTargets, initialSeeds, mode) {
				return false, mode
			}
		}
	}

	if e.logger != nil {
		e.logger.Warn().
			Str("job_id", job.ID).
			Int("max_rounds", maxRecursiveSNMPRounds).
			Msg("Recursive SNMP expansion hit round cap")
	}

	return true, ""
}

func recursiveSNMPTargetsEnabled(job *DiscoveryJob) bool {
	if job == nil || job.Params == nil || job.Params.Options == nil {
		return true
	}

	value := strings.TrimSpace(strings.ToLower(job.Params.Options["recursive_snmp_targets_enabled"]))
	if value == "" {
		return true
	}

	return value == "true" || value == "1" || value == "yes" || value == "on"
}
