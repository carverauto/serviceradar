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

package banner_grab

import (
	"sync"
	"time"
)

type candidatePlanner struct {
	portProtocols map[int][]string
	minFreshness  time.Duration
	now           func() time.Time
	mu            sync.Mutex
	lastObserved  map[string]time.Time
	backoffUntil  map[string]time.Time
}

func newCandidatePlanner(config Config, now func() time.Time) *candidatePlanner {
	if now == nil {
		now = time.Now
	}

	return &candidatePlanner{
		portProtocols: config.portProtocols(),
		minFreshness:  config.MinReprobeInterval,
		now:           now,
		lastObserved:  make(map[string]time.Time),
		backoffUntil:  make(map[string]time.Time),
	}
}

func (p *candidatePlanner) candidates(host string, port int, force bool) ([]Candidate, int, int) {
	protocols := p.portProtocols[port]
	if len(protocols) == 0 || host == "" || port <= 0 {
		return nil, 0, 0
	}

	now := p.now()
	out := make([]Candidate, 0, len(protocols))
	skippedFresh := 0
	skippedBackoff := 0

	p.mu.Lock()
	defer p.mu.Unlock()

	for _, protocol := range protocols {
		key := candidateKey(host, port, protocol)
		if !force {
			if last := p.lastObserved[key]; !last.IsZero() && p.minFreshness > 0 && now.Sub(last) < p.minFreshness {
				skippedFresh++
				continue
			}
			if until := p.backoffUntil[key]; until.After(now) {
				skippedBackoff++
				continue
			}
		}

		out = append(out, Candidate{
			Host:     host,
			Port:     port,
			Protocol: protocol,
			Source:   SourceSweepActive,
		})
	}

	return out, skippedFresh, skippedBackoff
}

func (p *candidatePlanner) recordSuccess(candidate Candidate, at time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()

	key := candidateKey(candidate.Host, candidate.Port, candidate.Protocol)
	p.lastObserved[key] = at
	delete(p.backoffUntil, key)
}

//nolint:unparam // duration parameterized for future adaptive backoff strategies
func (p *candidatePlanner) recordBackoff(candidate Candidate, duration time.Duration) {
	if duration <= 0 {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	p.backoffUntil[candidateKey(candidate.Host, candidate.Port, candidate.Protocol)] = p.now().Add(duration)
}

func candidateKey(host string, port int, protocol string) string {
	return host + "|" + portString(port) + "|" + protocol
}
