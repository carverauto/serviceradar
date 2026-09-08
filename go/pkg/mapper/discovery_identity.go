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
)

func (e *DiscoveryEngine) reconcileIdentity(job *DiscoveryJob) {
	if job == nil {
		return
	}

	job.mu.Lock()
	e.deduplicateDevices(job)
	e.deduplicateInterfaces(job)
	job.identityReconciled = true
	job.mu.Unlock()
}

// finalizeJobStatus updates the job status after completion
func (e *DiscoveryEngine) reconcileIdentityAndPublishInterfaces(job *DiscoveryJob) {
	if job == nil {
		return
	}

	var interfaces []*DiscoveredInterface
	jobID := ""
	jobCtx := context.Background()

	e.reconcileIdentity(job)

	job.mu.Lock()
	if !job.interfacesPublished && len(job.Results.Interfaces) > 0 {
		interfaces = append(interfaces, job.Results.Interfaces...)
		job.interfacesPublished = true
		jobID = job.ID
		if job.ctx != nil {
			jobCtx = job.ctx
		}
	}
	job.mu.Unlock()

	if len(interfaces) > 0 {
		e.publishInterfaces(jobCtx, jobID, interfaces)
	}
}

func recursivePollingModes(discoveryType DiscoveryType) []snmpPollingMode {
	switch discoveryType {
	case DiscoveryTypeFull:
		return []snmpPollingMode{snmpPollingModeEnrichment, snmpPollingModeTopology}
	case DiscoveryTypeBasic, DiscoveryTypeInterfaces:
		return nil
	case DiscoveryTypeTopology:
		return []snmpPollingMode{snmpPollingModeTopology}
	default:
		return nil
	}
}

func (e *DiscoveryEngine) finalizeJobStatus(job *DiscoveryJob) {
	e.reconcileIdentityAndPublishInterfaces(job)

	job.mu.Lock()
	defer job.mu.Unlock()

	if job.Status.Status != DiscoveryStatusRunning {
		return
	}

	job.Status.Status = DiscoveryStatusCompleted
	job.Status.Progress = progressCompleted

	if len(job.Results.Devices) == 0 {
		job.Status.Error = "No SNMP devices found"
		e.logger.Info().Str("job_id", job.ID).Msg("Completed - no SNMP devices found")
		return
	}

	e.logger.Info().Str("job_id", job.ID).
		Int("devices", len(job.Results.Devices)).
		Int("interfaces", len(job.Results.Interfaces)).
		Int("topology_links", len(job.Results.TopologyLinks)).
		Msg("Completed successfully")
}
