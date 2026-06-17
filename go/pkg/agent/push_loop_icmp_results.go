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
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/proto"
)

func (p *PushLoop) pushICMPResults(ctx context.Context) bool {
	results := p.collectDueICMPResults(ctx)
	if len(results) == 0 {
		return false
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()

	message, err := marshalICMPMetricEnvelope(results, metricEnvelopeContext{
		AgentID:   agentID,
		GatewayID: gatewayID,
		Partition: partition,
		KvStoreID: kvStoreID,
	})
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal ICMP metric envelope")
		return false
	}
	p.publishAddonMetricFeed("icmp", message)

	status := &proto.GatewayServiceStatus{
		ServiceName:  "icmp_checks",
		ServiceType:  "icmp",
		Available:    true,
		Message:      message,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       "icmp-metrics",
		KvStoreId:    kvStoreID,
	}

	chunk := &proto.GatewayStatusChunk{
		Services:    []*proto.GatewayServiceStatus{status},
		GatewayId:   gatewayID,
		AgentId:     agentID,
		Timestamp:   time.Now().UnixNano(),
		Partition:   partition,
		SourceIp:    p.getSourceIP(),
		IsFinal:     true,
		ChunkIndex:  0,
		TotalChunks: 1,
		KvStoreId:   kvStoreID,
		Version:     runtimeMetadata.Version,
		Hostname:    runtimeMetadata.Hostname,
		Os:          runtimeMetadata.Os,
		Arch:        runtimeMetadata.Arch,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, []*proto.GatewayStatusChunk{chunk})
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream ICMP results to gateway")
		return false
	}

	if resp.Received {
		p.logger.Info().Int("result_count", len(results)).Msg("Streamed ICMP results to gateway")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge ICMP metrics stream")
	return false
}

func (p *PushLoop) collectDueICMPResults(ctx context.Context) []icmpCheckResult {
	now := time.Now()

	p.icmpMu.RLock()
	checks := make([]*icmpCheckConfig, 0, len(p.icmpChecks))
	for _, check := range p.icmpChecks {
		checks = append(checks, check)
	}
	lastRun := make(map[string]time.Time, len(p.icmpLastRun))
	for id, t := range p.icmpLastRun {
		lastRun[id] = t
	}
	p.icmpMu.RUnlock()

	if len(checks) == 0 {
		return nil
	}

	results := make([]icmpCheckResult, 0, len(checks))

	for _, check := range checks {
		if check == nil || !check.Enabled || check.Target == "" {
			continue
		}

		interval := check.Interval
		if interval <= 0 {
			interval = p.getInterval()
		}

		if last, ok := lastRun[check.ID]; ok && now.Sub(last) < interval {
			continue
		}

		result := p.runICMPCheck(ctx, check)
		results = append(results, result)

		p.icmpMu.Lock()
		p.icmpLastRun[check.ID] = now
		p.icmpMu.Unlock()
	}

	return results
}

func (p *PushLoop) runICMPCheck(ctx context.Context, check *icmpCheckConfig) icmpCheckResult {
	timeout := check.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	checkCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	scanner, err := scan.NewICMPSweeper(timeout, defaultICMPSweeperRateLimit, p.logger)
	if err != nil {
		return icmpCheckResult{
			CheckID:   check.ID,
			CheckName: check.Name,
			Target:    check.Target,
			DeviceID:  check.DeviceID,
			Available: false,
			Timestamp: time.Now().UnixNano(),
			Error:     err.Error(),
		}
	}
	defer func() {
		if stopErr := scanner.Stop(); stopErr != nil {
			p.logger.Error().Err(stopErr).Msg("Failed to stop ICMP scanner")
		}
	}()

	resultChan, err := scanner.Scan(checkCtx, []models.Target{{Host: check.Target, Mode: models.ModeICMP}})
	if err != nil {
		return icmpCheckResult{
			CheckID:   check.ID,
			CheckName: check.Name,
			Target:    check.Target,
			DeviceID:  check.DeviceID,
			Available: false,
			Timestamp: time.Now().UnixNano(),
			Error:     err.Error(),
		}
	}

	var result models.Result
	select {
	case r, ok := <-resultChan:
		if ok {
			result = r
		}
	case <-checkCtx.Done():
		return icmpCheckResult{
			CheckID:   check.ID,
			CheckName: check.Name,
			Target:    check.Target,
			DeviceID:  check.DeviceID,
			Available: false,
			Timestamp: time.Now().UnixNano(),
			Error:     checkCtx.Err().Error(),
		}
	}

	return icmpCheckResult{
		CheckID:        check.ID,
		CheckName:      check.Name,
		Target:         check.Target,
		DeviceID:       check.DeviceID,
		Available:      result.Available,
		ResponseTimeNs: result.RespTime.Nanoseconds(),
		PacketLoss:     result.PacketLoss,
		Timestamp:      time.Now().UnixNano(),
	}
}
