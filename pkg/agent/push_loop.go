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
	"fmt"
	"net"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Version is set at build time via -ldflags
var Version = "dev"

// PushLoop manages the periodic pushing of agent status to the gateway.
type PushLoop struct {
	server             *Server
	gateway            *GatewayClient
	interval           time.Duration
	logger             logger.Logger
	done               chan struct{}
	configVersion      string        // Current config version for polling
	configPollInterval time.Duration // How often to poll for config updates
	enrolled           bool          // Whether we've successfully enrolled
}

// Default config poll interval (5 minutes)
const defaultConfigPollInterval = 5 * time.Minute

// NewPushLoop creates a new push loop.
func NewPushLoop(server *Server, gateway *GatewayClient, interval time.Duration, log logger.Logger) *PushLoop {
	if interval <= 0 {
		interval = defaultPushInterval
	}

	return &PushLoop{
		server:             server,
		gateway:            gateway,
		interval:           interval,
		logger:             log,
		done:               make(chan struct{}),
		configPollInterval: defaultConfigPollInterval,
	}
}

// Start begins the push loop. It runs until the context is cancelled.
func (p *PushLoop) Start(ctx context.Context) error {
	p.logger.Info().Dur("interval", p.interval).Msg("Starting push loop")

	// Initial connection and enrollment attempt
	if err := p.gateway.Connect(ctx); err != nil {
		p.logger.Warn().Err(err).Msg("Initial gateway connection failed, will retry")
	} else {
		// Connected, try to enroll
		p.enroll(ctx)
	}

	// Start config polling in a separate goroutine
	go p.configPollLoop(ctx)

	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()

	// Do an initial push immediately (only if enrolled)
	if p.enrolled {
		p.pushStatus(ctx)
	}

	for {
		select {
		case <-ctx.Done():
			p.logger.Info().Msg("Push loop stopping due to context cancellation")
			close(p.done)
			return ctx.Err()

		case <-ticker.C:
			p.pushStatus(ctx)
		}
	}
}

// Stop signals the push loop to stop.
func (p *PushLoop) Stop() {
	<-p.done
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
		p.enrolled = false
		p.enroll(ctx)
	}

	// Skip pushing if not enrolled
	if !p.enrolled {
		p.logger.Debug().Msg("Not enrolled, skipping status push")
		return
	}

	// Collect status from all services
	statuses := p.collectAllStatuses(ctx)

	if len(statuses) == 0 {
		p.logger.Debug().Msg("No statuses to push")
		return
	}

	// Build the request
	req := &proto.GatewayStatusRequest{
		Services:   statuses,
		GatewayId:  "", // Will be set by the gateway
		AgentId:    p.server.config.AgentID,
		Timestamp:  time.Now().UnixNano(),
		Partition:  p.server.config.Partition,
		SourceIp:   p.getSourceIP(),
		KvStoreId:  p.server.config.KVAddress,
		TenantId:   p.server.config.TenantID,
		TenantSlug: p.server.config.TenantSlug,
	}

	// Push to gateway
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

// collectAllStatuses gathers status from all configured services and checkers.
func (p *PushLoop) collectAllStatuses(ctx context.Context) []*proto.GatewayServiceStatus {
	var statuses []*proto.GatewayServiceStatus

	// Collect from sweep services (SweepStatusProvider)
	p.server.mu.RLock()
	services := p.server.services
	checkerConfs := p.server.checkerConfs
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

	// Collect from configured checkers
	for name, conf := range checkerConfs {
		status := p.getCheckerStatus(ctx, name, conf)
		if status != nil {
			statuses = append(statuses, status)
		}
	}

	return statuses
}

// getCheckerStatus gets the status of a configured checker.
func (p *PushLoop) getCheckerStatus(ctx context.Context, name string, conf *CheckerConfig) *proto.GatewayServiceStatus {
	// Create a status request to get the checker status
	req := &proto.StatusRequest{
		ServiceName: name,
		ServiceType: conf.Type,
		AgentId:     p.server.config.AgentID,
	}

	// Use the server's GetStatus method to get the checker status
	resp, err := p.server.GetStatus(ctx, req)
	if err != nil {
		p.logger.Debug().Err(err).Str("checker", name).Msg("Failed to get checker status")
		return nil
	}

	return p.convertToGatewayStatus(resp, name, conf.Type)
}

// convertToGatewayStatus converts a StatusResponse to a GatewayServiceStatus.
func (p *PushLoop) convertToGatewayStatus(resp *proto.StatusResponse, serviceName, serviceType string) *proto.GatewayServiceStatus {
	if resp == nil {
		return nil
	}

	return &proto.GatewayServiceStatus{
		ServiceName:  serviceName,
		Available:    resp.Available,
		Message:      resp.Message,
		ServiceType:  serviceType,
		ResponseTime: resp.ResponseTime,
		AgentId:      p.server.config.AgentID,
		GatewayId:    "", // Will be set by gateway
		Partition:    p.server.config.Partition,
		Source:       "status",
		KvStoreId:    p.server.config.KVAddress,
		TenantId:     p.server.config.TenantID,
		TenantSlug:   p.server.config.TenantSlug,
	}
}

// getSourceIP attempts to determine the source IP of this agent.
func (p *PushLoop) getSourceIP() string {
	// First check if HostIP is configured
	if p.server.config.HostIP != "" {
		return p.server.config.HostIP
	}

	// Try to get the outbound IP
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		p.logger.Debug().Err(err).Msg("Failed to determine source IP")
		return ""
	}
	defer conn.Close()

	localAddr := conn.LocalAddr().(*net.UDPAddr)
	return localAddr.IP.String()
}

// enroll sends Hello to the gateway and fetches initial config.
func (p *PushLoop) enroll(ctx context.Context) {
	p.logger.Info().Msg("Enrolling with gateway...")

	// Build Hello request
	helloReq := &proto.AgentHelloRequest{
		AgentId:       p.server.config.AgentID,
		Version:       Version, // Agent version from version.go
		Capabilities:  getAgentCapabilities(),
		ConfigVersion: p.configVersion,
	}

	// Send Hello
	helloResp, err := p.gateway.Hello(ctx, helloReq)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to enroll with gateway")
		return
	}

	// Update server config with tenant info from gateway
	p.server.config.TenantID = helloResp.TenantId
	p.server.config.TenantSlug = helloResp.TenantSlug

	// Update push interval if specified by gateway
	if helloResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(helloResp.HeartbeatIntervalSec) * time.Second
		if newInterval != p.interval {
			p.interval = newInterval
			p.logger.Info().Dur("interval", p.interval).Msg("Updated push interval from gateway")
		}
	}

	p.enrolled = true
	p.logger.Info().
		Str("agent_id", helloResp.AgentId).
		Str("gateway_id", helloResp.GatewayId).
		Str("tenant_slug", helloResp.TenantSlug).
		Msg("Successfully enrolled with gateway")

	// Fetch initial config if outdated or not yet fetched
	if helloResp.ConfigOutdated || p.configVersion == "" {
		p.fetchAndApplyConfig(ctx)
	}
}

// configPollLoop periodically polls for config updates.
func (p *PushLoop) configPollLoop(ctx context.Context) {
	// Wait for initial enrollment before polling
	for !p.enrolled {
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
			// Keep waiting
		}
	}

	ticker := time.NewTicker(p.configPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			p.logger.Debug().Msg("Config poll loop stopping")
			return
		case <-ticker.C:
			if p.gateway.IsConnected() && p.enrolled {
				p.fetchAndApplyConfig(ctx)
			}
		}
	}
}

// fetchAndApplyConfig fetches config from gateway and applies it.
func (p *PushLoop) fetchAndApplyConfig(ctx context.Context) {
	configReq := &proto.AgentConfigRequest{
		AgentId:       p.server.config.AgentID,
		ConfigVersion: p.configVersion,
	}

	configResp, err := p.gateway.GetConfig(ctx, configReq)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to fetch config from gateway")
		return
	}

	// If config hasn't changed, nothing to do
	if configResp.NotModified {
		p.logger.Debug().Str("version", p.configVersion).Msg("Config not modified")
		return
	}

	// Update intervals from config response
	if configResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(configResp.HeartbeatIntervalSec) * time.Second
		if newInterval != p.interval {
			p.interval = newInterval
			p.logger.Info().Dur("interval", p.interval).Msg("Updated push interval from config")
		}
	}

	if configResp.ConfigPollIntervalSec > 0 {
		newPollInterval := time.Duration(configResp.ConfigPollIntervalSec) * time.Second
		if newPollInterval != p.configPollInterval {
			p.configPollInterval = newPollInterval
			p.logger.Info().Dur("interval", p.configPollInterval).Msg("Updated config poll interval")
		}
	}

	// Apply the new checks
	p.applyChecks(configResp.Checks)

	// Update version
	p.configVersion = configResp.ConfigVersion
	p.logger.Info().
		Str("version", p.configVersion).
		Int("checks", len(configResp.Checks)).
		Msg("Applied new config from gateway")
}

// applyChecks converts proto checks to checker configs and updates the server.
func (p *PushLoop) applyChecks(checks []*proto.AgentCheckConfig) {
	if len(checks) == 0 {
		p.logger.Debug().Msg("No checks to apply")
		return
	}

	p.server.mu.Lock()
	defer p.server.mu.Unlock()

	// Track which checks we've seen (for removing stale checks later)
	seenChecks := make(map[string]bool)

	for _, check := range checks {
		if !check.Enabled {
			continue
		}

		seenChecks[check.Name] = true

		// Convert proto check to CheckerConfig
		checkerConf := protoCheckToCheckerConfig(check)

		// Check if this config already exists and is unchanged
		if existing, exists := p.server.checkerConfs[check.Name]; exists {
			if existing.Type == checkerConf.Type &&
				existing.Address == checkerConf.Address &&
				existing.Timeout == checkerConf.Timeout {
				// Config unchanged, skip
				continue
			}
		}

		// Add or update the checker config
		p.server.checkerConfs[check.Name] = checkerConf

		p.logger.Info().
			Str("name", check.Name).
			Str("type", check.CheckType).
			Str("target", check.Target).
			Int32("port", check.Port).
			Msg("Added/updated check from gateway config")
	}

	// Optionally: remove checks that are no longer in the config
	// (commented out for now - may want to keep local file-based checks)
	// for name := range p.server.checkerConfs {
	// 	if !seenChecks[name] {
	// 		delete(p.server.checkerConfs, name)
	// 		p.logger.Info().Str("name", name).Msg("Removed stale check")
	// 	}
	// }
}

// protoCheckToCheckerConfig converts a proto AgentCheckConfig to a CheckerConfig.
func protoCheckToCheckerConfig(check *proto.AgentCheckConfig) *CheckerConfig {
	// Build address from target and port
	address := check.Target
	if check.Port > 0 {
		address = net.JoinHostPort(check.Target, fmt.Sprintf("%d", check.Port))
	}

	// Map proto check type to internal type
	checkerType := mapCheckType(check.CheckType)

	return &CheckerConfig{
		Name:    check.Name,
		Type:    checkerType,
		Address: address,
		Timeout: Duration(time.Duration(check.TimeoutSec) * time.Second),
		// Additional fields from settings if needed
	}
}

// mapCheckType maps proto check types to internal checker types.
func mapCheckType(protoType string) string {
	switch protoType {
	case "icmp", "ping":
		return "icmp"
	case "tcp":
		return "tcp"
	case "http", "https":
		return "http"
	case "grpc":
		return "grpc"
	case "process":
		return "process"
	case "sweep":
		return "sweep"
	default:
		return protoType
	}
}

// getAgentCapabilities returns the list of capabilities this agent supports.
func getAgentCapabilities() []string {
	return []string{
		"icmp",
		"tcp",
		"http",
		"grpc",
		"sweep",
		"snmp",
		"process",
	}
}
