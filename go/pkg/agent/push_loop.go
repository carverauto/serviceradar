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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	agentgateway "github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Version is set at build time via -ldflags
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var Version = "dev"

var (
	errSweepMissingHosts    = errors.New("sweep data missing hosts field")
	errSweepHostsNotArray   = errors.New("hosts field is not an array")
	errJSONPayloadTooLarge  = errors.New("json payload exceeds limit")
	errPluginEmptyPayload   = errors.New("plugin payload empty")
	errPluginMissingStatus  = errors.New("plugin status missing")
	errPluginInvalidStatus  = errors.New("plugin status invalid")
	errPluginMissingSummary = errors.New("plugin summary missing")
)

type limitedJSONBuffer struct {
	bytes.Buffer
	limit int
}

type pluginResultStatusStreamer func(
	context.Context,
	[]*proto.GatewayStatusChunk,
) (*proto.GatewayStatusResponse, error)

func (b *limitedJSONBuffer) Write(p []byte) (int, error) {
	if b.limit > 0 && b.Len()+len(p) > b.limit {
		remaining := b.limit - b.Len()
		if remaining > 0 {
			_, _ = b.Buffer.Write(p[:remaining])
		}

		return 0, fmt.Errorf("%w: limit=%d", errJSONPayloadTooLarge, b.limit)
	}

	return b.Buffer.Write(p)
}

func marshalJSONLimited(v any, limit int) ([]byte, error) {
	buf := &limitedJSONBuffer{limit: limit}
	enc := json.NewEncoder(buf)

	if err := enc.Encode(v); err != nil {
		return nil, err
	}

	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// PushLoop manages the periodic pushing of agent status to the gateway.
type PushLoop struct {
	server        *Server
	gateway       *agentgateway.GatewayClient
	interval      time.Duration
	logger        logger.Logger
	done          chan struct{}
	stopCh        chan struct{}
	stopOnce      sync.Once
	doneOnce      sync.Once
	configVersion string // Current config version for polling (set only after a fully-successful apply)
	// lastAttemptedConfigVersion is the most recent version that ran through the full apply
	// pipeline, even if it did not commit (a transient section deferred). It lets a resend of
	// the SAME still-uncommitted version skip the idempotent heavy re-apply while the
	// deferrable sections keep retrying (fj #4301).
	lastAttemptedConfigVersion string
	configPollInterval         time.Duration // How often to poll for config updates
	enrolled                   bool          // Whether we've successfully enrolled
	started                    bool          // Whether Start has been invoked
	enrollMu                   sync.Mutex
	enrollInFlight             bool
	sweepResultsSeq            string
	icmpChecks                 map[string]*icmpCheckConfig
	icmpLastRun                map[string]time.Time
	icmpMu                     sync.RWMutex
	statusDebounce             time.Duration
	statusHeartbeat            time.Duration
	statusDebounceConfigured   bool
	statusHeartbeatConfigured  bool
	lastStatusPush             time.Time
	lastStatusSignature        string
	syncRuntime                *SyncRuntime
	mtrState                   *mtrCheckerState
	mtrOnDemandSem             chan struct{}
	mtrBulkJobSem              chan struct{}
	adhocScanSem               chan struct{}
	endpointInventoryFreshSem  chan struct{}
	cameraRelayManager         *cameraRelayManager
	remoteConsoleManager       *remoteConsoleManager
	applicationHTTPMu          sync.Mutex
	applicationHTTPSessions    map[string]*remoteaccess.ApplicationHTTPAdapter
	applicationHTTPRequests    map[string]map[string]*applicationHTTPRequestState
	tcpMu                      sync.Mutex
	tcpSessions                map[string]*remoteaccess.TCPAdapter

	addonLastGoodMu sync.Mutex
	addonLastGood   map[string]agentaddon.Spec // last successfully applied add-on spec, by addon id

	addonDeliveryMu       sync.Mutex
	addonDeliveryFailures map[string]addonDeliveryFailure // permanent add-on artifact delivery failure, by addon id (drives backoff + status)

	configSectionMu       sync.Mutex
	configSectionFailures map[string]configSectionFailure // persistent config-section apply failure, by section name (drives skip + escalate-once + per-section ack)

	hostNetworkVisibilitySupported func() bool
	uninstallSystemdAddonUnits     func(context.Context, []string) error
	relabelStagedAddonExecutables  func(runtimeRoot, addonID string)

	// configApplyMu serializes complete config-response transactions across the independent
	// poll/control-stream/enroll goroutines. The lock order is configApplyMu then
	// addonReconcileMu; direct add-on reconciles never acquire configApplyMu.
	configSequence       atomic.Uint64 // allocated before a poll request or on control receipt
	configApplyMu        sync.Mutex
	latestConfigSequence uint64 // highest request/receipt sequence whose apply began; guarded by configApplyMu
	addonReconcileMu     sync.Mutex

	systemdAddonsMu        sync.Mutex
	systemdRehydrateOnce   sync.Once
	installedSystemdAddons map[string][]string // systemd-supervised addon id -> installed unit names
	readSystemdUnitStatus  func(string) systemdUnitStatus

	ephemeralHelpersMu        sync.Mutex
	availableEphemeralHelpers map[string]string // ephemeral-helper addon id -> resolved staged binary path

	workloadIdentityMu          sync.Mutex
	lastWorkloadIdentityFile    workloadIdentityFileSignature
	flowAttributionDelivery     flowAttributionDeliveryQueue
	pluginResultDeliveryMu      sync.Mutex
	pendingPluginResults        []PluginResult
	pluginResultStreamStatus    pluginResultStatusStreamer
	flowAttributionStreamStatus pluginResultStatusStreamer

	stateMu  sync.RWMutex // Protects interval, configPollInterval, enrolled, configVersion, lastAttemptedConfigVersion, started
	cancelMu sync.Mutex
	cancel   context.CancelFunc
}

// Thread-safe accessors for shared state

// Default intervals
const (
	defaultPushInterval            = 30 * time.Second
	defaultConfigPollInterval      = 60 * time.Second
	defaultEnrollRetryDelay        = 2 * time.Second
	maxEnrollRetryDelay            = 30 * time.Second
	defaultStatusHeartbeatInterval = 5 * time.Minute
	minSweepResultsStreamTimeout   = 30 * time.Second
	maxSweepResultsStreamTimeout   = 30 * time.Minute
	sweepResultsTimeoutPerChunk    = time.Second
	rdpAdapterAddonID              = "rdp"
)

func gatewayIDFromClient(gateway *agentgateway.GatewayClient) string {
	if gateway == nil {
		return ""
	}
	return gateway.GetGatewayID()
}

// NewPushLoop creates a new push loop.
func NewPushLoop(server *Server, gateway *agentgateway.GatewayClient, interval time.Duration, log logger.Logger) *PushLoop {
	if interval <= 0 {
		interval = defaultPushInterval
	}
	configurePluginCredentialBroker(server, gateway)
	configureAutomationLaunchEnvelopeResolver(server, gateway)
	configurePluginArtifactUploader(server)
	debounce, heartbeat := clampStatusIntervals(interval, defaultStatusHeartbeatInterval, interval)
	cameraRelayManager := newCameraRelayManager(gateway, log)
	cameraRelayManager.pluginSourceFactory = func(ctx context.Context, spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		server.mu.RLock()
		pluginManager := server.pluginManager
		server.mu.RUnlock()

		if pluginManager == nil {
			return nil, errCameraRelayPluginUnavailable
		}

		return pluginManager.OpenCameraRelayStream(ctx, spec.PluginAssignmentID, spec)
	}
	remoteConsoleManager := newRemoteConsoleManagerWithRoute(serverAgentID(server), gatewayIDFromClient(gateway), log)
	remoteConsoleManager.sshOptions.KnownHostsPath = remoteAccessKnownHostsFile(server)
	remoteConsoleManager.desktopGateway = desktopMediaGatewayFromClient(gateway)
	remoteConsoleManager.opener = func(ctx context.Context, frame *proto.ConsoleFrame) (remoteConsolePTY, error) {
		spec, err := decodeProxmoxConsoleOpenPayload(frame)
		if err != nil {
			return nil, err
		}

		server.mu.RLock()
		pluginManager := server.pluginManager
		server.mu.RUnlock()

		if pluginManager == nil {
			return nil, errRemoteConsoleBridgeUnavailable
		}

		return pluginManager.OpenProxmoxConsoleStream(ctx, spec)
	}

	pushLoop := &PushLoop{
		server:                         server,
		gateway:                        gateway,
		interval:                       interval,
		logger:                         log,
		done:                           make(chan struct{}),
		stopCh:                         make(chan struct{}),
		configPollInterval:             defaultConfigPollInterval,
		icmpChecks:                     make(map[string]*icmpCheckConfig),
		icmpLastRun:                    make(map[string]time.Time),
		statusDebounce:                 debounce,
		statusHeartbeat:                heartbeat,
		syncRuntime:                    NewSyncRuntime(server, gateway, log),
		mtrState:                       newMtrCheckerState(),
		mtrOnDemandSem:                 make(chan struct{}, defaultMaxConcurrentOnDemandMtr),
		mtrBulkJobSem:                  make(chan struct{}, 1),
		adhocScanSem:                   make(chan struct{}, defaultMaxConcurrentAdhocScans),
		endpointInventoryFreshSem:      make(chan struct{}, 1),
		cameraRelayManager:             cameraRelayManager,
		remoteConsoleManager:           remoteConsoleManager,
		readSystemdUnitStatus:          readSystemdUnitStatusDefault,
		hostNetworkVisibilitySupported: runtimeSupportsHostNetworkVisibility,
		uninstallSystemdAddonUnits:     uninstallAddonSystemdUnitsViaUpdater,
		relabelStagedAddonExecutables:  relabelStagedAddonExecutables,
	}
	remoteConsoleManager.desktopAdapter = desktopRDPHelperAdapter{HelperPathResolver: pushLoop.remoteAccessRDPAdapterPath}

	// The add-on OTLP relay pumps are registered with the add-on manager at
	// server construction, before the gateway client exists; hand them the
	// gateway now that it does.
	if gateway != nil && server != nil {
		bindAddonOtlpRelayGateway(server, gateway, pushLoop.getSourceIP)
	}

	return pushLoop
}

func configureAutomationLaunchEnvelopeResolver(server *Server, gateway *agentgateway.GatewayClient) {
	if server == nil || gateway == nil {
		return
	}

	resolver := newControlPlaneAutomationLaunchEnvelopeResolver(gateway, serverAgentID(server))
	if resolver == nil {
		return
	}

	server.mu.RLock()
	pluginManager := server.pluginManager
	server.mu.RUnlock()

	server.mu.Lock()
	server.launchEnvelopes = resolver
	server.mu.Unlock()

	if pluginManager != nil {
		pluginManager.SetAWXCallbackCredentialEnvelopeResolver(resolver)
	}
}

func configurePluginArtifactUploader(server *Server) {
	if server == nil || server.config == nil {
		return
	}

	uploader, err := newGatewayPluginArtifactUploader(server.config.GatewaySecurity, server.logger)
	if err != nil {
		if server.logger != nil {
			server.logger.Warn().Err(err).Msg("Wasm plugin artifact staging unavailable")
		}
		return
	}

	server.mu.RLock()
	pluginManager := server.pluginManager
	server.mu.RUnlock()

	server.mu.Lock()
	server.artifactUploader = uploader
	server.mu.Unlock()

	if pluginManager != nil {
		pluginManager.SetArtifactUploader(uploader)
	}
}

func configurePluginCredentialBroker(server *Server, gateway *agentgateway.GatewayClient) {
	if server == nil || gateway == nil {
		return
	}

	resolver := newControlPlaneCredentialBrokerResolver(gateway, serverAgentID(server))
	if resolver == nil {
		return
	}

	server.mu.RLock()
	pluginManager := server.pluginManager
	addonManager := server.addonManager
	server.mu.RUnlock()

	server.mu.Lock()
	server.credentialBroker = resolver
	server.mu.Unlock()

	if pluginManager != nil {
		pluginManager.SetCredentialBroker(resolver)
	}
	if addonManager != nil {
		addonManager.SetCredentialResolver(resolver)
	}
}

type gatewayDesktopMediaClient struct {
	gateway *agentgateway.GatewayClient
}

func desktopMediaGatewayFromClient(gateway *agentgateway.GatewayClient) desktopMediaGateway {
	if gateway == nil {
		return nil
	}

	return gatewayDesktopMediaClient{gateway: gateway}
}

func (g gatewayDesktopMediaClient) OpenDesktopMediaSession(
	ctx context.Context,
	req *proto.OpenDesktopMediaSessionRequest,
) (*proto.OpenDesktopMediaSessionResponse, error) {
	return g.gateway.OpenDesktopMediaSession(ctx, req)
}

func (g gatewayDesktopMediaClient) StreamDesktopMedia(ctx context.Context) (desktopMediaStream, error) {
	return g.gateway.StreamDesktopMedia(ctx)
}

func (g gatewayDesktopMediaClient) CloseDesktopMediaSession(
	ctx context.Context,
	req *proto.CloseDesktopMediaSessionRequest,
) (*proto.CloseDesktopMediaSessionResponse, error) {
	return g.gateway.CloseDesktopMediaSession(ctx, req)
}

func remoteAccessRDPAdapterPath(server *Server) string {
	if server == nil || server.config == nil {
		return ""
	}

	server.mu.RLock()
	defer server.mu.RUnlock()

	return strings.TrimSpace(server.config.RemoteAccessRDPAdapterPath)
}

func (p *PushLoop) remoteAccessRDPAdapterPath() string {
	if p != nil {
		if path, ok := p.EphemeralHelperPath(rdpAdapterAddonID); ok && strings.TrimSpace(path) != "" {
			return path
		}
	}
	if p == nil {
		return ""
	}

	return remoteAccessRDPAdapterPath(p.server)
}

func remoteAccessKnownHostsFile(server *Server) string {
	if server == nil || server.config == nil {
		return ""
	}

	server.mu.RLock()
	defer server.mu.RUnlock()

	return strings.TrimSpace(server.config.RemoteAccessKnownHostsFile)
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

	if p.syncRuntime != nil {
		p.syncRuntime.SetContext(runCtx)
	}

	// Start config polling in a separate goroutine
	go p.configPollLoop(runCtx)
	go p.superviseControlStreamLoop(runCtx)
	go p.monitorReleaseActivation(runCtx)

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

	// Push regular statuses via StreamStatus
	if len(statuses) > 0 {
		now := time.Now()
		decision := p.evaluateStatusPush(statuses, now)
		if decision.shouldPush {
			if p.pushRegularStatuses(ctx, statuses, decision.reason) {
				p.recordStatusPush(decision.signature, now)
			}
		} else {
			p.logger.Debug().Msg("Status unchanged; skipping status push")
		}
	}

	// Push sysmon via StreamStatus (it can have large payloads with all processes)
	sentSysmonMetrics := false
	if sysmonStatus != nil {
		sentSysmonMetrics = p.pushSysmonStatus(ctx, sysmonStatus)
	}

	sentICMPResults := p.pushICMPResults(ctx)
	sentMtrResults := p.pushMtrResults(ctx)
	sentSweepResults := p.pushSweepResults(ctx)
	sentMapperResults := p.pushMapperResults(ctx)
	sentMapperInterfaces := p.pushMapperInterfaces(ctx)
	sentMapperTopology := p.pushMapperTopology(ctx)
	sentSNMPMetrics := p.pushSNMPMetrics(ctx)
	sentNetprobeResults := p.pushNetprobeResults(ctx)
	sentFlowAttribution := p.pushFlowAttribution(ctx)
	sentWorkloadIdentity := p.pushWorkloadIdentity(ctx)
	sentPluginResults := p.pushPluginResults(ctx)
	sentPluginSignals := p.pushPluginSignals(ctx)
	sentPluginTelemetry := p.pushPluginTelemetry(ctx)
	sentAddonTelemetry := p.pushAddonTelemetry(ctx)

	if len(statuses) == 0 &&
		!sentSysmonMetrics &&
		!sentICMPResults &&
		!sentMtrResults &&
		!sentSweepResults &&
		!sentMapperResults &&
		!sentMapperInterfaces &&
		!sentMapperTopology &&
		!sentSNMPMetrics &&
		!sentNetprobeResults &&
		!sentFlowAttribution &&
		!sentWorkloadIdentity &&
		!sentPluginResults &&
		!sentPluginSignals &&
		!sentPluginTelemetry &&
		!sentAddonTelemetry {
		p.logger.Debug().Msg("No statuses to push")
	}
}

// getSourceIP attempts to determine the source IP of this agent.
//
// host_ip in agent.json is a bootstrap pin written at onboard time. If that
// address is still on a local interface, keep it (multi-homed / NAT pin).
// If the host moved and the pin is gone, ignore it and re-detect so Hello
// can update the existing agent device instead of leaving a stale IP.
func (p *PushLoop) getSourceIP() string {
	p.server.mu.RLock()
	configured := ""
	if p.server.config != nil {
		configured = p.server.config.HostIP
	}
	p.server.mu.RUnlock()

	localIPs, err := localSourceIPs()
	if err != nil {
		p.logger.Debug().Err(err).Msg("Failed to enumerate network interfaces")
		return strings.TrimSpace(configured)
	}

	selected := selectSourceIP(configured, localIPs)
	if configured = strings.TrimSpace(configured); configured != "" && selected != "" && selected != configured {
		p.logger.Info().
			Str("configured_host_ip", configured).
			Str("detected_host_ip", selected).
			Msg("Ignoring stale host_ip; using live interface address")
	}
	return selected
}

func selectSourceIP(configured string, localIPs []net.IP) string {
	configured = strings.TrimSpace(configured)
	if configured != "" && localIPsContain(localIPs, configured) {
		return configured
	}
	if detected := preferLocalSourceIP(localIPs); detected != "" {
		return detected
	}
	return configured
}

func localSourceIPs() ([]net.IP, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	var ips []net.IP
	for _, iface := range ifaces {
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
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			ips = append(ips, ip)
		}
	}

	return ips, nil
}

func preferLocalSourceIP(localIPs []net.IP) string {
	var publicIPv4, ipv6 string

	for _, ip := range localIPs {
		if ip4 := ip.To4(); ip4 != nil {
			if ip4.IsPrivate() {
				return ip4.String()
			}
			if publicIPv4 == "" && ip4.IsGlobalUnicast() {
				publicIPv4 = ip4.String()
			}
			continue
		}
		if ipv6 == "" && ip.IsGlobalUnicast() {
			ipv6 = ip.String()
		}
	}

	if publicIPv4 != "" {
		return publicIPv4
	}
	return ipv6
}

func localIPsContain(localIPs []net.IP, candidate string) bool {
	parsed := net.ParseIP(candidate)
	if parsed == nil {
		return false
	}
	for _, ip := range localIPs {
		if ip.Equal(parsed) {
			return true
		}
	}
	return false
}
