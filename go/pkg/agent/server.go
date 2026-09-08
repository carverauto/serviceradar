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

// Package agent pkg/agent/server.go
package agent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/config"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

var (
	// ErrAgentIDRequired indicates agent_id is required in configuration
	ErrAgentIDRequired = errors.New("agent_id is required in configuration")
)

const (
	defaultPartition   = "default"
	sweepType          = "sweep"
	defaultErrChansize = 10
)

// NewServer initializes a new Server instance.
func NewServer(ctx context.Context, configDir string, cfg *ServerConfig, log logger.Logger) (*Server, error) {
	cfgLoader := config.NewConfig(log)

	s := initializeServer(configDir, cfg, log)

	s.createSweepService = func(ctx context.Context, sweepConfig *SweepConfig) (Service, error) {
		return createSweepService(ctx, sweepConfig, cfg, log, sweeper.WithBannerObservationHandler(s.handleBannerObservations))
	}

	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	s.initObjectStore(ctx)
	s.initPluginManager(ctx)
	s.initNetprobeSidecarStatus()
	s.initAddonManager()

	// Initialize embedded sysmon service
	if err := s.initSysmonService(ctx); err != nil {
		log.Warn().Err(err).Msg("Failed to initialize sysmon service, continuing without it")
	}

	// Initialize embedded SNMP service
	if err := s.initSNMPService(ctx); err != nil {
		log.Warn().Err(err).Msg("Failed to initialize SNMP service, continuing without it")
	}

	return s, nil
}

// initializeServer creates a new Server struct with default values.
func initializeServer(configDir string, cfg *ServerConfig, log logger.Logger) *Server {
	return &Server{
		configDir: configDir,
		services:  make([]Service, 0),
		errChan:   make(chan error, defaultErrChansize),
		done:      make(chan struct{}),
		config:    cfg,
		logger:    log,
	}
}

// createSweepService constructs a new SweepService instance.
func createSweepService(
	ctx context.Context,
	sweepConfig *SweepConfig,
	cfg *ServerConfig,
	log logger.Logger,
	opts ...sweeper.Option,
) (Service, error) {
	if sweepConfig == nil {
		return nil, errSweepConfigNil
	}

	groupConfig := sweepGroupConfigFromSweepConfig(sweepConfig)
	service, err := NewMultiSweepServiceWithContext(ctx, cfg, []SweepGroupConfig{groupConfig}, log, opts...)
	if err != nil {
		return nil, err
	}

	return service, nil
}

func sweepGroupConfigFromSweepConfig(sweepConfig *SweepConfig) SweepGroupConfig {
	groupID := sweepConfig.SweepGroupID
	if groupID == "" {
		groupID = defaultSweepGroupID
	}

	return SweepGroupConfig{
		ID:            groupID,
		SweepGroupID:  groupID,
		Networks:      sweepConfig.Networks,
		Ports:         sweepConfig.Ports,
		SweepModes:    sweepConfig.SweepModes,
		DeviceTargets: sweepConfig.DeviceTargets,
		BannerGrab:    sweepConfig.BannerGrab,
		Interval:      sweepConfig.Interval,
		Concurrency:   sweepConfig.Concurrency,
		Timeout:       sweepConfig.Timeout,
		ScheduleType:  intervalLiteral,
		ConfigHash:    sweepConfig.ConfigHash,
	}
}

func buildSweepModelConfigFromGroup(cfg *ServerConfig, group SweepGroupConfig, log logger.Logger) (*models.Config, error) {
	if cfg == nil {
		return nil, ErrAgentIDRequired
	}

	partition := cfg.Partition
	if partition == "" {
		log.Warn().Msg("Partition not configured, using 'default'. Consider setting partition in agent config")
		partition = defaultPartition
	}

	if cfg.AgentID == "" {
		return nil, ErrAgentIDRequired
	}

	return &models.Config{
		Networks:      group.Networks,
		Ports:         group.Ports,
		SweepModes:    group.SweepModes,
		DeviceTargets: group.DeviceTargets,
		BannerGrab:    toModelBannerGrab(group.BannerGrab),
		Interval:      time.Duration(group.Interval),
		Concurrency:   group.Concurrency,
		Timeout:       time.Duration(group.Timeout),
		AgentID:       cfg.AgentID,
		GatewayID:     cfg.AgentID,
		Partition:     partition,
		SweepGroupID:  group.SweepGroupID,
		ConfigHash:    group.ConfigHash,
	}, nil
}

func (s *Server) loadSweepService(
	ctx context.Context, cfgLoader *config.Config, filePath string,
) (Service, error) {
	var sweepConfig SweepConfig

	if err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			s.logger.Info().Str("path", filePath).Msg("Sweep config file not found, using defaults")
			sweepConfig = SweepConfig{}
		} else {
			return nil, fmt.Errorf("failed to load sweep config from file %s: %w", filePath, err)
		}
	} else {
		s.logger.Info().Str("path", filePath).Msg("Loaded sweep config from file")
	}

	service, err := s.createSweepService(ctx, &sweepConfig)
	if err != nil {
		return nil, err
	}

	return service, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, sweepType, "sweep.json")

	// Load sweep service
	service, err := s.loadSweepService(ctx, cfgLoader, fileSweepConfigPath)
	if err != nil {
		return fmt.Errorf("failed to load sweep service: %w", err)
	}

	if service != nil {
		s.services = append(s.services, service)
	}

	if s.config.Bumblebee != nil && s.config.Bumblebee.Enabled {
		s.services = append(s.services, NewBumblebeeSpoolService(s.config.AgentID, s.config.Bumblebee))
	}
	if s.config.EndpointInventory != nil && s.config.EndpointInventory.Enabled {
		s.services = append(s.services, NewEndpointInventorySpoolService(s.config.AgentID, s.config.EndpointInventory))
	}
	if s.config.K8sPublicEndpoints != nil && s.config.K8sPublicEndpoints.Enabled {
		s.services = append(s.services, NewK8sPublicEndpointsSpoolService(s.config.AgentID, s.config.K8sPublicEndpoints))
	}

	return nil
}

func (s *Server) initObjectStore(ctx context.Context) {
	if s == nil || s.config == nil || strings.TrimSpace(s.config.KVAddress) == "" {
		return
	}

	security := s.config.KVSecurity
	if security == nil {
		security = s.config.Security
	}
	if security == nil {
		s.logger.Warn().Str("addr", s.config.KVAddress).Msg("Skipping object store client: no security config")
		return
	}

	provider, err := srgrpc.NewSecurityProvider(ctx, security, s.logger)
	if err != nil {
		s.logger.Warn().Err(err).Str("addr", s.config.KVAddress).Msg("Failed to initialize object store security")
		return
	}

	client, err := srgrpc.NewClient(ctx, srgrpc.ClientConfig{
		Address:          s.config.KVAddress,
		SecurityProvider: provider,
		MaxRetries:       3,
		Logger:           s.logger,
	})
	if err != nil {
		_ = provider.Close()
		s.logger.Warn().Err(err).Str("addr", s.config.KVAddress).Msg("Failed to connect object store client")
		return
	}

	s.objectStore = &grpcRemoteStore{
		configClient: proto.NewKVServiceClient(client.GetConnection()),
		objectClient: proto.NewDataServiceClient(client.GetConnection()),
		conn:         client,
	}
}

func (s *Server) initNetprobeSidecarStatus() {
	netprobeSidecar := netprobe.NewSidecar(netprobe.SidecarConfig{
		Logger: s.logger.WithComponent("agent.netprobe"),
	})
	manager, err := netprobe.NewAttachManager(
		netprobe.AttachManagerConfig{
			ClientFactory: netprobe.ClientFactory(),
			Logger:        s.logger.WithComponent("agent.netprobe.attach"),
			// netprobe is systemd-supervised rather than agent-launched, so it
			// reaches this buffer through a pump instead of the go-plugin client.
			// Everything downstream of here is identical to a launched add-on's.
			AddonTelemetrySink: func(batch *addonpb.TelemetryBatch) {
				s.handleAddonTelemetry(netprobe.DefaultSidecarName, batch)
			},
		},
		netprobeSidecar,
	)
	if err != nil {
		s.logger.Warn().Err(err).Msg("Failed to initialize netprobe attach status")
		return
	}

	s.sidecarStatus = manager
	s.sidecarManager = manager
	s.netprobeSidecar = netprobeSidecar
}

// initAddonManager creates the native add-on (feature set) manager that supervises
// add-ons delivered via agent configuration as go-plugin subprocesses.
func (s *Server) initAddonManager() {
	if s.addonTelemetry == nil {
		s.addonTelemetry = newAddonTelemetryBuffer(defaultAddonTelemetryQueueSize)
	}
	if s.addonOtlpRelay == nil {
		s.addonOtlpRelay = newAddonOtlpRelayDeps()
	}

	localOtlpEndpoint := ""
	addonCgroupRoot := ""
	if s.config != nil {
		localOtlpEndpoint = strings.TrimSpace(s.config.LocalOtlpEndpoint)
		addonCgroupRoot = strings.TrimSpace(s.config.AddonCgroupRoot)
	}
	runtimeCgroupRoot, cgroupErr := defaultAddonCgroupRoot()
	if cgroupErr != nil {
		s.logger.Warn().Err(cgroupErr).
			Msg("Could not prepare delegated systemd cgroup for agent-sidecar add-ons")
	}
	if addonCgroupRoot == "" {
		addonCgroupRoot = runtimeCgroupRoot
		if addonCgroupRoot != "" {
			s.logger.Info().Str("cgroup_root", addonCgroupRoot).
				Msg("Using delegated systemd cgroup for agent-sidecar add-ons")
		}
	}

	s.addonManager = agentaddon.NewManager(agentaddon.Config{
		CredentialResolver: s.credentialBroker,
		TelemetryHandler:   s.handleAddonTelemetry,
		ArtifactHandler:    s.handleAddonArtifact,
		OtlpRelayRunner:    s.runAddonOtlpRelay,
		// Fallback self-telemetry endpoint (agent.local_otlp_endpoint); the
		// endpoint derived from a sidecar otel-collector add-on's delivered
		// config wins inside the manager.
		LocalOtlpEndpoint: localOtlpEndpoint,
		// Delegated cgroup v2 sub-tree for agent-sidecar add-on resource limits;
		// When omitted by an older persisted config, a delegated systemd
		// supervisor subgroup supplies the runtime default. Empty after that
		// disables enforcement (best-effort at launch either way).
		AddonCgroupRoot: addonCgroupRoot,
		Logger:          s.logger.WithComponent("agent.addon"),
	})
}

// initSysmonService creates and initializes the embedded sysmon service.
func (s *Server) initSysmonService(ctx context.Context) error {
	sysmonSvc, err := NewSysmonService(SysmonServiceConfig{
		AgentID:   s.config.AgentID,
		Partition: s.config.Partition,
		ConfigDir: s.configDir,
		Logger:    s.logger,
	})
	if err != nil {
		return fmt.Errorf("failed to create sysmon service: %w", err)
	}

	// Start the sysmon service
	if err := sysmonSvc.Start(ctx); err != nil {
		return fmt.Errorf("failed to start sysmon service: %w", err)
	}

	s.sysmonService = sysmonSvc
	s.logger.Info().Msg("Sysmon service initialized and started")
	return nil
}

// GetSysmonStatus returns the current sysmon metrics if the service is running.
func (s *Server) GetSysmonStatus(ctx context.Context) (*sysmon.MetricSample, error) {
	s.mu.RLock()
	svc := s.sysmonService
	s.mu.RUnlock()

	if svc == nil || !svc.IsEnabled() {
		return nil, nil
	}

	return svc.GetLatestSample(), nil
}

// initSNMPService creates and initializes the embedded SNMP service.
func (s *Server) initSNMPService(ctx context.Context) error {
	snmpSvc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:   s.config.AgentID,
		Partition: s.config.Partition,
		ConfigDir: s.configDir,
		Logger:    s.logger,
	})
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	// Start the SNMP service
	if err := snmpSvc.Start(ctx); err != nil {
		return fmt.Errorf("failed to start SNMP service: %w", err)
	}

	s.snmpService = snmpSvc
	s.logger.Info().Msg("SNMP service initialized and started")
	return nil
}

// GetSNMPStatus returns the current SNMP status if the service is running.
func (s *Server) GetSNMPStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	svc := s.snmpService
	s.mu.RUnlock()

	if svc == nil || !svc.IsEnabled() {
		return nil, nil
	}

	return svc.GetStatus(ctx)
}

type bannerGrabStatsProvider interface {
	GetBannerGrabStats() *models.BannerGrabStats
}

type bannerGrabConfigProvider interface {
	BannerGrabEnabled() bool
}

func (s *Server) BannerGrabEnabled() bool {
	s.mu.RLock()
	services := append([]Service(nil), s.services...)
	s.mu.RUnlock()

	for _, svc := range services {
		provider, ok := svc.(bannerGrabConfigProvider)
		if ok && provider.BannerGrabEnabled() {
			return true
		}
	}

	return false
}

func (s *Server) BannerGrabStats() *models.BannerGrabStats {
	s.mu.RLock()
	services := append([]Service(nil), s.services...)
	s.mu.RUnlock()

	var out models.BannerGrabStats
	found := false
	for _, svc := range services {
		provider, ok := svc.(bannerGrabStatsProvider)
		if !ok {
			continue
		}
		stats := provider.GetBannerGrabStats()
		if stats == nil {
			continue
		}

		found = true
		out.CandidatesTotal += stats.CandidatesTotal
		out.ProbesTotal += stats.ProbesTotal
		out.InFlight += stats.InFlight
		out.QueueDepth += stats.QueueDepth
		out.MatchBatchesTotal += stats.MatchBatchesTotal
		out.MatchBatchBytesTotal += stats.MatchBatchBytesTotal
		out.BannerBytesTotal += stats.BannerBytesTotal
		out.SkippedFreshTotal += stats.SkippedFreshTotal
		out.SkippedBackoffTotal += stats.SkippedBackoffTotal
		out.MatchesTotal += stats.MatchesTotal
		out.EmptyResponseTotal += stats.EmptyResponseTotal
		out.ConnectionResetTotal += stats.ConnectionResetTotal
		out.TimeoutTotal += stats.TimeoutTotal
		out.ErrorsTotal += stats.ErrorsTotal
	}
	if !found {
		return nil
	}

	return &out
}

func (s *Server) WritePrometheusMetrics(w io.Writer) error {
	stats := s.BannerGrabStats()
	if stats == nil {
		stats = &models.BannerGrabStats{}
	}

	metrics := []struct {
		name  string
		typ   string
		value uint64
	}{
		{"sweep_banner_grab_candidates_total", "counter", stats.CandidatesTotal},
		{"sweep_banner_grab_probes_total", "counter", stats.ProbesTotal},
		{"sweep_banner_grab_inflight", "gauge", stats.InFlight},
		{"sweep_banner_grab_queue_depth", "gauge", stats.QueueDepth},
		{"sweep_banner_grab_match_batches_total", "counter", stats.MatchBatchesTotal},
		{"sweep_banner_grab_match_batch_bytes_total", "counter", stats.MatchBatchBytesTotal},
		{"sweep_banner_grab_bytes_received_total", "counter", stats.BannerBytesTotal},
		{"sweep_banner_grab_skipped_fresh_total", "counter", stats.SkippedFreshTotal},
		{"sweep_banner_grab_skipped_backoff_total", "counter", stats.SkippedBackoffTotal},
		{"sweep_banner_grab_matches_total", "counter", stats.MatchesTotal},
		{"sweep_banner_grab_empty_response_total", "counter", stats.EmptyResponseTotal},
		{"sweep_banner_grab_connection_reset_total", "counter", stats.ConnectionResetTotal},
		{"sweep_banner_grab_timeout_total", "counter", stats.TimeoutTotal},
		{"sweep_banner_grab_errors_total", "counter", stats.ErrorsTotal},
		{"agent_flow_attribution_events_forwarded_total", "counter", AgentFlowAttributionEventsForwardedTotal()},
		{"agent_flow_attribution_events_quarantined_total", "counter", AgentFlowAttributionEventsQuarantinedTotal()},
	}

	for _, metric := range metrics {
		if _, err := fmt.Fprintf(w, "# TYPE %s %s\n%s %d\n", metric.name, metric.typ, metric.name, metric.value); err != nil {
			return fmt.Errorf("write prometheus metric %s: %w", metric.name, err)
		}
	}

	if _, err := fmt.Fprintln(w, "# TYPE agent_retained_poison_dropped_items_total counter"); err != nil {
		return fmt.Errorf("write agent retained poison item metric type: %w", err)
	}
	if _, err := fmt.Fprintln(w, "# TYPE agent_retained_poison_dropped_bytes_total counter"); err != nil {
		return fmt.Errorf("write agent retained poison byte metric type: %w", err)
	}
	for _, source := range retainedPoisonSourceNames {
		for _, reason := range retainedPoisonReasonNames {
			items, bytes := AgentRetainedPoisonDropTotals(source, reason)
			if _, err := fmt.Fprintf(
				w,
				"agent_retained_poison_dropped_items_total{source=%q,reason=%q} %d\n",
				source,
				reason,
				items,
			); err != nil {
				return fmt.Errorf("write agent retained poison item metric: %w", err)
			}
			if _, err := fmt.Fprintf(
				w,
				"agent_retained_poison_dropped_bytes_total{source=%q,reason=%q} %d\n",
				source,
				reason,
				bytes,
			); err != nil {
				return fmt.Errorf("write agent retained poison byte metric: %w", err)
			}
		}
	}

	return nil
}

func (s *Server) initPluginManager(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.pluginManager != nil {
		return
	}

	cacheDir := filepath.Join(s.configDir, "plugins")
	pluginHTTPClient, err := pluginHTTPClientWithTrustedCAs(s.config.PluginHTTPTrustedCAFiles)
	if err != nil {
		s.logger.Error().Err(err).Msg("Plugin HTTP trust configuration invalid; outbound plugin HTTP disabled")
		pluginHTTPClient = unavailablePluginHTTPClient(err)
	}
	s.pluginManager = NewPluginManager(ctx, PluginManagerConfig{
		CacheDir:           cacheDir,
		LocalStoreDir:      s.configDir,
		Logger:             s.logger,
		HTTPClient:         pluginHTTPClient,
		ArtifactHTTPClient: s.gatewayArtifactHTTPClient(),
		CredentialBroker:   s.credentialBroker,
		ArtifactUploader:   s.artifactUploader,
	})
}

func (s *Server) gatewayArtifactHTTPClient() *http.Client {
	if s == nil || s.config == nil {
		return unavailableGatewayArtifactHTTPClient(errReleaseGatewaySecurityRequired)
	}

	client, err := gatewayArtifactHTTPClient(s.config.GatewaySecurity)
	if err != nil {
		if s.logger != nil {
			s.logger.Warn().Err(err).Msg("Gateway artifact downloads unavailable")
		}

		return unavailableGatewayArtifactHTTPClient(err)
	}

	return client
}

// Start initializes and starts all agent services.
func (s *Server) Start(ctx context.Context) error {
	s.logger.Info().Msg("Starting agent service...")

	s.logger.Info().Int("services", len(s.services)).Msg("Found services to start")

	for i, svc := range s.services {
		s.logger.Info().Int("index", i).Str("service", svc.Name()).Msg("Starting service")

		go func(svc Service) { // Run in goroutine to avoid blocking
			if err := svc.Start(ctx); err != nil {
				s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start service")
			} else {
				s.logger.Info().Str("service", svc.Name()).Msg("Service started successfully")
			}
		}(svc)
	}

	return nil
}

// Stop gracefully shuts down all agent services.
func (s *Server) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping agent service...")

	if s.sidecarManager != nil {
		if err := s.sidecarManager.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop sidecar manager")
		}
	}

	if s.addonManager != nil {
		if err := s.addonManager.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop addon manager")
		}
	}

	// Stop sysmon service if running
	if s.sysmonService != nil {
		if err := s.sysmonService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop sysmon service")
		}
	}

	// Stop SNMP service if running
	if s.snmpService != nil {
		if err := s.snmpService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop SNMP service")
		}
	}

	// Stop mapper service if running
	if s.mapperService != nil {
		if err := s.mapperService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop mapper service")
		}
	}

	if s.pluginManager != nil {
		s.pluginManager.Stop()
	}

	if closer, ok := s.objectStore.(interface{ Close() error }); ok {
		if err := closer.Close(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to close object store client")
		}
	}

	for _, svc := range s.services {
		if err := svc.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to stop service")
		}
	}

	close(s.done)

	return nil
}

// UpdateConfig applies logging/security updates at runtime where possible.
// Security changes typically require a restart to fully apply to gRPC servers/clients.
func (s *Server) UpdateConfig(newCfg *ServerConfig) {
	if newCfg == nil {
		return
	}
	// Apply logging level changes if provided
	if newCfg.Logging != nil {
		lvl := strings.ToLower(newCfg.Logging.Level)
		switch lvl {
		case "debug":
			s.logger.SetDebug(true)
		case "info", "":
			s.logger.SetDebug(false)
		}
		s.logger.Info().Str("level", newCfg.Logging.Level).Msg("Agent logger level updated")
	}
	// Security changes: log advisory; full restart may be required
	if newCfg.Security != nil && s.config.Security != nil {
		// naive compare of cert paths
		if newCfg.Security.TLS != s.config.Security.TLS || newCfg.Security.Mode != s.config.Security.Mode {
			s.logger.Warn().Msg("Security config changed; restart recommended to apply TLS changes")
		}
	}
	s.config = newCfg
}

// RestartServices stops and starts all managed services using the current configuration.
func (s *Server) RestartServices(ctx context.Context) {
	s.logger.Info().Msg("Restarting agent services due to config changes")
	for _, svc := range s.services {
		if err := svc.Stop(ctx); err != nil {
			s.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to stop service during restart")
		}
	}
	for _, svc := range s.services {
		if err := svc.Start(ctx); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start service during restart")
		} else {
			s.logger.Info().Str("service", svc.Name()).Msg("Service restarted")
		}
	}
}

// SecurityConfig returns the server's security configuration.
func (s *Server) SecurityConfig() *models.SecurityConfig {
	return s.config.Security
}

// Close gracefully shuts down the server and releases resources.
func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Error during stop")

		return err
	}

	close(s.errChan)

	return nil
}
