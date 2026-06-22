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

func (e *DiscoveryEngine) triggerUniFiTopologyDiscovery(ctx context.Context, job *DiscoveryJob, initialSeeds []string) {
	if len(e.config.UniFiAPIs) == 0 || (job.Params.Type != DiscoveryTypeFull && job.Params.Type != DiscoveryTypeTopology) {
		return
	}

	seen := make(map[string]struct{})
	candidates := make([]string, 0, len(initialSeeds)+1)

	for _, seed := range initialSeeds {
		seed = strings.TrimSpace(seed)
		if seed == "" {
			continue
		}
		if _, ok := seen[seed]; ok {
			continue
		}
		seen[seed] = struct{}{}
		candidates = append(candidates, seed)
	}

	// Final fallback contextless attempt (build from full controller inventory).
	candidates = append(candidates, "")

	for _, candidate := range candidates {
		attemptCtx, cancel := context.WithTimeout(ctx, defaultUniFiPhaseTimeout)
		e.checkUniFiAPI(attemptCtx, job, candidate)
		cancel()

		job.mu.RLock()
		polled := job.uniFiTopologyPolled
		job.mu.RUnlock()
		if polled {
			return
		}
	}
}

// handleUniFiDiscoveryPhase performs the UniFi discovery phase and collects potential SNMP targets
func (e *DiscoveryEngine) handleUniFiDiscoveryPhase(
	ctx context.Context, job *DiscoveryJob, initialSeeds []string,
) map[string]bool {
	allPotentialSNMPTargets := make(map[string]bool)
	seenMACs := make(map[string]string)

	for _, seedIP := range initialSeeds {
		if seedIP != "" {
			allPotentialSNMPTargets[seedIP] = true
		}
	}

	job.mu.Lock()
	job.Status.Progress = progressInitial / 3
	job.mu.Unlock()

	e.logger.Info().Str("job_id", job.ID).Int("initial_seeds_count", len(initialSeeds)).
		Msg("Phase 1 - API discovery starting")

	devicesFound := 0
	interfacesFound := 0

	for _, seedIP := range initialSeeds {
		if seedIP == "" {
			continue
		}

		if e.checkPhaseJobCancellation(job, seedIP, "UniFi discovery") {
			return nil
		}

		if len(e.config.UniFiAPIs) > 0 {
			seedCtx, cancel := context.WithTimeout(ctx, defaultUniFiPhaseTimeout)
			devices, interfaces, err := e.queryUniFiDevices(seedCtx, job, seedIP)
			cancel()
			if err != nil {
				e.logger.Error().Str("job_id", job.ID).
					Str("seed_ip", seedIP).Err(err).Msg("UniFi discovery for seed failed")

				continue
			}

			devicesFound += len(devices)
			interfacesFound += len(interfaces)

			job.mu.Lock()
			e.processDevicesForSNMPTargets(job, devices, allPotentialSNMPTargets, seenMACs)
			job.mu.Unlock()

			for _, iface := range interfaces {
				if iface.DeviceID == "" && iface.IfPhysAddress != "" {
					iface.DeviceID = GenerateDeviceID(iface.IfPhysAddress)
				}
				e.upsertInterface(job, iface)
			}
		}
	}

	if len(e.config.MikroTikAPIs) > 0 {
		apiCtx, cancel := context.WithTimeout(ctx, defaultUniFiPhaseTimeout)
		devices, interfaces, links, err := e.queryMikroTikDevices(apiCtx, job)
		cancel()
		if err != nil {
			e.logger.Error().Str("job_id", job.ID).Err(err).Msg("MikroTik discovery failed")
		} else {
			devicesFound += len(devices)
			interfacesFound += len(interfaces)

			job.mu.Lock()
			e.processDevicesForSNMPTargets(job, devices, allPotentialSNMPTargets, seenMACs)
			job.mu.Unlock()

			for _, iface := range interfaces {
				e.upsertInterface(job, iface)
			}

			if len(links) > 0 {
				e.publishTopologyLinks(job, links, "", "MikroTik-API")
			}
		}
	}

	if len(e.config.ProxmoxAPIs) > 0 {
		apiCtx, cancel := context.WithTimeout(ctx, defaultUniFiPhaseTimeout)
		devices, links, err := e.queryProxmoxDevices(apiCtx, job)
		cancel()
		if err != nil {
			e.logger.Error().Str("job_id", job.ID).Err(err).Msg("Proxmox discovery failed")
		} else {
			devicesFound += len(devices)

			job.mu.Lock()
			e.processDevicesForSNMPTargets(job, devices, allPotentialSNMPTargets, seenMACs)
			job.mu.Unlock()

			if len(links) > 0 {
				e.publishTopologyLinks(job, links, "", "Proxmox-API")
			}
		}
	}

	e.logger.Info().Str("job_id", job.ID).Int("devices_found", devicesFound).
		Int("interfaces_found", interfacesFound).Int("snmp_targets", len(allPotentialSNMPTargets)).
		Msg("Phase 1 - API discovery completed")

	return allPotentialSNMPTargets
}
