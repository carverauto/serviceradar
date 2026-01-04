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
	"net/url"
	"strings"
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
			// Only push when enrolled (enrollment can happen later via reconnect)
			if p.isEnrolled() {
				p.pushStatus(runCtx)
			}
			timer.Reset(p.getInterval())
		}
	}
}

// Stop signals the push loop to stop and waits for it to exit.
// Closes done channel if Start() was never called to prevent deadlock.
func (p *PushLoop) Stop() {
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
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	tenantID := p.server.config.TenantID
	tenantSlug := p.server.config.TenantSlug
	p.server.mu.RUnlock()

	req := &proto.GatewayStatusRequest{
		Services:   statuses,
		GatewayId:  "", // Will be set by the gateway
		AgentId:    agentID,
		Timestamp:  time.Now().UnixNano(),
		Partition:  partition,
		SourceIp:   p.getSourceIP(),
		KvStoreId:  kvStoreID,
		TenantId:   tenantID,
		TenantSlug: tenantSlug,
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
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()

	// Create a status request to get the checker status
	req := &proto.StatusRequest{
		ServiceName: name,
		ServiceType: conf.Type,
		AgentId:     agentID,
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

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	tenantID := p.server.config.TenantID
	tenantSlug := p.server.config.TenantSlug
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
		TenantId:     tenantID,
		TenantSlug:   tenantSlug,
	}
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

// enroll sends Hello to the gateway and fetches initial config.
func (p *PushLoop) enroll(ctx context.Context) {
	p.logger.Info().Msg("Enrolling with gateway...")

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
	if check == nil {
		return nil
	}

	target := normalizeCheckTarget(check.Target)
	port := normalizeCheckPort(check.Port)
	wantHTTPS := check.CheckType == "https"
	checkerType := mapCheckType(check.CheckType)
	if (checkerType == tcpCheckType || checkerType == grpcCheckType) && port == 0 {
		// Allow "host:port" or URL targets that already include a port.
		hasEmbeddedPort := false
		if host, p, err := net.SplitHostPort(target); err == nil && host != "" && p != "" {
			hasEmbeddedPort = true
		} else if parsed, err := url.Parse(target); err == nil && parsed.Host != "" && parsed.Port() != "" {
			hasEmbeddedPort = true
		} else {
			// Handles "host:port/path" inputs without an explicit scheme.
			hostPort := target
			if i := strings.IndexAny(hostPort, "/?"); i >= 0 {
				hostPort = hostPort[:i]
			}

			// net.SplitHostPort requires bracketed IPv6; be explicit to avoid silently dropping checks.
			if host, p, err := net.SplitHostPort(hostPort); err == nil && host != "" && p != "" {
				hasEmbeddedPort = true
			}
		}
		if !hasEmbeddedPort {
			return nil
		}
	}
	address := buildCheckAddress(target, port, checkerType, check.Path, wantHTTPS)
	timeout := clampCheckTimeout(check.TimeoutSec)

	return &CheckerConfig{
		Name:    check.Name,
		Type:    checkerType,
		Address: address,
		Timeout: Duration(timeout),
		// Additional fields from settings if needed
	}
}

func normalizeCheckTarget(target string) string {
	if target == "" {
		return "localhost"
	}
	return target
}

func normalizeCheckPort(port int32) int32 {
	if port < 0 || port > 65535 {
		return 0
	}
	return port
}

func buildCheckAddress(target string, port int32, checkerType, path string, wantHTTPS bool) string {
	address := applyHTTPPath(target, checkerType, path, wantHTTPS)
	if port > 0 {
		return applyPort(address, target, port, checkerType, wantHTTPS)
	}
	return address
}

func applyHTTPPath(target, checkerType, path string, wantHTTPS bool) string {
	if checkerType != httpCheckType || path == "" {
		return target
	}

	parsed, err := url.Parse(target)
	if err != nil || parsed.Scheme == "" {
		scheme := "http://"
		if wantHTTPS {
			scheme = "https://"
		}
		if parsedURL, err := url.Parse(scheme + target); err == nil {
			parsed = parsedURL
		} else if err != nil {
			return target
		}
	}
	// Only override if target didn't already include a path.
	if parsed.Path == "" || parsed.Path == "/" {
		parsed.Path = path
	}
	return parsed.String()
}

func applyPort(address, target string, port int32, checkerType string, wantHTTPS bool) string {
	// If target is already host:port (or [ipv6]:port), don't append a second port.
	if host, _, err := net.SplitHostPort(target); err == nil && host != "" {
		return target
	}

	if updated, ok := applyPortToURL(address, port); ok {
		return updated
	}

	if isPathLikeTarget(target) {
		return applyPortToPathLike(target, port, checkerType, wantHTTPS)
	}

	return joinHostPort(target, port)
}

func applyPortToURL(address string, port int32) (string, bool) {
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", false
	}
	if parsed.Port() == "" {
		parsed.Host = net.JoinHostPort(parsed.Hostname(), fmt.Sprintf("%d", port))
	}
	return parsed.String(), true
}

func isPathLikeTarget(target string) bool {
	parsed, err := url.Parse(target)
	return err == nil && parsed.Scheme == "" && parsed.Host == "" && parsed.Path != ""
}

func applyPortToPathLike(target string, port int32, checkerType string, wantHTTPS bool) string {
	// Path-like target (e.g., "example.com/path"): for HTTP checks, normalize into a URL and apply port.
	if checkerType != httpCheckType {
		return target
	}
	scheme := "http://"
	if wantHTTPS {
		scheme = "https://"
	}
	parsedURL, err := url.Parse(scheme + target)
	if err != nil || parsedURL.Host == "" {
		return target
	}
	if parsedURL.Port() == "" {
		parsedURL.Host = net.JoinHostPort(parsedURL.Hostname(), fmt.Sprintf("%d", port))
	}
	return parsedURL.String()
}

func joinHostPort(target string, port int32) string {
	// Plain host/IP target without port.
	// If target is a bracketed IPv6 literal (e.g. "[::1]"), strip brackets before JoinHostPort.
	host := target
	if len(host) >= 2 && host[0] == '[' && host[len(host)-1] == ']' {
		host = host[1 : len(host)-1]
	}
	return net.JoinHostPort(host, fmt.Sprintf("%d", port))
}

func clampCheckTimeout(timeoutSec int32) time.Duration {
	// Validate and default timeout to prevent issues with zero/negative values and duration overflow.
	sec := int64(timeoutSec)
	if sec <= 0 {
		return defaultCheckTimeout
	}
	timeout := time.Duration(sec) * time.Second
	if timeout > maxCheckTimeout {
		return maxCheckTimeout
	}
	return timeout
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
