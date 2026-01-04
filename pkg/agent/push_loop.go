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
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Version is set at build time via -ldflags
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var Version = "dev"

// PushLoop manages the periodic pushing of agent status to the gateway.
type PushLoop struct {
	server             *Server
	gateway            *GatewayClient
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

	stateMu sync.RWMutex // Protects interval, configPollInterval, enrolled, configVersion, started
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

// Default config poll interval (5 minutes)
const defaultConfigPollInterval = 5 * time.Minute

// Check type constants for goconst compliance
const (
	icmpCheckType = "icmp"
	tcpCheckType  = "tcp"
	httpCheckType = "http"
	grpcCheckType = "grpc"
)

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
		stopCh:             make(chan struct{}),
		configPollInterval: defaultConfigPollInterval,
	}
}

// Start begins the push loop. It runs until the context is cancelled or Stop is called.
func (p *PushLoop) Start(ctx context.Context) error {
	// Ensure done is closed when Start exits (only once)
	defer p.doneOnce.Do(func() { close(p.done) })

	p.stateMu.Lock()
	p.started = true
	p.stateMu.Unlock()

	p.logger.Info().Dur("interval", p.getInterval()).Msg("Starting push loop")

	// Initial connection and enrollment attempt
	if err := p.gateway.Connect(ctx); err != nil {
		p.logger.Warn().Err(err).Msg("Initial gateway connection failed, will retry")
	} else {
		// Connected, try to enroll
		p.enroll(ctx)
	}

	// Start config polling in a separate goroutine
	go p.configPollLoop(ctx)

	// Use a resettable timer so updated intervals take effect
	timer := time.NewTimer(0) // fire immediately for first tick
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			p.logger.Info().Msg("Push loop stopping due to context cancellation")
			return ctx.Err()

		case <-p.stopCh:
			p.logger.Info().Msg("Push loop stopping due to Stop()")
			return context.Canceled

		case <-timer.C:
			// Only push when enrolled (enrollment can happen later via reconnect)
			if p.isEnrolled() {
				p.pushStatus(ctx)
			}
			timer.Reset(p.getInterval())
		}
	}
}

// Stop signals the push loop to stop and waits for it to exit.
// Closes done channel if Start() was never called to prevent deadlock.
func (p *PushLoop) Stop() {
	p.stopOnce.Do(func() { close(p.stopCh) })
	p.stateMu.RLock()
	started := p.started
	p.stateMu.RUnlock()
	if !started {
		p.doneOnce.Do(func() { close(p.done) })
		return
	}
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
		p.setEnrolled(false)
		p.enroll(ctx)
	}

	// Skip pushing if not enrolled
	if !p.isEnrolled() {
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
	services := append([]Service(nil), p.server.services...)
	checkerConfs := make(map[string]*CheckerConfig, len(p.server.checkerConfs))
	for key, conf := range p.server.checkerConfs {
		if conf == nil {
			continue
		}
		c := *conf // snapshot by value to avoid races on shared pointers
		checkerConfs[key] = &c
	}
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

	// Enumerate local interfaces to find a non-loopback IP
	// This avoids unexpected external network egress
	ifaces, err := net.Interfaces()
	if err != nil {
		p.logger.Debug().Err(err).Msg("Failed to enumerate network interfaces")
		return ""
	}

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

			// Prefer IPv4 addresses
			if ip4 := ip.To4(); ip4 != nil {
				return ip4.String()
			}
		}
	}

	p.logger.Debug().Msg("No suitable source IP found")
	return ""
}

// enroll sends Hello to the gateway and fetches initial config.
func (p *PushLoop) enroll(ctx context.Context) {
	p.logger.Info().Msg("Enrolling with gateway...")

	// Build Hello request
	helloReq := &proto.AgentHelloRequest{
		AgentId:       p.server.config.AgentID,
		Version:       Version, // Agent version from version.go
		Capabilities:  getAgentCapabilities(),
		ConfigVersion: p.getConfigVersion(),
	}

	// Send Hello
	helloResp, err := p.gateway.Hello(ctx, helloReq)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to enroll with gateway")
		return
	}

	// Update server config with tenant info from gateway
	p.server.mu.Lock()
	p.server.config.TenantID = helloResp.TenantId
	p.server.config.TenantSlug = helloResp.TenantSlug
	p.server.mu.Unlock()

	// Update push interval if specified by gateway
	if helloResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(helloResp.HeartbeatIntervalSec) * time.Second
		if newInterval != p.getInterval() {
			p.setInterval(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Updated push interval from gateway")
		}
	}

	p.setEnrolled(true)
	p.logger.Info().
		Str("agent_id", helloResp.AgentId).
		Str("gateway_id", helloResp.GatewayId).
		Str("tenant_slug", helloResp.TenantSlug).
		Msg("Successfully enrolled with gateway")

	// Fetch initial config if outdated or not yet fetched
	if helloResp.ConfigOutdated || p.getConfigVersion() == "" {
		p.fetchAndApplyConfig(ctx)
	}
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
	configReq := &proto.AgentConfigRequest{
		AgentId:       p.server.config.AgentID,
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
		if newInterval != p.getInterval() {
			p.setInterval(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Updated push interval from config")
		}
	}

	if configResp.ConfigPollIntervalSec > 0 {
		newPollInterval := time.Duration(configResp.ConfigPollIntervalSec) * time.Second
		if newPollInterval != p.getConfigPollInterval() {
			p.setConfigPollInterval(newPollInterval)
			p.logger.Info().Dur("interval", newPollInterval).Msg("Updated config poll interval")
		}
	}

	// Apply the new checks
	p.applyChecks(configResp.Checks)

	// Update version
	p.setConfigVersion(configResp.ConfigVersion)
	p.logger.Info().
		Str("version", p.getConfigVersion()).
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
		// Guard against nil entries in the checks slice
		if check == nil {
			continue
		}

		if !check.Enabled {
			continue
		}

		// Require a stable map key for server.checkerConfs.
		if check.Name == "" {
			continue
		}

		seenChecks[check.Name] = true

		// Convert proto check to CheckerConfig
		checkerConf := protoCheckToCheckerConfig(check)
		if checkerConf == nil {
			continue
		}

		// Check if this config already exists and is unchanged
		if existing, exists := p.server.checkerConfs[check.Name]; exists && existing != nil {
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

// Default timeout for checks when not specified or invalid
const (
	defaultCheckTimeout = 10 * time.Second
	maxCheckTimeout     = 24 * time.Hour
)

// protoCheckToCheckerConfig converts a proto AgentCheckConfig to a CheckerConfig.
func protoCheckToCheckerConfig(check *proto.AgentCheckConfig) *CheckerConfig {
	// Sanitize required fields coming from the gateway to avoid panics downstream.
	// NOTE: Don't return nil here; callers may store the config without checking.
	target := check.Target
	if target == "" {
		target = "localhost"
	}

	port := check.Port
	if port < 0 || port > 65535 {
		port = 0
	}

	// Build address from target and port
	address := target
	if port > 0 {
		address = net.JoinHostPort(target, fmt.Sprintf("%d", port))
	}

	// Map proto check type to internal type
	checkerType := mapCheckType(check.CheckType)

	// Validate and default timeout to prevent issues with zero/negative values and duration overflow.
	timeoutSec := int64(check.TimeoutSec)
	var timeout time.Duration
	if timeoutSec <= 0 {
		timeout = defaultCheckTimeout
	} else {
		timeout = time.Duration(timeoutSec) * time.Second
		if timeout > maxCheckTimeout {
			timeout = maxCheckTimeout
		}
	}

	return &CheckerConfig{
		Name:    check.Name,
		Type:    checkerType,
		Address: address,
		Timeout: Duration(timeout),
		// Additional fields from settings if needed
	}
}

// mapCheckType maps proto check types to internal checker types.
func mapCheckType(protoType string) string {
	switch protoType {
	case icmpCheckType, "ping":
		return icmpCheckType
	case tcpCheckType:
		return tcpCheckType
	case httpCheckType, "https":
		return httpCheckType
	case grpcCheckType:
		return grpcCheckType
	case "process":
		return "process"
	case sweepType:
		return sweepType
	default:
		return protoType
	}
}

// getAgentCapabilities returns the list of capabilities this agent supports.
func getAgentCapabilities() []string {
	return []string{
		icmpCheckType,
		tcpCheckType,
		httpCheckType,
		grpcCheckType,
		sweepType,
		"snmp",
		"process",
	}
}
