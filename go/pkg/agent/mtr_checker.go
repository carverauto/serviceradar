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
	"encoding/json"
	"maps"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
)

const (
	mtrCheckType   = "mtr"
	mtrServiceName = "mtr_traces"
	mtrServiceType = "mtr"

	// Safety caps for remotely supplied MTR config.
	mtrMaxHopsUpperBound         = 64
	mtrProbesPerHopUpperBound    = 20
	mtrProbeIntervalMsUpperBound = 10_000
	mtrPacketSizeUpperBound      = 1500
)

type mtrCheckConfig struct {
	ID              string
	Name            string
	Target          string
	DeviceID        string
	Interval        time.Duration
	Timeout         time.Duration
	Enabled         bool
	MaxHops         int
	ProbesPerHop    int
	Protocol        mtr.Protocol
	ProbeIntervalMs int
	PacketSize      int
	DNSResolve      bool
	ASNDBPath       string
}

type mtrCheckResult struct {
	CheckID   string           `json:"check_id"`
	CheckName string           `json:"check_name"`
	Target    string           `json:"target"`
	DeviceID  string           `json:"device_id,omitempty"`
	Available bool             `json:"available"`
	Trace     *mtr.TraceResult `json:"trace,omitempty"`
	Timestamp int64            `json:"timestamp"`
	Error     string           `json:"error,omitempty"`
}

// mtrCheckerState holds per-PushLoop MTR check state.
type mtrCheckerState struct {
	checks  map[string]*mtrCheckConfig
	lastRun map[string]time.Time
	mu      sync.RWMutex
}

func newMtrCheckerState() *mtrCheckerState {
	return &mtrCheckerState{
		checks:  make(map[string]*mtrCheckConfig),
		lastRun: make(map[string]time.Time),
	}
}

// pushMtrResults collects and pushes due MTR check results.
func (p *PushLoop) pushMtrResults(ctx context.Context) bool {
	results := p.collectDueMtrResults(ctx)
	if len(results) == 0 {
		return false
	}

	payload := map[string]any{
		"results": results,
	}

	data, err := json.Marshal(payload)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal MTR results payload")
		return false
	}

	chunk := &proto.ResultsChunk{
		Data:        data,
		IsFinal:     true,
		ChunkIndex:  0,
		TotalChunks: 1,
		Timestamp:   time.Now().UnixNano(),
	}

	statusChunks := p.buildResultsStatusChunks([]*proto.ResultsChunk{chunk}, mtrServiceName, mtrServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second) //nolint:mnd
	defer cancel()

	if _, err := p.gateway.StreamStatus(pushCtx, statusChunks); err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream MTR results to gateway")
		return false
	}

	p.logger.Info().Int("result_count", len(results)).Msg("Streamed MTR results to gateway")

	return true
}

func (p *PushLoop) collectDueMtrResults(ctx context.Context) []mtrCheckResult {
	now := time.Now()

	p.mtrState.mu.RLock()
	checks := make([]*mtrCheckConfig, 0, len(p.mtrState.checks))
	for _, check := range p.mtrState.checks {
		checks = append(checks, check)
	}

	lastRun := make(map[string]time.Time, len(p.mtrState.lastRun))
	maps.Copy(lastRun, p.mtrState.lastRun)
	p.mtrState.mu.RUnlock()

	if len(checks) == 0 {
		return nil
	}

	results := make([]mtrCheckResult, 0, len(checks))

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

		result := p.runMtrCheck(ctx, check)
		results = append(results, result)

		p.mtrState.mu.Lock()
		p.mtrState.lastRun[check.ID] = now
		p.mtrState.mu.Unlock()
	}

	return results
}

func (p *PushLoop) runMtrCheck(ctx context.Context, check *mtrCheckConfig) mtrCheckResult {
	timeout := check.Timeout
	if timeout <= 0 {
		timeout = mtr.DefaultTimeout
	}

	checkCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	opts := mtr.Options{
		Target:         check.Target,
		MaxHops:        check.MaxHops,
		ProbesPerHop:   check.ProbesPerHop,
		Protocol:       check.Protocol,
		Timeout:        timeout,
		ProbeInterval:  time.Duration(check.ProbeIntervalMs) * time.Millisecond,
		PacketSize:     check.PacketSize,
		DNSResolve:     check.DNSResolve,
		ASNDBPath:      check.ASNDBPath,
		MaxUnknownHops: mtr.DefaultMaxUnknownHops,
		RingBufferSize: mtr.DefaultRingBufferSize,
	}

	tracer, err := mtr.NewTracer(checkCtx, opts, p.logger)
	if err != nil {
		return mtrCheckResult{
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
		if closeErr := tracer.Close(); closeErr != nil {
			p.logger.Warn().Err(closeErr).Str("target", check.Target).Msg("Failed to close MTR tracer")
		}
	}()

	trace, err := tracer.Run(checkCtx)
	if err != nil {
		return mtrCheckResult{
			CheckID:   check.ID,
			CheckName: check.Name,
			Target:    check.Target,
			DeviceID:  check.DeviceID,
			Available: false,
			Timestamp: time.Now().UnixNano(),
			Error:     err.Error(),
		}
	}

	return mtrCheckResult{
		CheckID:   check.ID,
		CheckName: check.Name,
		Target:    check.Target,
		DeviceID:  check.DeviceID,
		Available: trace.TargetReached,
		Trace:     trace,
		Timestamp: time.Now().UnixNano(),
	}
}

// runOnDemandMtr executes a single MTR trace for an on-demand request.
func runOnDemandMtr(ctx context.Context, opts mtr.Options, log logger.Logger) (*mtr.TraceResult, error) {
	tracer, err := mtr.NewTracer(ctx, opts, log)
	if err != nil {
		return nil, err
	}
	defer func() {
		if closeErr := tracer.Close(); closeErr != nil {
			log.Warn().Err(closeErr).Str("target", opts.Target).Msg("Failed to close on-demand MTR tracer")
		}
	}()

	return tracer.Run(ctx)
}

// applyMtrCheckConfigs parses and applies MTR check configs.
func (p *PushLoop) applyMtrCheckConfigs(checks []*proto.AgentCheckConfig) {
	parsed := make(map[string]*mtrCheckConfig)

	for _, check := range checks {
		cfg := parseMtrCheckConfig(check)
		if cfg == nil {
			continue
		}

		parsed[cfg.ID] = cfg
	}

	p.mtrState.mu.Lock()
	p.mtrState.checks = parsed

	for id := range p.mtrState.lastRun {
		if _, ok := parsed[id]; !ok {
			delete(p.mtrState.lastRun, id)
		}
	}
	p.mtrState.mu.Unlock()

	if len(parsed) > 0 {
		p.logger.Info().Int("mtr_checks", len(parsed)).Msg("Applied MTR check config from gateway")
	}
}

func parseMtrCheckConfig(check *proto.AgentCheckConfig) *mtrCheckConfig {
	if check == nil {
		return nil
	}

	checkType := strings.ToLower(strings.TrimSpace(check.CheckType))
	if checkType != mtrCheckType {
		return nil
	}

	if !check.Enabled {
		return nil
	}

	target := strings.TrimSpace(check.Target)
	if target == "" {
		return nil
	}

	checkID := strings.TrimSpace(check.CheckId)
	if checkID == "" {
		return nil
	}

	cfg := &mtrCheckConfig{
		ID:              checkID,
		Name:            strings.TrimSpace(check.Name),
		Target:          target,
		Interval:        time.Duration(check.IntervalSec) * time.Second,
		Timeout:         time.Duration(check.TimeoutSec) * time.Second,
		Enabled:         check.Enabled,
		MaxHops:         mtr.DefaultMaxHops,
		ProbesPerHop:    mtr.DefaultProbesPerHop,
		Protocol:        mtr.ProtocolICMP,
		ProbeIntervalMs: mtr.DefaultProbeIntervalMs,
		PacketSize:      mtr.DefaultPacketSize,
		DNSResolve:      true,
		ASNDBPath:       mtr.DefaultASNDBPath,
	}

	if check.Settings != nil {
		if v, ok := check.Settings["device_id"]; ok {
			cfg.DeviceID = strings.TrimSpace(v)
		}

		if cfg.DeviceID == "" {
			if v, ok := check.Settings["device_uid"]; ok {
				cfg.DeviceID = strings.TrimSpace(v)
			}
		}

		if v, ok := check.Settings["max_hops"]; ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				cfg.MaxHops = clampInt(n, mtrMaxHopsUpperBound)
			}
		}

		if v, ok := check.Settings["probes_per_hop"]; ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				cfg.ProbesPerHop = clampInt(n, mtrProbesPerHopUpperBound)
			}
		}

		if v, ok := check.Settings["protocol"]; ok {
			cfg.Protocol = mtr.ParseProtocol(v)
		}

		if v, ok := check.Settings["probe_interval_ms"]; ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				cfg.ProbeIntervalMs = clampInt(n, mtrProbeIntervalMsUpperBound)
			}
		}

		if v, ok := check.Settings["packet_size"]; ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				cfg.PacketSize = clampInt(n, mtrPacketSizeUpperBound)
			}
		}

		if v, ok := check.Settings["dns_resolve"]; ok {
			cfg.DNSResolve = strings.ToLower(v) != "false"
		}

		if v, ok := check.Settings["asn_db_path"]; ok && v != "" {
			cfg.ASNDBPath = v
		}
	}

	return cfg
}

func clampInt(v, maxV int) int {
	if v < 1 {
		return 1
	}

	if v > maxV {
		return maxV
	}

	return v
}
