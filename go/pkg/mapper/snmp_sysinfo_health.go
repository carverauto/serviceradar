/*
 * Copyright 2026 Carver Automation Corporation.
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

import "sync"

// snmpSysInfoHealth remembers, across discovery runs, which targets did not
// answer the SNMP system-info query. A seed with no SNMP agent, or one that
// never answers the configured credential, fails every pass of every run; the
// engine reports it when it starts failing and when it answers again, not on
// each attempt.
type snmpSysInfoHealth struct {
	mu      sync.Mutex
	failing map[string]struct{}
}

// markFailing records a failed query and reports whether the target was
// already failing before this attempt.
func (h *snmpSysInfoHealth) markFailing(target string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, ok := h.failing[target]; ok {
		return true
	}

	if h.failing == nil {
		h.failing = make(map[string]struct{})
	}

	h.failing[target] = struct{}{}

	return false
}

// markAnswering records a successful query and reports whether the target had
// been failing.
func (h *snmpSysInfoHealth) markAnswering(target string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, ok := h.failing[target]; !ok {
		return false
	}

	delete(h.failing, target)

	return true
}

// skipSysInfoForRestOfRun stops later polling passes of this run from
// re-querying a target that has now failed on consecutive attempts.
func (job *DiscoveryJob) skipSysInfoForRestOfRun(target string) {
	job.mu.Lock()
	defer job.mu.Unlock()

	if job.sysInfoSkipped == nil {
		job.sysInfoSkipped = make(map[string]struct{})
	}

	job.sysInfoSkipped[target] = struct{}{}
}

func (job *DiscoveryJob) sysInfoSkippedThisRun(target string) bool {
	job.mu.RLock()
	defer job.mu.RUnlock()

	_, ok := job.sysInfoSkipped[target]

	return ok
}

// reportSysInfoFailure warns when a target starts failing the system-info
// query and logs later failures at debug. A target that fails again after
// already failing is not re-queried by the remaining passes of this run; each
// later run still queries it once, so it is picked up when it starts answering.
func (e *DiscoveryEngine) reportSysInfoFailure(job *DiscoveryJob, snmpTargetIP, hostname string, err error) {
	target := describeSNMPTarget(snmpTargetIP, hostname)

	if e.sysInfoHealth.markFailing(snmpTargetIP) {
		job.skipSysInfoForRestOfRun(snmpTargetIP)

		e.logger.Debug().
			Str("job_id", job.ID).
			Str("target_ip", snmpTargetIP).
			Str("hostname", hostname).
			Err(err).
			Msgf("System info via SNMP still failing for %s", target)

		return
	}

	e.logger.Warn().
		Str("job_id", job.ID).
		Str("target_ip", snmpTargetIP).
		Str("hostname", hostname).
		Err(err).
		Msgf("Failed to query system info via SNMP for %s, skipping; repeats are logged at debug until it answers", target)
}

// reportSysInfoAnswered logs once when a previously failing target answers the
// system-info query again.
func (e *DiscoveryEngine) reportSysInfoAnswered(job *DiscoveryJob, snmpTargetIP, hostname string) {
	if !e.sysInfoHealth.markAnswering(snmpTargetIP) {
		return
	}

	e.logger.Info().
		Str("job_id", job.ID).
		Str("target_ip", snmpTargetIP).
		Str("hostname", hostname).
		Msgf("System info via SNMP answering again for %s", describeSNMPTarget(snmpTargetIP, hostname))
}
