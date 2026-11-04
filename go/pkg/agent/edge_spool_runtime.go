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

package agent

import (
	"sync"

	"github.com/carverauto/serviceradar/proto"
)

// edgeSpoolRuntime is what the push loop reports and applies about the agent's
// one edge-record spool: whether it opened, which every hello carries, and the
// byte budget core delivers in the agent config.
type edgeSpoolRuntime struct {
	mu            sync.Mutex
	status        *proto.EdgeRecordSpoolStatus
	applyBudget   func(maxBytes uint64) error
	appliedBudget uint64
}

// SetEdgeSpoolStatus records how the spool opened at startup: openErr nil when
// it is available. Core shows an agent whose spool did not open as
// spool_unavailable.
func (p *PushLoop) SetEdgeSpoolStatus(openErr error) {
	status := &proto.EdgeRecordSpoolStatus{Available: openErr == nil}
	if openErr != nil {
		status.Error = openErr.Error()
	}

	p.edgeSpool.mu.Lock()
	defer p.edgeSpool.mu.Unlock()
	p.edgeSpool.status = status
}

// SetEdgeSpoolBudget installs the function that applies core's spool byte
// budget at spool admission.
func (p *PushLoop) SetEdgeSpoolBudget(apply func(maxBytes uint64) error) {
	p.edgeSpool.mu.Lock()
	defer p.edgeSpool.mu.Unlock()
	p.edgeSpool.applyBudget = apply
}

// edgeSpoolStatus is the status the hellos report, nil until it is recorded.
func (p *PushLoop) edgeSpoolStatus() *proto.EdgeRecordSpoolStatus {
	p.edgeSpool.mu.Lock()
	defer p.edgeSpool.mu.Unlock()
	return p.edgeSpool.status
}

// applyEdgeSpoolBudget applies the config's spool budget when it changed. Zero
// means the core predates the setting, so the agent keeps the budget it has.
// A refused budget is logged and retried on the next config that carries one.
func (p *PushLoop) applyEdgeSpoolBudget(configResp *proto.AgentConfigResponse) {
	budget := configResp.GetEdgeSpoolMaxBytes()

	p.edgeSpool.mu.Lock()
	defer p.edgeSpool.mu.Unlock()
	if budget == 0 || budget == p.edgeSpool.appliedBudget || p.edgeSpool.applyBudget == nil {
		return
	}
	if err := p.edgeSpool.applyBudget(budget); err != nil {
		p.logger.Warn().Err(err).Uint64("spool_max_bytes", budget).Msg("Refused edge spool budget from config")
		return
	}
	p.edgeSpool.appliedBudget = budget
	p.logger.Info().Uint64("spool_max_bytes", budget).Msg("Applied edge spool budget from config")
}
