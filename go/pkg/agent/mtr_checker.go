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
	"maps"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/go/pkg/scan"
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

	mtrExecutionSourceScheduledSweep = "scheduled_sweep"

	// Bounds for MTR checks derived from sweep groups whose modes include mtr.
	sweepMtrMaxTargetsPerGroup = 256
	sweepMtrMaxChecksPerTick   = 8
	sweepMtrMinInterval        = 5 * time.Minute
)

type mtrCheckConfig struct {
	ID              string
	Name            string
	Target          string
	DeviceID        string
	SweepGroupID    string
	ExecutionSource string
	Interval        time.Duration
	Timeout         time.Duration
	Enabled         bool
	MaxHops         int
	ProbesPerHop    int
	Protocol        mtr.Protocol
	ProbeIntervalMs int
	PacketSize      int
	DNSResolve      bool
	TCPPort         int
	TCPSynRetries   int
}

type mtrCheckResult struct {
	CheckID         string           `json:"check_id"`
	CheckName       string           `json:"check_name"`
	Target          string           `json:"target"`
	DeviceID        string           `json:"device_id,omitempty"`
	SweepGroupID    string           `json:"sweep_group_id,omitempty"`
	ExecutionID     string           `json:"execution_id,omitempty"`
	CommandID       string           `json:"command_id,omitempty"`
	ExecutionSource string           `json:"execution_source,omitempty"`
	Available       bool             `json:"available"`
	Trace           *mtr.TraceResult `json:"trace,omitempty"`
	Timestamp       int64            `json:"timestamp"`
	Error           string           `json:"error,omitempty"`
}

// mtrCheckerState holds per-PushLoop MTR check state.
type mtrCheckerState struct {
	checks      map[string]*mtrCheckConfig
	sweepChecks map[string]*mtrCheckConfig
	lastRun     map[string]time.Time
	runCheck    func(context.Context, *mtrCheckConfig) mtrCheckResult
	mu          sync.RWMutex
}

func newMtrCheckerState() *mtrCheckerState {
	return &mtrCheckerState{
		checks:      make(map[string]*mtrCheckConfig),
		sweepChecks: make(map[string]*mtrCheckConfig),
		lastRun:     make(map[string]time.Time),
	}
}

// pushMtrResults runs due MTR checks and spools their scalar metrics and full
// hop traces. A collection's records go out together, so checks run only while
// the agent holds both the metrics and the scheduled trace grants; without
// them due checks wait, as they wait while the spool refuses a collection.
func (p *PushLoop) pushMtrResults(ctx context.Context) bool {
	spooled := false
	if p.mtrEdge.hasPending() {
		flushed, empty := p.flushPendingMtrEdge()
		if !empty {
			return flushed
		}
		spooled = flushed
	}

	now := time.Now()
	metricsCapability := p.edgeMetricsCapability(now)
	traceCapability := p.edgeScheduledMtrCapability(now)
	if metricsCapability == nil || traceCapability == nil {
		if p.mtrChecksConfigured() {
			p.holdForGrant(edgeProducerMTRTraces)
		}
		return spooled
	}

	results := p.collectDueMtrResults(ctx)
	if len(results) == 0 {
		return spooled
	}

	spooledMetrics := spoolMtrMetricsBatch(p, results, metricsCapability)
	spooledTraces := spoolScheduledMtrTraces(p, results, traceCapability)
	return spooled || spooledMetrics || spooledTraces
}

// mtrChecksConfigured reports whether any MTR check, configured or derived from
// a sweep group, is installed.
func (p *PushLoop) mtrChecksConfigured() bool {
	if p.mtrState == nil {
		return false
	}
	p.mtrState.mu.RLock()
	defer p.mtrState.mu.RUnlock()
	return len(p.mtrState.checks) > 0 || len(p.mtrState.sweepChecks) > 0
}

// collectDueMtrResults runs due MTR checks. Sweep-group checks run at most
// sweepMtrMaxChecksPerTick per call, least recently run first.
func (p *PushLoop) collectDueMtrResults(ctx context.Context) []mtrCheckResult {
	if p.mtrState == nil {
		return nil
	}

	now := time.Now()

	p.mtrState.mu.RLock()
	checks := make([]*mtrCheckConfig, 0, len(p.mtrState.checks))
	for _, check := range p.mtrState.checks {
		checks = append(checks, check)
	}
	sweepChecks := make([]*mtrCheckConfig, 0, len(p.mtrState.sweepChecks))
	for _, check := range p.mtrState.sweepChecks {
		sweepChecks = append(sweepChecks, check)
	}

	lastRun := make(map[string]time.Time, len(p.mtrState.lastRun))
	maps.Copy(lastRun, p.mtrState.lastRun)
	runOverride := p.mtrState.runCheck
	p.mtrState.mu.RUnlock()

	if len(checks) == 0 && len(sweepChecks) == 0 {
		return nil
	}

	isDue := func(check *mtrCheckConfig) bool {
		if check == nil || !check.Enabled || check.Target == "" {
			return false
		}
		interval := check.Interval
		if interval <= 0 {
			interval = p.getInterval()
		}
		last, ok := lastRun[check.ID]
		return !ok || now.Sub(last) >= interval
	}

	checks = slices.DeleteFunc(checks, func(c *mtrCheckConfig) bool { return !isDue(c) })
	slices.SortFunc(checks, func(a, b *mtrCheckConfig) int {
		return strings.Compare(a.ID, b.ID)
	})

	sweepChecks = slices.DeleteFunc(sweepChecks, func(c *mtrCheckConfig) bool { return !isDue(c) })
	slices.SortFunc(sweepChecks, func(a, b *mtrCheckConfig) int {
		if c := lastRun[a.ID].Compare(lastRun[b.ID]); c != 0 {
			return c
		}
		return strings.Compare(a.ID, b.ID)
	})
	if len(sweepChecks) > sweepMtrMaxChecksPerTick {
		sweepChecks = sweepChecks[:sweepMtrMaxChecksPerTick]
	}
	checks = append(checks, sweepChecks...)

	results := make([]mtrCheckResult, 0, len(checks))

	for _, check := range checks {
		run := p.runMtrCheck
		if runOverride != nil {
			run = runOverride
		}
		result := run(ctx, check)
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
		MaxUnknownHops: mtr.DefaultMaxUnknownHops,
		RingBufferSize: mtr.DefaultRingBufferSize,
		TCPPort:        check.TCPPort,
		TCPSynRetries:  check.TCPSynRetries,
	}

	tracer, err := mtr.NewTracer(checkCtx, opts, p.logger)
	if err != nil {
		return mtrCheckResult{
			CheckID:         check.ID,
			CheckName:       check.Name,
			Target:          check.Target,
			DeviceID:        check.DeviceID,
			SweepGroupID:    check.SweepGroupID,
			ExecutionSource: check.ExecutionSource,
			Available:       false,
			Timestamp:       time.Now().UnixNano(),
			Error:           err.Error(),
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
			CheckID:         check.ID,
			CheckName:       check.Name,
			Target:          check.Target,
			DeviceID:        check.DeviceID,
			SweepGroupID:    check.SweepGroupID,
			ExecutionSource: check.ExecutionSource,
			Available:       false,
			Timestamp:       time.Now().UnixNano(),
			Error:           err.Error(),
		}
	}

	return mtrCheckResult{
		CheckID:         check.ID,
		CheckName:       check.Name,
		Target:          check.Target,
		DeviceID:        check.DeviceID,
		SweepGroupID:    check.SweepGroupID,
		ExecutionSource: check.ExecutionSource,
		Available:       trace.TargetReached,
		Trace:           trace,
		Timestamp:       time.Now().UnixNano(),
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

	// mtrState is always set by NewPushLoop; guard for directly-constructed instances
	// (tests) now that the check section runs even when an earlier section deferred.
	if p.mtrState == nil {
		return
	}

	p.mtrState.mu.Lock()
	p.mtrState.checks = parsed

	for id := range p.mtrState.lastRun {
		_, inChecks := parsed[id]
		_, inSweep := p.mtrState.sweepChecks[id]
		if !inChecks && !inSweep {
			delete(p.mtrState.lastRun, id)
		}
	}
	p.mtrState.mu.Unlock()

	if len(parsed) > 0 {
		p.logger.Info().Int("mtr_checks", len(parsed)).Msg("Applied MTR check config from gateway")
	}
}

func (p *PushLoop) updateSweepMtrChecks(checks []*mtrCheckConfig) {
	if p.mtrState == nil {
		return
	}

	byID := make(map[string]*mtrCheckConfig, len(checks))
	for _, cfg := range checks {
		if cfg == nil || cfg.ID == "" {
			continue
		}
		byID[cfg.ID] = cfg
	}

	p.mtrState.mu.Lock()
	p.mtrState.sweepChecks = byID
	for id := range p.mtrState.lastRun {
		_, inChecks := p.mtrState.checks[id]
		_, inSweep := byID[id]
		if !inChecks && !inSweep {
			delete(p.mtrState.lastRun, id)
		}
	}
	p.mtrState.mu.Unlock()
}

func deriveSweepGroupMtrChecks(groups []SweepGroupConfig, log logger.Logger) []*mtrCheckConfig {
	var checks []*mtrCheckConfig
	for _, group := range groups {
		sweepGroupID, groupKey := sweepGroupMtrIdentity(group)
		if groupKey == "" {
			continue
		}

		groupWantsMTR := sweepModesIncludeMTR(group.SweepModes)
		wantsMTR := groupWantsMTR
		for _, dt := range group.DeviceTargets {
			if len(dt.SweepModes) > 0 && sweepModesIncludeMTR(dt.SweepModes) {
				wantsMTR = true
			}
		}
		if !wantsMTR {
			continue
		}

		interval := time.Duration(group.Interval)
		if interval < sweepMtrMinInterval {
			log.Warn().Str("sweep_group", groupKey).Dur("interval", interval).
				Dur("min_interval", sweepMtrMinInterval).
				Msg("Skipping sweep group MTR traces: schedule is not an interval of at least the minimum")
			continue
		}

		var targets []string
		var skippedNetworks []string
		capReached := false
		seen := make(map[string]struct{})
		deviceByTarget := make(map[string]string)
		addTarget := func(target, deviceID string) {
			target = strings.TrimSpace(target)
			if target == "" {
				return
			}
			if _, ok := seen[target]; !ok {
				if len(targets) >= sweepMtrMaxTargetsPerGroup {
					capReached = true
					return
				}
				seen[target] = struct{}{}
				targets = append(targets, target)
			}
			if deviceID != "" && deviceByTarget[target] == "" {
				deviceByTarget[target] = deviceID
			}
		}

		expand := func(network string, budget int) []string {
			ips, skipped := expandSweepMtrTarget(network, budget)
			if skipped {
				skippedNetworks = append(skippedNetworks, strings.TrimSpace(network))
			}
			return ips
		}

		if groupWantsMTR {
			for _, network := range group.Networks {
				for _, ip := range expand(network, sweepMtrMaxTargetsPerGroup-len(targets)) {
					addTarget(ip, "")
				}
			}
		}

		for _, dt := range group.DeviceTargets {
			effectiveModes := dt.SweepModes
			if len(effectiveModes) == 0 {
				effectiveModes = group.SweepModes
			}
			if !sweepModesIncludeMTR(effectiveModes) {
				continue
			}
			deviceID := strings.TrimSpace(dt.Metadata["device_id"])
			if deviceID == "" {
				deviceID = strings.TrimSpace(dt.Metadata["device_uid"])
			}
			for _, ip := range expand(dt.Network, sweepMtrMaxTargetsPerGroup) {
				addTarget(ip, deviceID)
			}
		}

		if len(skippedNetworks) > 0 || capReached {
			log.Warn().Str("sweep_group", groupKey).Strs("skipped_networks", skippedNetworks).
				Bool("target_cap_reached", capReached).Int("max_targets", sweepMtrMaxTargetsPerGroup).
				Int("targets", len(targets)).
				Msg("Sweep group MTR targets exceed the per-group cap; skipped targets are not traced")
		}

		if len(targets) == 0 {
			continue
		}

		timeout := time.Duration(group.Timeout)
		if timeout <= 0 || timeout > mtr.DefaultTimeout {
			timeout = mtr.DefaultTimeout
		}

		checkName := strings.TrimSpace(group.Name)
		if checkName == "" {
			checkName = "sweep-" + groupKey
		}

		for _, target := range targets {
			checks = append(checks, &mtrCheckConfig{
				ID:              "sweep:" + groupKey + ":" + target,
				Name:            checkName,
				Target:          target,
				DeviceID:        deviceByTarget[target],
				SweepGroupID:    sweepGroupID,
				ExecutionSource: mtrExecutionSourceScheduledSweep,
				Interval:        interval,
				Timeout:         timeout,
				Enabled:         true,
				MaxHops:         mtr.DefaultMaxHops,
				ProbesPerHop:    mtr.DefaultProbesPerHop,
				Protocol:        mtr.ProtocolICMP,
				ProbeIntervalMs: mtr.DefaultProbeIntervalMs,
				PacketSize:      mtr.DefaultPacketSize,
				DNSResolve:      true,
				TCPPort:         mtr.DefaultTCPPort,
				TCPSynRetries:   mtr.DefaultTCPSynRetries,
			})
		}
	}
	return checks
}

// sweepGroupMtrIdentity returns the group's canonical UUID (empty when neither
// SweepGroupID nor ID parses as one) and the key used to name its MTR checks.
func sweepGroupMtrIdentity(group SweepGroupConfig) (sweepGroupID, groupKey string) {
	rawGroupID := strings.TrimSpace(group.SweepGroupID)
	if rawGroupID == "" {
		rawGroupID = strings.TrimSpace(group.ID)
	}
	if parsed, err := uuid.Parse(rawGroupID); err == nil {
		sweepGroupID = parsed.String()
	} else if parsed, err := uuid.Parse(strings.TrimSpace(group.ID)); err == nil {
		sweepGroupID = parsed.String()
	}
	if sweepGroupID != "" {
		return sweepGroupID, sweepGroupID
	}
	return "", rawGroupID
}

func sweepModesIncludeMTR(modes []models.SweepMode) bool {
	for _, mode := range modes {
		if mode == models.ModeMTR {
			return true
		}
	}
	return false
}

// expandSweepMtrTarget expands raw into host addresses, skipping any network
// with more than budget addresses and reporting whether it skipped one.
func expandSweepMtrTarget(raw string, budget int) ([]string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, false
	}
	networks, err := normalizeSweepNetwork(raw)
	if err != nil {
		if !strings.Contains(raw, "/") && !strings.Contains(raw, "-") {
			if budget <= 0 {
				return nil, true
			}
			return []string{raw}, false
		}
		return nil, false
	}
	skipped := false
	var out []string
	for _, network := range networks {
		prefix, pErr := netip.ParsePrefix(network)
		if pErr != nil {
			continue
		}
		hostBits := prefix.Addr().BitLen() - prefix.Bits()
		if hostBits >= 63 || budget-len(out) <= 0 || (uint64(1)<<hostBits) > uint64(budget-len(out)) {
			skipped = true
			continue
		}
		ips, expandErr := scan.ExpandCIDR(network)
		if expandErr != nil {
			continue
		}
		out = append(out, ips...)
	}
	return out, skipped
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
		TCPPort:         mtr.DefaultTCPPort,
		TCPSynRetries:   mtr.DefaultTCPSynRetries,
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

		if v, ok := check.Settings["tcp_port"]; ok {
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && validMtrTCPPort(n) {
				cfg.TCPPort = n
			}
		}

		if v, ok := check.Settings["tcp_syn_retries"]; ok {
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && validMtrTCPSynRetries(n) {
				cfg.TCPSynRetries = n
			}
		}

		if v, ok := check.Settings["dns_resolve"]; ok {
			cfg.DNSResolve = strings.ToLower(v) != "false"
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

// validMtrTCPSynRetries reports whether n is an allowed handshake retry count.
func validMtrTCPSynRetries(n int) bool {
	return n >= 0 && n <= mtr.MaxTCPSynRetries
}

// validMtrTCPPort reports whether n is usable as a TCP trace destination port.
func validMtrTCPPort(n int) bool {
	return n > 0 && n <= 65535
}
