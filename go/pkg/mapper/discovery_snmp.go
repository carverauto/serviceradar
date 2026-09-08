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
	"fmt"
	"sync"
	"time"
)

type snmpPollingMode string

const (
	snmpPollingModeIdentity   snmpPollingMode = "identity"
	snmpPollingModeEnrichment snmpPollingMode = "enrichment"
	snmpPollingModeTopology   snmpPollingMode = "topology"
)

func (e *DiscoveryEngine) setupAndExecuteSNMPPolling(
	job *DiscoveryJob, allPotentialSNMPTargets map[string]bool, initialSeeds []string, mode snmpPollingMode) bool {
	job.scanQueue = make([]string, 0, len(allPotentialSNMPTargets))

	for ip := range allPotentialSNMPTargets {
		if ip != "" {
			job.scanQueue = append(job.scanQueue, ip)
		}
	}

	totalSNMPTargets := len(job.scanQueue)
	if totalSNMPTargets == 0 {
		e.logger.Info().Str("job_id", job.ID).Strs("seeds", initialSeeds).
			Int("unifi_apis_count", len(e.config.UniFiAPIs)).
			Int("mikrotik_apis_count", len(e.config.MikroTikAPIs)).
			Int("proxmox_apis_count", len(e.config.ProxmoxAPIs)).
			Msg("No SNMP targets to poll")

		return true
	}

	e.logger.Info().Str("job_id", job.ID).Int("snmp_targets_count", totalSNMPTargets).
		Msg("Phase 2 - SNMP Polling unique target IPs")

	// Setup for SNMP polling
	concurrency := e.determineConcurrency(job, totalSNMPTargets)

	var wgSNMP sync.WaitGroup

	targetChanSNMP := make(chan string, concurrency*defaultConcurrencyMultiplier)
	resultChanSNMP := make(chan bool, totalSNMPTargets)

	// Create a wrapper function that matches the targetProcessorFunc type
	snmpWrapper := func(job *DiscoveryJob, targetIP string) {
		e.scanTargetForSNMP(job.ctx, job, targetIP, mode)
	}

	// Start workers and progress tracking
	e.startWorkers(job, &wgSNMP, targetChanSNMP, resultChanSNMP, concurrency, snmpWrapper)

	baseSNMPProgress := progressInitial / 3
	rangeSNMPProgress := progressScanning - baseSNMPProgress

	go e.trackJobProgress(job, resultChanSNMP, totalSNMPTargets, baseSNMPProgress, rangeSNMPProgress)

	job.mu.Lock()
	job.Status.Progress = baseSNMPProgress
	job.mu.Unlock()

	e.logger.Debug().Str("job_id", job.ID).Strs("scan_queue", job.scanQueue).Msg("Scan queue for SNMP")

	// Execute SNMP polling
	return e.executeSNMPPolling(job, targetChanSNMP, resultChanSNMP, &wgSNMP)
}

// executeSNMPPolling executes the SNMP polling phase
func (e *DiscoveryEngine) executeSNMPPolling(
	job *DiscoveryJob, targetChanSNMP chan<- string, resultChanSNMP chan bool, wgSNMP *sync.WaitGroup) bool {
	if e.feedTargetsToWorkers(job, targetChanSNMP) { // This closes targetChanSNMP
		wgSNMP.Wait()

		close(resultChanSNMP)

		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoverStatusCanceled
			job.Status.Error = "Job canceled during SNMP polling phase"
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()
		e.logger.Info().Str("job_id", job.ID).Msg("SNMP target feeding/processing was canceled")

		return false
	}

	wgSNMP.Wait()

	close(resultChanSNMP)

	// Corrected method name: checkPhaseJobCancellation instead of checkJobCancellation
	return !e.checkPhaseJobCancellation(job, "", "SNMP polling")
}

// trackJobProgress starts a goroutine to track job progress for a specific phase
func (e *DiscoveryEngine) trackJobProgress(
	job *DiscoveryJob,
	resultChan <-chan bool, totalTargets int, baseProgress, progressRange float64) {
	processed := 0
	successful := 0

	for success := range resultChan {
		processed++

		if success {
			successful++
		}

		job.mu.Lock()

		currentProgress := baseProgress

		if totalTargets > 0 {
			currentProgress += (float64(processed) / float64(totalTargets)) * progressRange
		}

		job.Status.Progress = currentProgress
		job.Status.DevicesFound = len(job.Results.Devices)
		job.Status.InterfacesFound = len(job.Results.Interfaces)
		job.Status.TopologyLinks = len(job.Results.TopologyLinks)

		e.logger.Debug().Str("job_id", job.ID).Float64("progress", job.Status.Progress).
			Int("processed", processed).Int("total_targets", totalTargets).
			Int("successful", successful).Int("devices", job.Status.DevicesFound).
			Int("interfaces", job.Status.InterfacesFound).Int("links", job.Status.TopologyLinks).
			Msg("Job progress update")

		job.mu.Unlock()

		select {
		case <-job.ctx.Done():
			e.logger.Debug().Str("job_id", job.ID).Msg("Progress tracking stopping due to cancellation")
			return
		case <-e.done:
			e.logger.Debug().Str("job_id", job.ID).Msg("Progress tracking stopping due to engine shutdown")
			return
		default:
		}
	}

	e.logger.Debug().Str("job_id", job.ID).Int("successful", successful).
		Int("total_targets", totalTargets).Msg("Progress tracking finished for this phase")
}

// finalizeDevice performs final setup on the device before returning it
func (*DiscoveryEngine) finalizeDevice(job *DiscoveryJob, device *DiscoveredDevice, target, jobID, source string) {
	if device.SysName != "" && device.Hostname == "" {
		device.Hostname = device.SysName
	}

	// Use IP as hostname if not provided
	if device.Hostname == "" {
		device.Hostname = target
	}

	// Add job metadata
	device.Metadata["discovery_id"] = jobID
	device.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
	device.Metadata["source"] = source
	applyJobOptionsMetadata(job, device.Metadata)
}

// finalizeInterfaces finalizes the interfaces by ensuring they have names and adding metadata
func (*DiscoveryEngine) finalizeInterfaces(
	job *DiscoveryJob, ifMap map[int]*DiscoveredInterface, jobID string) []*DiscoveredInterface {
	interfaces := make([]*DiscoveredInterface, 0, len(ifMap))

	// Cache devices by IP for lookup
	job.mu.RLock()

	deviceMap := make(map[string]*DiscoveredDevice)

	for _, device := range job.Results.Devices {
		deviceMap[device.IP] = device
	}

	job.mu.RUnlock()

	for _, iface := range ifMap {
		if iface.IfName == "" {
			if iface.IfDescr != "" {
				iface.IfName = iface.IfDescr
			} else {
				iface.IfName = fmt.Sprintf("Interface-%d", iface.IfIndex)
			}
		}

		iface.Metadata["discovery_id"] = jobID
		iface.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
		applyJobOptionsMetadata(job, iface.Metadata)

		interfaces = append(interfaces, iface)
	}

	return interfaces
}
