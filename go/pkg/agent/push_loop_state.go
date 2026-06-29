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

import "time"

func (p *PushLoop) getInterval() time.Duration {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.interval
}

func (p *PushLoop) setInterval(d time.Duration) {
	p.stateMu.Lock()
	p.interval = d
	p.stateMu.Unlock()
}

func (p *PushLoop) getStatusDebounceInterval() time.Duration {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.statusDebounce
}

func (p *PushLoop) getStatusHeartbeatInterval() time.Duration {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.statusHeartbeat
}

func (p *PushLoop) isStatusDebounceConfigured() bool {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.statusDebounceConfigured
}

func (p *PushLoop) isStatusHeartbeatConfigured() bool {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.statusHeartbeatConfigured
}

func (p *PushLoop) setStatusDebounceInterval(d time.Duration) {
	p.setStatusIntervals(d, p.getStatusHeartbeatInterval(), false, false)
}

func (p *PushLoop) setStatusHeartbeatInterval(d time.Duration) {
	p.setStatusIntervals(p.getStatusDebounceInterval(), d, false, false)
}

// SetStatusDebounceInterval updates the minimum interval between unchanged status pushes.
func (p *PushLoop) SetStatusDebounceInterval(d time.Duration) {
	p.setStatusIntervals(d, p.getStatusHeartbeatInterval(), true, false)
}

// SetStatusHeartbeatInterval updates the maximum interval between status pushes (heartbeat).
func (p *PushLoop) SetStatusHeartbeatInterval(d time.Duration) {
	p.setStatusIntervals(p.getStatusDebounceInterval(), d, false, true)
}

func (p *PushLoop) getConfigPollInterval() time.Duration {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.configPollInterval
}

func (p *PushLoop) getConfigVersion() string {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.configVersion
}

func (p *PushLoop) setConfigVersion(v string) {
	p.stateMu.Lock()
	p.configVersion = v
	p.stateMu.Unlock()
}

func (p *PushLoop) getLastAttemptedConfigVersion() string {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.lastAttemptedConfigVersion
}

func (p *PushLoop) setLastAttemptedConfigVersion(v string) {
	p.stateMu.Lock()
	p.lastAttemptedConfigVersion = v
	p.stateMu.Unlock()
}

func (p *PushLoop) setConfigPollInterval(d time.Duration) {
	p.stateMu.Lock()
	p.configPollInterval = d
	p.stateMu.Unlock()
}

func (p *PushLoop) setStatusIntervals(
	debounce time.Duration,
	heartbeat time.Duration,
	markDebounceConfigured bool,
	markHeartbeatConfigured bool,
) {
	debounce, heartbeat = clampStatusIntervals(debounce, heartbeat, p.getInterval())
	p.stateMu.Lock()
	p.statusDebounce = debounce
	p.statusHeartbeat = heartbeat
	if markDebounceConfigured {
		p.statusDebounceConfigured = true
	}
	if markHeartbeatConfigured {
		p.statusHeartbeatConfigured = true
	}
	p.stateMu.Unlock()
}

func clampStatusIntervals(debounce, heartbeat, fallbackDebounce time.Duration) (time.Duration, time.Duration) {
	if debounce <= 0 {
		debounce = fallbackDebounce
	}
	if debounce <= 0 {
		debounce = defaultPushInterval
	}
	if heartbeat <= 0 {
		heartbeat = defaultStatusHeartbeatInterval
	}
	if heartbeat < debounce {
		heartbeat = debounce
	}
	return debounce, heartbeat
}

func (p *PushLoop) isEnrolled() bool {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.enrolled
}

func (p *PushLoop) setEnrolled(v bool) {
	p.stateMu.Lock()
	p.enrolled = v
	p.stateMu.Unlock()
}

func (p *PushLoop) getSweepResultsSequence() string {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.sweepResultsSeq
}

func (p *PushLoop) setSweepResultsSequence(seq string) {
	p.stateMu.Lock()
	p.sweepResultsSeq = seq
	p.stateMu.Unlock()
}

func (p *PushLoop) getStatusTrackingState() (string, time.Time) {
	p.stateMu.RLock()
	defer p.stateMu.RUnlock()
	return p.lastStatusSignature, p.lastStatusPush
}

func (p *PushLoop) recordStatusPush(signature string, at time.Time) {
	p.stateMu.Lock()
	p.lastStatusSignature = signature
	p.lastStatusPush = at
	p.stateMu.Unlock()
}
