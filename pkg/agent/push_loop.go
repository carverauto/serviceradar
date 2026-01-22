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

// Package agent pkg/agent/push_loop.go
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	agentgateway "github.com/carverauto/serviceradar/pkg/agentgateway"
	snmpchecker "github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Version is set at build time via -ldflags
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var Version = "dev"

const (
	// configSourceRemote is the config source value for configs from the gateway.
	configSourceRemote = "remote"
)

var (
	errSweepMissingHosts  = errors.New("sweep data missing hosts field")
	errSweepHostsNotArray = errors.New("hosts field is not an array")
)

type icmpCheckConfig struct {
	ID       string
	Name     string
	Target   string
	DeviceID string
	Interval time.Duration
	Timeout  time.Duration
	Enabled  bool
}

type icmpCheckResult struct {
	CheckID        string  `json:"check_id"`
	CheckName      string  `json:"check_name"`
	Target         string  `json:"target"`
	DeviceID       string  `json:"device_id,omitempty"`
	Available      bool    `json:"available"`
	ResponseTimeNs int64   `json:"response_time_ns"`
	PacketLoss     float64 `json:"packet_loss"`
	Timestamp      int64   `json:"timestamp"`
	Error          string  `json:"error,omitempty"`
}

type snmpMetricResult struct {
	Target       string      `json:"target"`
	Host         string      `json:"host"`
	Metric       string      `json:"metric"`
	OID          string      `json:"oid"`
	Value        interface{} `json:"value"`
	Timestamp    time.Time   `json:"timestamp"`
	DataType     string      `json:"data_type,omitempty"`
	Scale        float64     `json:"scale,omitempty"`
	Delta        bool        `json:"delta,omitempty"`
	IfIndex      *int        `json:"if_index,omitempty"`
	InterfaceUID string      `json:"interface_uid,omitempty"`
}

// PushLoop manages the periodic pushing of agent status to the gateway.
type PushLoop struct {
	server             *Server
	gateway            *agentgateway.GatewayClient
	interval           time.Duration
	logger             logger.Logger
	done               chan struct{}
	stopCh             chan struct{}
	stopOnce           sync.Once
	doneOnce           sync.Once
	configVersion      string        // Current config version for polling
	configPollInterval time.Duration // How often to poll for config updates
	enrolled           bool          // Whether we've successfully enrolled
	started            bool          // Whether Start has been invoked
	enrollMu           sync.Mutex
	enrollInFlight     bool
	sweepResultsSeq    string
	icmpChecks         map[string]*icmpCheckConfig
	icmpLastRun        map[string]time.Time
	icmpMu             sync.RWMutex
	snmpLastSent       map[string]time.Time
	snmpMu             sync.RWMutex

	stateMu  sync.RWMutex // Protects interval, configPollInterval, enrolled, configVersion, started
	cancelMu sync.Mutex
	cancel   context.CancelFunc
}

// Thread-safe accessors for shared state

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

func (p *PushLoop) setConfigPollInterval(d time.Duration) {
	p.stateMu.Lock()
	p.configPollInterval = d
	p.stateMu.Unlock()
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

// Default intervals
const (
	defaultPushInterval       = 30 * time.Second
	defaultConfigPollInterval = 60 * time.Second
	defaultEnrollRetryDelay   = 2 * time.Second
	maxEnrollRetryDelay       = 30 * time.Second
)

// NewPushLoop creates a new push loop.
func NewPushLoop(server *Server, gateway *agentgateway.GatewayClient, interval time.Duration, log logger.Logger) *PushLoop {
	if interval <= 0 {
		interval = defaultPushInterval
	}

	return &PushLoop{
		server:             server,
		gateway:            gateway,
		interval:           interval,
		logger:             log,
		done:               make(chan struct{}),
		stopCh:             make(chan struct{}),
		configPollInterval: defaultConfigPollInterval,
		icmpChecks:         make(map[string]*icmpCheckConfig),
		icmpLastRun:        make(map[string]time.Time),
		snmpLastSent:       make(map[string]time.Time),
	}
}

// Start begins the push loop. It runs until the context is cancelled or Stop is called.
func (p *PushLoop) Start(ctx context.Context) error {
	// Ensure done is closed when Start exits (only once)
	defer p.doneOnce.Do(func() { close(p.done) })

	runCtx, cancel := context.WithCancel(ctx)
	p.cancelMu.Lock()
	p.cancel = cancel
	p.cancelMu.Unlock()
	defer cancel()

	p.stateMu.Lock()
	p.started = true
	p.stateMu.Unlock()

	p.logger.Info().Dur("interval", p.getInterval()).Msg("Starting push loop")

	// Initial connection and enrollment attempt
	if err := p.gateway.Connect(runCtx); err != nil {
		p.logger.Warn().Err(err).Msg("Initial gateway connection failed, will retry")
	} else {
		// Connected, try to enroll
		p.enroll(runCtx)
	}

	// Start config polling in a separate goroutine
	go p.configPollLoop(runCtx)

	// Use a resettable timer so updated intervals take effect
	timer := time.NewTimer(0) // fire immediately for first tick
	defer timer.Stop()

	for {
		select {
		case <-runCtx.Done():
			p.logger.Info().Msg("Push loop stopping due to context cancellation")
			return runCtx.Err()

		case <-p.stopCh:
			p.logger.Info().Msg("Push loop stopping due to Stop()")
			return context.Canceled

		case <-timer.C:
			if p.isEnrolled() {
				// Normal operation: push status
				p.pushStatus(runCtx)
			} else {
				// Not enrolled: attempt to connect and enroll
				p.attemptConnectionAndEnrollment(runCtx)
			}
			timer.Reset(p.getInterval())
		}
	}
}

// Stop signals the push loop to stop and waits for it to exit.
// Closes done channel if Start() was never called to prevent deadlock.
func (p *PushLoop) Stop(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}

	p.stopOnce.Do(func() { close(p.stopCh) })
	p.cancelMu.Lock()
	if p.cancel != nil {
		p.cancel()
	}
	p.cancelMu.Unlock()

	p.stateMu.RLock()
	started := p.started
	p.stateMu.RUnlock()
	if !started {
		p.doneOnce.Do(func() { close(p.done) })
		return nil
	}
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// attemptConnectionAndEnrollment tries to establish gateway connection and enroll.
// Called periodically when the agent is not yet enrolled.
func (p *PushLoop) attemptConnectionAndEnrollment(ctx context.Context) {
	if p.gateway.IsConnected() {
		// Already connected, just try to enroll
		p.enroll(ctx)
		return
	}

	// Not connected, attempt reconnection with backoff
	p.logger.Debug().Msg("Attempting gateway connection")
	if err := p.gateway.ReconnectWithBackoff(ctx); err != nil {
		p.logger.Warn().Err(err).Msg("Gateway connection attempt failed")
		return
	}

	// Connected, now try to enroll
	p.logger.Info().Msg("Gateway connection established, attempting enrollment")
	p.enroll(ctx)
}

// pushStatus collects status from all services and pushes to the gateway.
func (p *PushLoop) pushStatus(ctx context.Context) {
	// Ensure we're connected
	if !p.gateway.IsConnected() {
		if err := p.gateway.ReconnectWithBackoff(ctx); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to reconnect to gateway")
			return
		}
		// Re-enroll after reconnect
		p.setEnrolled(false)
		p.enroll(ctx)
	}

	// Skip pushing if not enrolled
	if !p.isEnrolled() {
		p.logger.Debug().Msg("Not enrolled, skipping status push")
		return
	}

	// Collect statuses, separating sysmon from other services
	statuses, sysmonStatus := p.collectAllStatusesSeparated(ctx)

	// Push regular statuses via PushStatus
	if len(statuses) > 0 {
		p.pushRegularStatuses(ctx, statuses)
	}

	// Push sysmon via StreamStatus (it can have large payloads with all processes)
	if sysmonStatus != nil {
		p.pushSysmonStatus(ctx, sysmonStatus)
	}

	sentICMPResults := p.pushICMPResults(ctx)
	sentSweepResults := p.pushSweepResults(ctx)
	sentMapperResults := p.pushMapperResults(ctx)
	sentMapperInterfaces := p.pushMapperInterfaces(ctx)
	sentMapperTopology := p.pushMapperTopology(ctx)
	sentSNMPMetrics := p.pushSNMPMetrics(ctx)

	if len(statuses) == 0 &&
		sysmonStatus == nil &&
		!sentICMPResults &&
		!sentSweepResults &&
		!sentMapperResults &&
		!sentMapperInterfaces &&
		!sentMapperTopology &&
		!sentSNMPMetrics {
		p.logger.Debug().Msg("No statuses to push")
	}
}

// pushRegularStatuses sends non-sysmon statuses via PushStatus.
func (p *PushLoop) pushRegularStatuses(ctx context.Context, statuses []*proto.GatewayServiceStatus) {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	req := &proto.GatewayStatusRequest{
		Services:  statuses,
		GatewayId: "", // Will be set by the gateway
		AgentId:   agentID,
		Timestamp: time.Now().UnixNano(),
		Partition: partition,
		SourceIp:  p.getSourceIP(),
		KvStoreId: kvStoreID,
	}

	resp, err := p.gateway.PushStatus(ctx, req)
	if err != nil {
		p.logger.Error().Err(err).Int("status_count", len(statuses)).Msg("Failed to push status to gateway")
		return
	}

	if resp.Received {
		p.logger.Info().Int("status_count", len(statuses)).Msg("Successfully pushed status to gateway")
	} else {
		p.logger.Warn().Msg("Gateway did not acknowledge status push")
	}
}

// pushSysmonStatus sends sysmon metrics via StreamStatus for large payloads.
func (p *PushLoop) pushSysmonStatus(ctx context.Context, status *proto.GatewayServiceStatus) {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	// Build a single chunk for sysmon metrics
	chunk := &proto.GatewayStatusChunk{
		Services:    []*proto.GatewayServiceStatus{status},
		GatewayId:   "",
		AgentId:     agentID,
		Timestamp:   time.Now().UnixNano(),
		Partition:   partition,
		SourceIp:    p.getSourceIP(),
		IsFinal:     true,
		ChunkIndex:  0,
		TotalChunks: 1,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, []*proto.GatewayStatusChunk{chunk})
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream sysmon metrics to gateway")
		return
	}

	if resp.Received {
		p.logger.Info().Msg("Successfully streamed sysmon metrics to gateway")
	} else {
		p.logger.Warn().Msg("Gateway did not acknowledge sysmon metrics stream")
	}
}

func (p *PushLoop) pushSNMPMetrics(ctx context.Context) bool {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	snmpSvc := p.server.snmpService
	p.server.mu.RUnlock()

	if snmpSvc == nil || !snmpSvc.IsEnabled() {
		return false
	}

	statuses, err := snmpSvc.GetTargetStatuses(ctx)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to get SNMP target status")
		return false
	}
	if len(statuses) == 0 {
		return false
	}

	results := p.buildSNMPMetricsResults(statuses)
	if len(results) == 0 {
		return false
	}

	payload := map[string]interface{}{
		"results": results,
	}

	messageBytes, err := json.Marshal(payload)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to marshal SNMP metrics payload")
		return false
	}

	status := &proto.GatewayServiceStatus{
		ServiceName:  "snmp",
		Available:    true,
		Message:      messageBytes,
		ServiceType:  "snmp",
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    "",
		Partition:    partition,
		Source:       "snmp-metrics",
		KvStoreId:    kvStoreID,
	}

	chunk := &proto.GatewayStatusChunk{
		Services:    []*proto.GatewayServiceStatus{status},
		GatewayId:   "",
		AgentId:     agentID,
		Timestamp:   time.Now().UnixNano(),
		Partition:   partition,
		SourceIp:    p.getSourceIP(),
		IsFinal:     true,
		ChunkIndex:  0,
		TotalChunks: 1,
		KvStoreId:   kvStoreID,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, []*proto.GatewayStatusChunk{chunk})
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream SNMP metrics to gateway")
		return false
	}

	if resp.Received {
		p.logger.Info().Msg("Successfully streamed SNMP metrics to gateway")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge SNMP metrics stream")
	return false
}

func (p *PushLoop) buildSNMPMetricsResults(
	statuses map[string]snmpchecker.TargetStatus,
) []snmpMetricResult {
	results := make([]snmpMetricResult, 0)

	for targetName, status := range statuses {
		oidConfigs := make(map[string]snmpchecker.OIDConfig)
		if status.Target != nil {
			for _, oid := range status.Target.OIDs {
				oidConfigs[oid.Name] = oid
			}
		}

		for oidName, oidStatus := range status.OIDStatus {
			if oidStatus.LastUpdate.IsZero() || oidStatus.LastValue == nil {
				continue
			}

			cacheKey := targetName + "|" + oidName
			if !p.shouldSendSNMPMetric(cacheKey, oidStatus.LastUpdate) {
				continue
			}

			oidConfig, ok := oidConfigs[oidName]
			oidValue := ""
			dataType := ""
			scale := 1.0
			delta := false
			if ok {
				oidValue = oidConfig.OID
				dataType = string(oidConfig.DataType)
				scale = oidConfig.Scale
				delta = oidConfig.Delta
			}

			metricName, interfaceUID := parseSNMPMetricName(oidName)
			ifIndex := parseIfIndexFromOID(oidValue)

			result := snmpMetricResult{
				Target:       targetName,
				Host:         status.HostIP,
				Metric:       metricName,
				OID:          oidValue,
				Value:        oidStatus.LastValue,
				Timestamp:    oidStatus.LastUpdate,
				DataType:     dataType,
				Scale:        scale,
				Delta:        delta,
				InterfaceUID: interfaceUID,
			}

			if ifIndex != nil {
				result.IfIndex = ifIndex
			}

			results = append(results, result)
			p.markSNMPMetricSent(cacheKey, oidStatus.LastUpdate)
		}
	}

	return results
}

func (p *PushLoop) shouldSendSNMPMetric(key string, ts time.Time) bool {
	p.snmpMu.RLock()
	last, ok := p.snmpLastSent[key]
	p.snmpMu.RUnlock()

	if !ok {
		return true
	}

	return ts.After(last)
}

func (p *PushLoop) markSNMPMetricSent(key string, ts time.Time) {
	p.snmpMu.Lock()
	if last, ok := p.snmpLastSent[key]; !ok || ts.After(last) {
		p.snmpLastSent[key] = ts
	}
	p.snmpMu.Unlock()
}

func parseSNMPMetricName(raw string) (string, string) {
	if raw == "" {
		return "", ""
	}

	parts := strings.SplitN(raw, "::", 2)
	if len(parts) == 2 {
		return parts[0], parts[1]
	}

	return raw, ""
}

func parseIfIndexFromOID(oid string) *int {
	oid = strings.TrimSpace(oid)
	if oid == "" {
		return nil
	}

	parts := strings.Split(oid, ".")
	if len(parts) == 0 {
		return nil
	}

	last := parts[len(parts)-1]
	if last == "" {
		return nil
	}

	value, err := strconv.Atoi(last)
	if err != nil || value <= 0 {
		return nil
	}

	return &value
}

func (p *PushLoop) pushSweepResults(ctx context.Context) bool {
	sweepSvc := p.findSweepService()
	if sweepSvc == nil {
		return false
	}

	lastSequence := p.getSweepResultsSequence()
	response, err := sweepSvc.GetSweepResults(ctx, lastSequence)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to get sweep results")
		return false
	}

	if response == nil {
		return false
	}

	pendingSeq := response.CurrentSequence

	if !response.HasNewData || len(response.Data) == 0 {
		if pendingSeq != "" {
			p.setSweepResultsSequence(pendingSeq)
		}
		return false
	}

	chunks, err := buildSweepResultsChunks(response)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to chunk sweep results")
		return false
	}

	serviceName := response.ServiceName
	if serviceName == "" {
		serviceName = "network_sweep"
	}

	serviceType := response.ServiceType
	if serviceType == "" {
		serviceType = sweepType
	}

	statusChunks := p.buildResultsStatusChunks(chunks, serviceName, serviceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	_, err = p.gateway.StreamStatus(pushCtx, statusChunks)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream sweep results to gateway")
		return false
	}

	if pendingSeq != "" {
		p.setSweepResultsSequence(pendingSeq)
	}

	p.logger.Info().
		Str("service_name", serviceName).
		Int("chunk_count", len(statusChunks)).
		Msg("Streamed sweep results to gateway")

	return true
}

func (p *PushLoop) pushICMPResults(ctx context.Context) bool {
	results := p.collectDueICMPResults(ctx)
	if len(results) == 0 {
		return false
	}

	payload := map[string]interface{}{
		"results": results,
	}

	data, err := json.Marshal(payload)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal ICMP results payload")
		return false
	}

	chunk := &proto.ResultsChunk{
		Data:        data,
		IsFinal:     true,
		ChunkIndex:  0,
		TotalChunks: 1,
		Timestamp:   time.Now().UnixNano(),
	}

	statusChunks := p.buildResultsStatusChunks([]*proto.ResultsChunk{chunk}, "icmp_checks", "icmp")
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if _, err := p.gateway.StreamStatus(pushCtx, statusChunks); err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream ICMP results to gateway")
		return false
	}

	p.logger.Info().Int("result_count", len(results)).Msg("Streamed ICMP results to gateway")
	return true
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

func buildSweepResultsChunks(response *proto.ResultsResponse) ([]*proto.ResultsChunk, error) {
	if response == nil {
		return nil, nil
	}

	if len(response.Data) == 0 {
		return nil, nil
	}

	maxChunkSize, maxHostsPerChunk := sweepResultsChunkLimits()

	if len(response.Data) <= maxChunkSize {
		return []*proto.ResultsChunk{{
			Data:            response.Data,
			IsFinal:         true,
			ChunkIndex:      0,
			TotalChunks:     1,
			CurrentSequence: response.CurrentSequence,
			Timestamp:       response.Timestamp,
		}}, nil
	}

	var sweepData map[string]interface{}
	if err := json.Unmarshal(response.Data, &sweepData); err != nil {
		return nil, fmt.Errorf("parse sweep data: %w", err)
	}

	hostsInterface, ok := sweepData["hosts"]
	if !ok {
		return nil, errSweepMissingHosts
	}

	hosts, ok := hostsInterface.([]interface{})
	if !ok {
		return nil, errSweepHostsNotArray
	}

	totalHosts := len(hosts)

	metadata := make(map[string]interface{})
	for key, value := range sweepData {
		if key != "hosts" {
			metadata[key] = value
		}
	}

	baseData := make(map[string]interface{}, len(metadata))
	for key, value := range metadata {
		baseData[key] = value
	}
	baseData["hosts"] = []interface{}{}

	baseBytes, err := json.Marshal(baseData)
	if err != nil {
		return nil, fmt.Errorf("marshal sweep metadata: %w", err)
	}

	baseSize := len(baseBytes) - 2
	if baseSize < 0 {
		baseSize = len(baseBytes)
	}

	hostSizes := make([]int, totalHosts)
	for i, host := range hosts {
		hostBytes, err := json.Marshal(host)
		if err != nil {
			return nil, fmt.Errorf("marshal sweep host %d: %w", i, err)
		}
		hostSizes[i] = len(hostBytes)
	}

	type hostRange struct {
		start int
		end   int
	}

	var ranges []hostRange
	start := 0
	currentSize := baseSize + 2

	for i, hostSize := range hostSizes {
		additional := hostSize
		if i > start {
			additional++
		}

		if (currentSize+additional > maxChunkSize || i-start >= maxHostsPerChunk) && i > start {
			ranges = append(ranges, hostRange{start: start, end: i})
			start = i
			currentSize = baseSize + 2
			additional = hostSize
		}

		currentSize += additional
	}

	if start < totalHosts {
		ranges = append(ranges, hostRange{start: start, end: totalHosts})
	}

	totalChunks := len(ranges)
	chunks := make([]*proto.ResultsChunk, 0, totalChunks)

	for chunkIndex, chunkRange := range ranges {
		chunkHosts := hosts[chunkRange.start:chunkRange.end]

		chunkData := make(map[string]interface{}, len(metadata))
		for key, value := range metadata {
			chunkData[key] = value
		}
		chunkData["hosts"] = chunkHosts

		chunkBytes, err := json.Marshal(chunkData)
		if err != nil {
			return nil, fmt.Errorf("marshal sweep chunk %d: %w", chunkIndex, err)
		}

		chunks = append(chunks, &proto.ResultsChunk{
			Data:            chunkBytes,
			IsFinal:         chunkIndex == totalChunks-1,
			ChunkIndex:      int32(chunkIndex),
			TotalChunks:     int32(totalChunks),
			CurrentSequence: response.CurrentSequence,
			Timestamp:       response.Timestamp,
		})
	}

	return chunks, nil
}

// collectAllStatusesSeparated gathers status from all services, separating sysmon from others.
// Sysmon is returned separately because it uses StreamStatus with Source: "sysmon-metrics".
func (p *PushLoop) collectAllStatusesSeparated(ctx context.Context) ([]*proto.GatewayServiceStatus, *proto.GatewayServiceStatus) {
	var statuses []*proto.GatewayServiceStatus
	var sysmonStatus *proto.GatewayServiceStatus

	// Collect from sweep services (SweepStatusProvider)
	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	sysmonSvc := p.server.sysmonService
	p.server.mu.RUnlock()

	for _, svc := range services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			status, err := provider.GetStatus(ctx)
			if err != nil {
				p.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to get status from service")
				continue
			}

			statuses = append(statuses, p.convertToGatewayStatus(status, svc.Name(), sweepType))
		}
	}

	// Collect from embedded sysmon service - separate from regular statuses
	if sysmonSvc != nil && sysmonSvc.IsEnabled() {
		status, err := sysmonSvc.GetStatus(ctx)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Failed to get sysmon status")
		} else if status != nil {
			sysmonStatus = p.convertToSysmonGatewayStatus(status)
		}
	}

	if status, err := p.server.GetSNMPStatus(ctx); err == nil && status != nil {
		statuses = append(statuses, p.convertToGatewayStatus(status, status.ServiceName, status.ServiceType))
	}

	if status, err := p.server.GetDuskStatus(ctx); err == nil && status != nil {
		statuses = append(statuses, p.convertToGatewayStatus(status, status.ServiceName, status.ServiceType))
	}

	return statuses, sysmonStatus
}

func (p *PushLoop) findSweepService() *SweepService {
	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	p.server.mu.RUnlock()

	for _, svc := range services {
		if sweepSvc, ok := svc.(*SweepService); ok {
			return sweepSvc
		}
	}

	return nil
}

// convertToGatewayStatus converts a StatusResponse to a GatewayServiceStatus.
func (p *PushLoop) convertToGatewayStatus(resp *proto.StatusResponse, serviceName, serviceType string) *proto.GatewayServiceStatus {
	if resp == nil {
		return nil
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	return &proto.GatewayServiceStatus{
		ServiceName:  serviceName,
		Available:    resp.Available,
		Message:      resp.Message,
		ServiceType:  serviceType,
		ResponseTime: resp.ResponseTime,
		AgentId:      agentID,
		GatewayId:    "", // Will be set by gateway
		Partition:    partition,
		Source:       "status",
		KvStoreId:    kvStoreID,
	}
}

// convertToSysmonGatewayStatus converts a sysmon StatusResponse to a GatewayServiceStatus.
// Uses Source: "sysmon-metrics" to distinguish from other metrics sources (e.g., SNMP).
func (p *PushLoop) convertToSysmonGatewayStatus(resp *proto.StatusResponse) *proto.GatewayServiceStatus {
	if resp == nil {
		return nil
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	return &proto.GatewayServiceStatus{
		ServiceName:  SysmonServiceName,
		Available:    resp.Available,
		Message:      resp.Message,
		ServiceType:  SysmonServiceType,
		ResponseTime: resp.ResponseTime,
		AgentId:      agentID,
		GatewayId:    "", // Will be set by gateway
		Partition:    partition,
		Source:       "sysmon-metrics",
		KvStoreId:    kvStoreID,
	}
}

func (p *PushLoop) buildResultsStatusChunks(
	chunks []*proto.ResultsChunk,
	serviceName string,
	serviceType string,
) []*proto.GatewayStatusChunk {
	if len(chunks) == 0 {
		return nil
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()
	gatewayID := ""

	statusChunks := make([]*proto.GatewayStatusChunk, 0, len(chunks))

	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}

		status := &proto.GatewayServiceStatus{
			ServiceName:  serviceName,
			Available:    true,
			Message:      chunk.Data,
			ServiceType:  serviceType,
			ResponseTime: 0,
			AgentId:      agentID,
			GatewayId:    gatewayID,
			Partition:    partition,
			Source:       "results",
			KvStoreId:    "",
		}

		statusChunks = append(statusChunks, &proto.GatewayStatusChunk{
			Services:    []*proto.GatewayServiceStatus{status},
			GatewayId:   gatewayID,
			AgentId:     agentID,
			Timestamp:   chunk.Timestamp,
			Partition:   partition,
			IsFinal:     chunk.IsFinal,
			ChunkIndex:  chunk.ChunkIndex,
			TotalChunks: chunk.TotalChunks,
			KvStoreId:   "",
		})
	}

	return statusChunks
}

// getSourceIP attempts to determine the source IP of this agent.
func (p *PushLoop) getSourceIP() string {
	// First check if HostIP is configured
	p.server.mu.RLock()
	hostIP := p.server.config.HostIP
	p.server.mu.RUnlock()
	if hostIP != "" {
		return hostIP
	}

	// Enumerate local interfaces to find a non-loopback IP
	// This avoids unexpected external network egress
	ifaces, err := net.Interfaces()
	if err != nil {
		p.logger.Debug().Err(err).Msg("Failed to enumerate network interfaces")
		return ""
	}

	var (
		publicIPv4 string
		ipv6       string
	)

	for _, iface := range ifaces {
		// Skip down interfaces and loopback
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			// Skip loopback and link-local addresses, prefer IPv4
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}

			// Prefer RFC1918 IPv4 addresses; fall back to any global unicast.
			if ip4 := ip.To4(); ip4 != nil {
				if ip4.IsPrivate() {
					return ip4.String()
				}
				if publicIPv4 == "" && ip4.IsGlobalUnicast() {
					publicIPv4 = ip4.String()
				}
				continue
			}

			// Fallback to IPv6 if no IPv4 is present (avoid empty source_ip on IPv6-only hosts)
			if ipv6 == "" && ip.IsGlobalUnicast() {
				ipv6 = ip.String()
			}
		}
	}

	if publicIPv4 != "" {
		return publicIPv4
	}
	if ipv6 != "" {
		return ipv6
	}

	p.logger.Debug().Msg("No suitable source IP found")
	return ""
}

// enroll starts the enrollment loop (single in-flight attempt with retries).
func (p *PushLoop) enroll(ctx context.Context) {
	p.enrollMu.Lock()
	if p.enrollInFlight {
		p.enrollMu.Unlock()
		return
	}
	p.enrollInFlight = true
	p.enrollMu.Unlock()

	go p.enrollLoop(ctx)
}

func (p *PushLoop) enrollLoop(ctx context.Context) {
	defer func() {
		p.enrollMu.Lock()
		p.enrollInFlight = false
		p.enrollMu.Unlock()
	}()

	p.logger.Info().Msg("Enrolling with gateway...")

	delay := defaultEnrollRetryDelay
	for {
		if ctx.Err() != nil {
			return
		}

		if err := p.enrollOnce(ctx); err == nil {
			return
		} else if isRetryableEnrollError(err) {
			p.logger.Warn().
				Err(err).
				Dur("retry_in", delay).
				Msg("Enrollment failed, retrying")
		} else {
			p.logger.Error().Err(err).Msg("Failed to enroll with gateway")
			return
		}

		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-p.stopCh:
			timer.Stop()
			return
		case <-timer.C:
		}

		delay *= 2
		if delay > maxEnrollRetryDelay {
			delay = maxEnrollRetryDelay
		}
	}
}

// enrollOnce sends Hello to the gateway and fetches initial config.
func (p *PushLoop) enrollOnce(ctx context.Context) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}

	if !p.gateway.IsConnected() {
		if err := p.gateway.ReconnectWithBackoff(ctx); err != nil {
			return err
		}
	}

	// Build Hello request
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()
	helloReq := &proto.AgentHelloRequest{
		AgentId:       agentID,
		Version:       Version, // Agent version from version.go
		Capabilities:  getAgentCapabilities(),
		ConfigVersion: p.getConfigVersion(),
	}

	// Send Hello
	helloResp, err := p.gateway.Hello(ctx, helloReq)
	if err != nil {
		return err
	}

	// Update push interval if specified by gateway
	if helloResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(helloResp.HeartbeatIntervalSec) * time.Second
		if newInterval < time.Second {
			newInterval = time.Second
		}
		if newInterval > time.Hour {
			newInterval = time.Hour
		}
		if newInterval != p.getInterval() {
			p.setInterval(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Updated push interval from gateway")
		}
	}

	p.setEnrolled(true)
	p.logger.Info().
		Str("agent_id", helloResp.AgentId).
		Str("gateway_id", helloResp.GatewayId).
		Msg("Successfully enrolled with gateway")

	// Fetch initial config if outdated or not yet fetched
	if helloResp.ConfigOutdated || p.getConfigVersion() == "" {
		p.fetchAndApplyConfig(ctx)
	}

	return nil
}

func isRetryableEnrollError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	if errors.Is(err, agentgateway.ErrGatewayNotConnected) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded:
		return true
	case codes.OK,
		codes.Canceled,
		codes.Unknown,
		codes.InvalidArgument,
		codes.NotFound,
		codes.AlreadyExists,
		codes.PermissionDenied,
		codes.ResourceExhausted,
		codes.FailedPrecondition,
		codes.Aborted,
		codes.OutOfRange,
		codes.Unimplemented,
		codes.Internal,
		codes.DataLoss,
		codes.Unauthenticated:
		return false
	}
	return false
}

// configPollLoop periodically polls for config updates.
func (p *PushLoop) configPollLoop(ctx context.Context) {
	// Wait for initial enrollment before polling
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for !p.isEnrolled() {
		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		case <-ticker.C:
			// Keep waiting
		}
	}

	// Use a resettable timer so updated intervals take effect
	timer := time.NewTimer(p.getConfigPollInterval())
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			p.logger.Debug().Msg("Config poll loop stopping")
			return
		case <-p.stopCh:
			p.logger.Debug().Msg("Config poll loop stopping due to Stop()")
			return
		case <-timer.C:
			if p.gateway.IsConnected() && p.isEnrolled() {
				p.fetchAndApplyConfig(ctx)
			}
			timer.Reset(p.getConfigPollInterval())
		}
	}
}

// fetchAndApplyConfig fetches config from gateway and applies it.
func (p *PushLoop) fetchAndApplyConfig(ctx context.Context) {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()
	configReq := &proto.AgentConfigRequest{
		AgentId:       agentID,
		ConfigVersion: p.getConfigVersion(),
	}

	configResp, err := p.gateway.GetConfig(ctx, configReq)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to fetch config from gateway")
		return
	}

	// If config hasn't changed, nothing to do
	if configResp.NotModified {
		p.logger.Debug().Str("version", p.getConfigVersion()).Msg("Config not modified")
		return
	}

	// Update intervals from config response
	if configResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(configResp.HeartbeatIntervalSec) * time.Second
		if newInterval < time.Second {
			newInterval = time.Second
		}
		if newInterval > time.Hour {
			newInterval = time.Hour
		}
		if newInterval != p.getInterval() {
			p.setInterval(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Updated push interval from config")
		}
	}

	if configResp.ConfigPollIntervalSec > 0 {
		newPollInterval := time.Duration(configResp.ConfigPollIntervalSec) * time.Second
		// Safety bounds to avoid gateway/agent overload or "never poll" configurations.
		const (
			minConfigPollInterval = 30 * time.Second
			maxConfigPollInterval = 24 * time.Hour
		)
		if newPollInterval < minConfigPollInterval {
			newPollInterval = minConfigPollInterval
		} else if newPollInterval > maxConfigPollInterval {
			newPollInterval = maxConfigPollInterval
		}
		if newPollInterval != p.getConfigPollInterval() {
			p.setConfigPollInterval(newPollInterval)
			p.logger.Info().Dur("interval", newPollInterval).Msg("Updated config poll interval")
		}
	}

	p.applySweepConfig(configResp.ConfigJson)
	p.applyMapperConfig(configResp.ConfigJson)

	// Apply sysmon config if present
	if configResp.SysmonConfig != nil {
		p.applySysmonConfig(configResp.SysmonConfig)
	}

	// Apply SNMP config if present
	if configResp.SnmpConfig != nil {
		p.applySNMPConfig(configResp.SnmpConfig)
	}

	// Apply dusk config if present
	if configResp.DuskConfig != nil {
		p.applyDuskConfig(configResp.DuskConfig)
	}

	// Apply check configs (icmp checks supported)
	p.applyCheckConfigs(configResp.Checks)

	// Update version
	p.setConfigVersion(configResp.ConfigVersion)
	p.logger.Info().
		Str("version", p.getConfigVersion()).
		Msg("Applied new config from gateway")
}

func (p *PushLoop) applyMapperConfig(configJSON []byte) {
	mapperConfig, err := parseGatewayMapperConfig(configJSON)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to parse mapper config from gateway")
		return
	}

	if mapperConfig == nil {
		return
	}

	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	cfg := p.server.config
	p.server.mu.RUnlock()

	compiled, err := buildMapperEngineConfig(mapperConfig, cfg, p.logger)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build mapper config from gateway payload")
		return
	}

	if mapperSvc == nil {
		service, err := NewMapperService(compiled, p.logger)
		if err != nil {
			p.logger.Error().Err(err).Msg("Failed to initialize mapper service")
			return
		}
		mapperSvc = service
		p.server.mu.Lock()
		p.server.mapperService = mapperSvc
		p.server.mu.Unlock()
	}

	if mapperConfig.ConfigHash != "" && mapperSvc.GetConfigHash() == mapperConfig.ConfigHash {
		p.logger.Debug().Str("config_hash", mapperConfig.ConfigHash).Msg("Mapper config unchanged")
		return
	}

	if err := mapperSvc.ApplyMapperConfig(compiled, mapperConfig.ConfigHash); err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply mapper config from gateway")
		return
	}

	p.logger.Info().
		Str("config_hash", mapperConfig.ConfigHash).
		Int("scheduled_jobs", len(mapperConfig.ScheduledJobs)).
		Msg("Applied mapper config from gateway")
}

func (p *PushLoop) pushMapperResults(ctx context.Context) bool {
	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	if mapperSvc == nil {
		return false
	}

	updates, ok := mapperSvc.DrainResults(1000)
	if !ok || len(updates) == 0 {
		return false
	}

	payload, err := buildMapperResultsPayload(updates, agentID, partition)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build mapper results payload")
		return false
	}

	if len(payload) == 0 {
		return false
	}

	seq := fmt.Sprintf("%d", time.Now().UnixNano())

	response := mapperResultsResponse(payload, seq, "mapper", mapperServiceType)
	chunks := []*proto.ResultsChunk{{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	}}

	statusChunks := p.buildResultsStatusChunks(chunks, response.ServiceName, response.ServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	_, err = p.gateway.StreamStatus(pushCtx, statusChunks)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream mapper results to gateway")
		return false
	}

	p.logger.Info().
		Int("update_count", len(updates)).
		Msg("Streamed mapper results to gateway")

	return true
}

func (p *PushLoop) pushMapperInterfaces(ctx context.Context) bool {
	return p.pushMapperDerivedResults(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainInterfaces(1000)
		},
		buildMapperInterfacePayload,
		"mapper_interfaces",
		"interface_count",
	)
}

func (p *PushLoop) pushMapperTopology(ctx context.Context) bool {
	return p.pushMapperDerivedResults(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainTopology(1000)
		},
		buildMapperTopologyPayload,
		"mapper_topology",
		"topology_count",
	)
}

func (p *PushLoop) pushMapperDerivedResults(
	ctx context.Context,
	drain func(*MapperService) ([]map[string]interface{}, bool),
	buildPayload func([]map[string]interface{}, string, string) ([]byte, error),
	serviceType string,
	countField string,
) bool {
	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	if mapperSvc == nil {
		return false
	}

	updates, ok := drain(mapperSvc)
	if !ok || len(updates) == 0 {
		return false
	}

	payload, err := buildPayload(updates, agentID, partition)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build mapper payload")
		return false
	}

	if len(payload) == 0 {
		return false
	}

	seq := fmt.Sprintf("%d", time.Now().UnixNano())
	response := mapperResultsResponse(payload, seq, "mapper", serviceType)
	chunks := []*proto.ResultsChunk{{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	}}

	statusChunks := p.buildResultsStatusChunks(chunks, response.ServiceName, response.ServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	_, err = p.gateway.StreamStatus(pushCtx, statusChunks)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream mapper results to gateway")
		return false
	}

	p.logger.Info().Int(countField, len(updates)).Msg("Streamed mapper results to gateway")

	return true
}

func (p *PushLoop) applySweepConfig(configJSON []byte) {
	sweepSvc := p.findSweepService()
	if sweepSvc == nil {
		return
	}

	sweepConfig, err := parseGatewaySweepConfig(configJSON, p.logger)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to parse sweep config from gateway")
		return
	}

	if sweepConfig == nil {
		return
	}

	if sweepConfig.ConfigHash != "" && sweepSvc.GetConfigHash() == sweepConfig.ConfigHash {
		p.logger.Debug().Str("config_hash", sweepConfig.ConfigHash).Msg("Sweep config unchanged")
		return
	}

	p.server.mu.RLock()
	cfg := p.server.config
	p.server.mu.RUnlock()

	sweepModelConfig, err := buildSweepModelConfig(cfg, sweepConfig, p.logger)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build sweep config from gateway payload")
		return
	}

	if err := sweepSvc.UpdateConfig(sweepModelConfig); err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply sweep config from gateway")
		return
	}

	p.logger.Info().
		Str("config_hash", sweepConfig.ConfigHash).
		Int("targets", len(sweepConfig.Networks)).
		Msg("Applied sweep config from gateway")
}

// applySysmonConfig applies sysmon configuration from the gateway to the embedded sysmon service.
func (p *PushLoop) applySysmonConfig(protoConfig *proto.SysmonConfig) {
	p.server.mu.RLock()
	sysmonSvc := p.server.sysmonService
	p.server.mu.RUnlock()

	if sysmonSvc == nil {
		p.logger.Debug().Msg("Sysmon service not initialized, skipping config apply")
		return
	}

	// Convert proto config to sysmon.Config
	cfg := protoToSysmonConfig(protoConfig)

	// Parse and apply the configuration (including when disabled - collector checks Enabled flag)
	parsed, err := cfg.Parse()
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to parse sysmon config from gateway")
		return
	}

	if err := sysmonSvc.Reconfigure(parsed); err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply sysmon config from gateway")
		return
	}

	p.logger.Info().
		Str("profile_id", protoConfig.ProfileId).
		Str("profile_name", protoConfig.ProfileName).
		Str("config_source", protoConfig.ConfigSource).
		Bool("enabled", cfg.Enabled).
		Str("sample_interval", cfg.SampleInterval).
		Bool("cpu", cfg.CollectCPU).
		Bool("memory", cfg.CollectMemory).
		Bool("disk", cfg.CollectDisk).
		Bool("network", cfg.CollectNetwork).
		Bool("processes", cfg.CollectProcesses).
		Msg("Applied sysmon config from gateway")
}

// protoToSysmonConfig converts a proto SysmonConfig to a sysmon.Config.
func protoToSysmonConfig(proto *proto.SysmonConfig) sysmon.Config {
	if proto == nil {
		return sysmon.DefaultConfig()
	}

	cfg := sysmon.Config{
		Enabled:          proto.Enabled,
		SampleInterval:   proto.SampleInterval,
		CollectCPU:       proto.CollectCpu,
		CollectMemory:    proto.CollectMemory,
		CollectDisk:      proto.CollectDisk,
		CollectNetwork:   proto.CollectNetwork,
		CollectProcesses: proto.CollectProcesses,
		DiskPaths:        proto.DiskPaths,
		DiskExcludePaths: proto.DiskExcludePaths,
		Thresholds:       proto.Thresholds,
	}

	// Apply defaults for any unset values
	return cfg.MergeWithDefaults()
}

// applySNMPConfig applies SNMP configuration from the gateway to the embedded SNMP service.
func (p *PushLoop) applySNMPConfig(protoConfig *proto.SNMPConfig) {
	p.server.mu.RLock()
	snmpSvc := p.server.snmpService
	p.server.mu.RUnlock()

	if snmpSvc == nil {
		p.logger.Debug().Msg("SNMP service not initialized, skipping config apply")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := snmpSvc.ApplyProtoConfig(ctx, protoConfig); err != nil {
		p.logger.Warn().Err(err).Msg("Failed to apply SNMP config")
	}
}

// applyDuskConfig applies dusk configuration from the gateway to the embedded dusk service.
func (p *PushLoop) applyDuskConfig(protoConfig *proto.DuskConfig) {
	p.server.mu.RLock()
	duskSvc := p.server.duskService
	p.server.mu.RUnlock()

	if duskSvc == nil {
		p.logger.Debug().Msg("Dusk service not initialized, skipping config apply")
		return
	}

	// Convert proto config to DuskConfig
	cfg := protoToDuskConfig(protoConfig)

	// Build source string from proto metadata
	source := configSourceRemote
	if protoConfig.ConfigSource != "" {
		source = configSourceRemote + ":" + protoConfig.ConfigSource
	}

	// Apply the configuration
	if err := duskSvc.Reconfigure(cfg, source); err != nil {
		p.logger.Error().Err(err).Msg("Failed to apply dusk config from gateway")
		return
	}

	p.logger.Info().
		Str("profile_id", protoConfig.ProfileId).
		Str("profile_name", protoConfig.ProfileName).
		Str("config_source", protoConfig.ConfigSource).
		Bool("enabled", cfg.Enabled).
		Str("node_address", cfg.NodeAddress).
		Msg("Applied dusk config from gateway")
}

func (p *PushLoop) applyCheckConfigs(checks []*proto.AgentCheckConfig) {
	parsed := make(map[string]*icmpCheckConfig)

	for _, check := range checks {
		cfg := parseICMPCheckConfig(check)
		if cfg == nil {
			continue
		}
		parsed[cfg.ID] = cfg
	}

	p.icmpMu.Lock()
	p.icmpChecks = parsed
	for id := range p.icmpLastRun {
		if _, ok := parsed[id]; !ok {
			delete(p.icmpLastRun, id)
		}
	}
	p.icmpMu.Unlock()

	if len(parsed) > 0 {
		p.logger.Info().Int("icmp_checks", len(parsed)).Msg("Applied ICMP check config from gateway")
	} else if len(checks) > 0 {
		p.logger.Debug().Msg("Gateway checks did not include any ICMP checks")
	}
}

func parseICMPCheckConfig(check *proto.AgentCheckConfig) *icmpCheckConfig {
	if check == nil {
		return nil
	}

	checkType := strings.ToLower(strings.TrimSpace(check.CheckType))
	if checkType != "icmp" && checkType != "ping" {
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

	interval := time.Duration(check.IntervalSec) * time.Second
	timeout := time.Duration(check.TimeoutSec) * time.Second

	deviceID := ""
	if check.Settings != nil {
		if value, ok := check.Settings["device_id"]; ok {
			deviceID = strings.TrimSpace(value)
		}
		if deviceID == "" {
			if value, ok := check.Settings["device_uid"]; ok {
				deviceID = strings.TrimSpace(value)
			}
		}
	}

	return &icmpCheckConfig{
		ID:       checkID,
		Name:     strings.TrimSpace(check.Name),
		Target:   target,
		DeviceID: deviceID,
		Interval: interval,
		Timeout:  timeout,
		Enabled:  check.Enabled,
	}
}

// protoToDuskConfig converts a proto DuskConfig to a DuskConfig.
func protoToDuskConfig(p *proto.DuskConfig) *DuskConfig {
	if p == nil {
		return DefaultDuskConfig()
	}

	cfg := &DuskConfig{
		Enabled:     p.Enabled,
		NodeAddress: p.NodeAddress,
	}

	// Parse timeout from string duration
	if p.Timeout != "" {
		d, err := time.ParseDuration(p.Timeout)
		if err == nil {
			cfg.Timeout = models.Duration(d)
		} else {
			cfg.Timeout = models.Duration(5 * time.Minute) // Default timeout
		}
	} else {
		cfg.Timeout = models.Duration(5 * time.Minute)
	}

	return cfg
}

// getAgentCapabilities returns the list of capabilities this agent supports.
func getAgentCapabilities() []string {
	return []string{
		"icmp",
		sweepType,
		"snmp",
		"dusk",
		"mapper",
		"sync",
		"sysmon",
	}
}
