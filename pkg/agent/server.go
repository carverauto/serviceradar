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
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultTimeout     = 30 * time.Second
	jsonSuffix         = ".json"
	fallBackSuffix     = "fallback"
	grpcType           = "grpc"
	defaultErrChansize = 10

	// DeviceCache settings

	defaultIncrementalInterval = 5 * time.Minute
	defaultFullReportInterval  = 1 * time.Hour
	defaultCleanupInterval     = 1 * time.Hour
	defaultMaxAge              = 24 * time.Hour
	defaultBatchSize           = 1000
)

// NewServer initializes a new Server instance.
func NewServer(ctx context.Context, configDir string, cfg *ServerConfig) (*Server, error) {
	cfgLoader := config.NewConfig()

	s := initializeServer(configDir, cfg)

	kvStore, err := setupKVStore(ctx, cfgLoader, cfg)
	if err != nil {
		return nil, err
	}

	s.kvStore = kvStore

	s.createSweepService = func(sweepConfig *SweepConfig, kvStore KVStore) (Service, error) {
		return createSweepService(sweepConfig, kvStore, cfg)
	}

	// Initialize DeviceCache
	incrementalInterval := defaultIncrementalInterval
	fullReportInterval := defaultFullReportInterval
	cleanupInterval := defaultCleanupInterval
	maxAge := defaultMaxAge
	batchSize := defaultBatchSize

	if cfg.DeviceCacheConfig != nil {
		incrementalInterval = time.Duration(cfg.DeviceCacheConfig.IncrementalInterval)
		fullReportInterval = time.Duration(cfg.DeviceCacheConfig.FullReportInterval)
		cleanupInterval = time.Duration(cfg.DeviceCacheConfig.CleanupInterval)
		maxAge = time.Duration(cfg.DeviceCacheConfig.MaxAge)
		batchSize = cfg.DeviceCacheConfig.BatchSize
	}

	s.deviceCache = DeviceCache{
		Devices:             make(map[string]*DeviceState),
		IncrementalInterval: incrementalInterval,
		FullReportInterval:  fullReportInterval,
		CleanupInterval:     cleanupInterval,
		MaxAge:              maxAge,
		BatchSize:           batchSize,
	}

	// Setup device maintenance
	s.SetupDeviceMaintenance(ctx)

	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	return s, nil
}

// initializeServer creates a new Server struct with default values.
func initializeServer(configDir string, cfg *ServerConfig) *Server {
	return &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		configDir:    configDir,
		services:     make([]Service, 0),
		listenAddr:   cfg.ListenAddr,
		registry:     initRegistry(),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		config:       cfg,
		connections:  make(map[string]*CheckerConnection),
		deviceCache: DeviceCache{
			Devices: make(map[string]*DeviceState),
		},
	}
}

// setupKVStore configures the KV store if an address is provided.
func setupKVStore(ctx context.Context, cfgLoader *config.Config, cfg *ServerConfig) (KVStore, error) {
	if cfg.KVAddress == "" {
		log.Printf("KVAddress not set, skipping KV store setup")
		return nil, nil
	}

	clientCfg := grpc.ClientConfig{
		Address:    cfg.KVAddress,
		MaxRetries: 3,
	}

	securityConfig := cfg.Security
	if cfg.KVSecurity != nil {
		securityConfig = cfg.KVSecurity
	}

	if securityConfig == nil {
		return nil, errNoSecurityConfigKV
	}

	provider, err := grpc.NewSecurityProvider(ctx, securityConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create KV security provider: %w", err)
	}

	clientCfg.SecurityProvider = provider

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create KV gRPC client: %w", err)
	}

	kvStore := &grpcKVStore{
		client: proto.NewKVServiceClient(client.GetConnection()),
		conn:   client,
	}

	if kvStore.client == nil {
		if err := client.Close(); err != nil {
			log.Printf("Error closing client: %v", err)
			return nil, err
		}

		return nil, errFailedToInitializeKVClient
	}

	cfgLoader.SetKVStore(kvStore)

	return kvStore, nil
}

// createSweepService constructs a new SweepService instance.
func createSweepService(sweepConfig *SweepConfig, kvStore KVStore, cfg *ServerConfig) (Service, error) {
	if sweepConfig == nil {
		return nil, errSweepConfigNil
	}

	c := &models.Config{
		Networks:    sweepConfig.Networks,
		Ports:       sweepConfig.Ports,
		SweepModes:  sweepConfig.SweepModes,
		Interval:    time.Duration(sweepConfig.Interval),
		Concurrency: sweepConfig.Concurrency,
		Timeout:     time.Duration(sweepConfig.Timeout),
	}

	serverName := cfg.AgentID
	if cfg.AgentName != "" {
		serverName = cfg.AgentName
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	return NewSweepService(c, kvStore, configKey)
}

func (s *Server) loadSweepService(ctx context.Context, cfgLoader *config.Config, kvPath, filePath string) (Service, error) {
	var sweepConfig SweepConfig

	if service, err := s.tryLoadFromKV(ctx, kvPath, &sweepConfig); err == nil && service != nil {
		return service, nil
	}

	if err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig); err != nil {
		return nil, fmt.Errorf("failed to load sweep config from file %s: %w", filePath, err)
	}

	suffix := s.getLogSuffix()
	log.Printf("Loaded sweep config from file%s: %s", suffix, filePath)

	service, err := s.createSweepService(&sweepConfig, s.kvStore) // Pass s.kvStore
	if err != nil {
		return nil, err
	}

	return service, nil
}

func (s *Server) tryLoadFromKV(ctx context.Context, kvPath string, sweepConfig *SweepConfig) (Service, error) {
	if s.kvStore == nil {
		log.Printf("KV store not initialized, skipping KV fetch for sweep config")
		return nil, nil
	}

	value, found, err := s.kvStore.Get(ctx, kvPath)
	if err != nil {
		log.Printf("Failed to get sweep config from KV %s: %v", kvPath, err)
		return nil, err
	}

	if !found {
		log.Printf("Sweep config not found in KV at %s", kvPath)
		return nil, nil
	}

	if err = json.Unmarshal(value, sweepConfig); err != nil {
		log.Printf("Failed to unmarshal sweep config from KV %s: %v", kvPath, err)
		return nil, err
	}

	log.Printf("Loaded sweep config from KV: %s", kvPath)

	service, err := s.createSweepService(sweepConfig, s.kvStore) // Pass s.kvStore
	if err != nil {
		return nil, fmt.Errorf("failed to create sweep service from KV config: %w", err)
	}

	return service, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	if err := s.loadCheckerConfigs(ctx, cfgLoader); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, "sweep", "sweep.json")

	// Use AgentName for KV path, fall back to AgentID if not set
	serverName := s.config.AgentID // Default to AgentID

	if s.config.AgentName != "" {
		serverName = s.config.AgentName // Prefer AgentName
	}

	kvSweepConfigPath := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	// Load sweep service
	service, err := s.loadSweepService(ctx, cfgLoader, kvSweepConfigPath, fileSweepConfigPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("failed to load sweep service: %w", err)
	}

	if service != nil {
		s.services = append(s.services, service)
	}

	return nil
}

// getLogSuffix returns appropriate suffix based on KV store availability.
func (s *Server) getLogSuffix() string {
	if s.kvStore != nil {
		return " " + fallBackSuffix
	}

	return ""
}

func (s *Server) Start(ctx context.Context) error {
	log.Printf("Starting agent service...")

	if err := s.initializeCheckers(ctx); err != nil {
		return fmt.Errorf("failed to initialize checkers: %w", err)
	}

	log.Printf("Found %d services to start", len(s.services))

	for i, svc := range s.services {
		log.Printf("Starting service #%d: %s", i, svc.Name())

		go func(svc Service) { // Run in goroutine to avoid blocking
			if err := svc.Start(ctx); err != nil {
				log.Printf("Failed to start service %s: %v", svc.Name(), err)
			} else {
				log.Printf("Service %s started successfully", svc.Name())
			}
		}(svc)
	}

	return nil
}

func (s *Server) Stop(_ context.Context) error {
	log.Printf("Stopping agent service...")

	for _, svc := range s.services {
		if err := svc.Stop(context.Background()); err != nil {
			log.Printf("Failed to stop service %s: %v", svc.Name(), err)
		}
	}

	for name, conn := range s.connections {
		if err := conn.client.Close(); err != nil {
			log.Printf("Error closing connection to checker %s: %v", name, err)
		}
	}

	close(s.done)

	return nil
}

func (s *Server) ListenAddr() string {
	return s.config.ListenAddr
}

func (s *Server) SecurityConfig() *models.SecurityConfig {
	return s.config.Security
}

func (e *ServiceError) Error() string {
	return fmt.Sprintf("service %s error: %v", e.ServiceName, e.Err)
}

func (s *Server) initializeCheckers(ctx context.Context) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	s.connections = make(map[string]*CheckerConnection)

	cfgLoader := config.NewConfig()

	if s.kvStore != nil {
		cfgLoader.SetKVStore(s.kvStore)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		filePath := filepath.Join(s.configDir, file.Name())

		conf, err := s.loadCheckerConfig(ctx, cfgLoader, filePath)
		if err != nil {
			log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

			continue
		}

		if conf.Type == grpcType {
			conn, err := s.connectToChecker(ctx, conf)
			if err != nil {
				log.Printf("Warning: Failed to connect to checker %s: %v", conf.Name, err)
				continue
			}

			s.connections[conf.Name] = conn
		}

		s.checkerConfs[conf.Name] = conf

		log.Printf("Loaded checker config: %s (type: %s)", conf.Name, conf.Type)
	}

	return nil
}

func (c *CheckerConnection) EnsureConnected(ctx context.Context) (*grpc.Client, error) {
	c.mu.RLock()
	if c.healthy && c.client != nil {
		c.mu.RUnlock()
		return c.client, nil
	}
	c.mu.RUnlock()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after locking
	if c.healthy && c.client != nil {
		return c.client, nil
	}

	// Close existing connection if it exists
	if c.client != nil {
		_ = c.client.Close()
	}

	clientCfg := grpc.ClientConfig{
		Address:    c.address,
		MaxRetries: 3,
	}

	// Add security provider as needed
	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		c.healthy = false

		return nil, fmt.Errorf("failed to reconnect to %s: %w", c.serviceName, err)
	}

	c.client = client
	c.healthy = true

	return client, nil
}

func (s *Server) connectToChecker(ctx context.Context, checkerConfig *CheckerConfig) (*CheckerConnection, error) {
	clientCfg := grpc.ClientConfig{
		Address:    checkerConfig.Address,
		MaxRetries: 3,
	}

	if s.config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, s.config.Security)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	log.Printf("Connecting to checker service %s at %s", checkerConfig.Name, checkerConfig.Address)

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to checker %s: %w", checkerConfig.Name, err)
	}

	return &CheckerConnection{
		client:      client,
		serviceName: checkerConfig.Name,
		serviceType: checkerConfig.Type,
		address:     checkerConfig.Address,
	}, nil
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	var response *proto.StatusResponse
	var deviceInfo *models.DeviceInfo

	// TODO: populate pollerID in ctx and retrieve
	pollerID := "" // Poller ID could be passed via context or configuration if available

	switch {
	case isRperfCheckerRequest(req):
		response, _ = s.handleRperfChecker(ctx, req)
	case isICMPRequest(req):
		response, _ = s.handleICMPCheck(ctx, req)
		if response != nil && response.Available {
			// Extract device info from ICMP response
			deviceInfo = extractDeviceInfoFromICMP(response.Message, req.Details)
		}
	case isSweepRequest(req):
		response, _ = s.getSweepStatus(ctx)
		if response != nil {
			// Extract devices from sweep status
			extractDevicesFromSweep(response.Message, s)
		}
	default:
		response, _ = s.handleDefaultChecker(ctx, req)
		if response != nil && isDeviceService(req.ServiceType) {
			deviceInfo = extractDeviceInfoFromChecker(req, response)
		}
	}

	// Update device cache with individual device
	if deviceInfo != nil {
		s.updateDeviceCache(deviceInfo, pollerID)
	}

	return response, nil
}

// Helper functions to extract device info
func extractDeviceInfoFromICMP(message, host string) *models.DeviceInfo {
	var icmpData struct {
		Host         string  `json:"host"`
		ResponseTime int64   `json:"response_time"`
		PacketLoss   float64 `json:"packet_loss"`
		Available    bool    `json:"available"`
	}

	if err := json.Unmarshal([]byte(message), &icmpData); err != nil {
		return nil
	}

	return &models.DeviceInfo{
		IP:              icmpData.Host,
		Available:       icmpData.Available,
		DiscoverySource: "icmp",
		LastSeen:        time.Now().Unix(),
	}
}

func extractDevicesFromSweep(message string, s *Server) {
	var sweepData struct {
		Hosts []models.HostResult `json:"hosts"`
	}

	if err := json.Unmarshal([]byte(message), &sweepData); err != nil {
		return
	}

	// Update device cache with each host from sweep
	for _, host := range sweepData.Hosts {
		deviceInfo := &models.DeviceInfo{
			IP:              host.Host,
			Available:       host.Available,
			DiscoverySource: "network_sweep",
			OpenPorts:       host.OpenPorts,
			LastSeen:        time.Now().Unix(),
		}

		s.updateDeviceCache(deviceInfo)
	}
}

func isDeviceService(serviceType string) bool {
	return serviceType == "icmp" || serviceType == "port" || serviceType == "snmp"
}

func extractDeviceInfoFromChecker(req *proto.StatusRequest, resp *proto.StatusResponse) *models.DeviceInfo {
	switch req.ServiceType {
	case "port":
		parts := strings.Split(req.Details, ":")
		if len(parts) >= 1 {
			host := parts[0]
			return &models.DeviceInfo{
				IP:              host,
				Available:       resp.Available,
				DiscoverySource: "port_check",
				LastSeen:        time.Now().Unix(),
			}
		}
	case "snmp":
		return &models.DeviceInfo{
			IP:              req.Details,
			Available:       resp.Available,
			DiscoverySource: "snmp_check",
			LastSeen:        time.Now().Unix(),
		}
	}

	return nil
}

func (s *Server) updateDeviceCache(info *models.DeviceInfo, pollerID string) {
	if info == nil || info.IP == "" {
		return
	}

	s.deviceCache.mu.Lock()
	defer s.deviceCache.mu.Unlock()

	key := info.IP
	now := time.Now()

	if device, exists := s.deviceCache.Devices[key]; exists {
		oldInfo := device.Info

		updateDeviceFields(&device.Info, info)

		device.LastSeen = now
		device.Sources[info.DiscoverySource] = true
		device.PollerID = pollerID

		if hasSignificantChanges(oldInfo, device.Info) {
			device.Changed = true
			device.Reported = false
			device.ReportCount++
		}
	} else {
		s.deviceCache.Devices[key] = &DeviceState{
			Info:        *info,
			Reported:    false,
			Changed:     true,
			LastSeen:    now,
			FirstSeen:   now,
			Sources:     map[string]bool{info.DiscoverySource: true},
			ReportCount: 0,
			AgentID:     s.config.AgentID,
			PollerID:    pollerID,
		}
	}
}

// hasSignificantChanges checks if there are significant changes between old and new DeviceInfo.
func hasSignificantChanges(old, new models.DeviceInfo) bool {
	return old.Available != new.Available ||
		!reflect.DeepEqual(old.OpenPorts, new.OpenPorts) ||
		old.Hostname != new.Hostname ||
		old.MAC != new.MAC ||
		old.NetworkSegment != new.NetworkSegment ||
		old.ServiceType != new.ServiceType ||
		old.ServiceName != new.ServiceName ||
		old.ResponseTime != new.ResponseTime ||
		old.PacketLoss != new.PacketLoss ||
		old.DeviceType != new.DeviceType ||
		old.Vendor != new.Vendor ||
		old.Model != new.Model ||
		old.OSInfo != new.OSInfo ||
		!reflect.DeepEqual(old.Metadata, new.Metadata)
}

// updateDeviceFields merges source DeviceInfo into target, preserving non-empty fields.
func updateDeviceFields(target, source *models.DeviceInfo) {
	if source.MAC != "" {
		target.MAC = source.MAC
	}

	if source.Hostname != "" {
		target.Hostname = source.Hostname
	}

	target.Available = source.Available
	target.LastSeen = source.LastSeen

	if len(source.OpenPorts) > 0 {
		target.OpenPorts = source.OpenPorts
	}

	if source.NetworkSegment != "" {
		target.NetworkSegment = source.NetworkSegment
	}

	if source.ServiceType != "" {
		target.ServiceType = source.ServiceType
	}

	if source.ServiceName != "" {
		target.ServiceName = source.ServiceName
	}

	if source.ResponseTime > 0 {
		target.ResponseTime = source.ResponseTime
	}

	if source.PacketLoss > 0 {
		target.PacketLoss = source.PacketLoss
	}

	if source.DeviceType != "" {
		target.DeviceType = source.DeviceType
	}

	if source.Vendor != "" {
		target.Vendor = source.Vendor
	}

	if source.Model != "" {
		target.Model = source.Model
	}

	if source.OSInfo != "" {
		target.OSInfo = source.OSInfo
	}

	if source.Metadata != nil {
		if target.Metadata == nil {
			target.Metadata = make(map[string]string)
		}

		for k, v := range source.Metadata {
			target.Metadata[k] = v
		}
	}
}

func isRperfCheckerRequest(req *proto.StatusRequest) bool {
	return req.ServiceName == "rperf-checker" && req.ServiceType == "grpc"
}

func isICMPRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == "icmp" && req.Details != ""
}

func isSweepRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == "sweep"
}

var (
	errNotExternalChecker = errors.New("checker is not an ExternalChecker")
)

func (s *Server) handleRperfChecker(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("failed to get rperf checker: %w", err)
	}

	extChecker, ok := c.(*ExternalChecker)
	if !ok {
		return nil, errNotExternalChecker
	}

	if err := extChecker.ensureConnected(ctx); err != nil {
		log.Printf("Failed to ensure connection for rperf-checker: %v", err)

		return nil, fmt.Errorf("failed to ensure rperf-checker connection: %w", err)
	}

	agentClient := proto.NewAgentServiceClient(extChecker.grpcClient.GetConnection())

	return agentClient.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: "",
		ServiceType: "grpc",
		Details:     "",
	})
}

func (s *Server) handleICMPCheck(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		sweepSvc, ok := svc.(*SweepService)
		if !ok {
			continue
		}

		result, err := sweepSvc.CheckICMP(ctx, req.Details)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errICMPCheck, err)
		}

		resp := &ICMPResponse{
			Host:         result.Target.Host,
			ResponseTime: result.RespTime.Nanoseconds(),
			PacketLoss:   result.PacketLoss,
			Available:    result.Available,
		}

		jsonResp, _ := json.Marshal(resp)

		return &proto.StatusResponse{
			Available:    result.Available,
			Message:      string(jsonResp),
			ServiceName:  "icmp_check",
			ServiceType:  "icmp",
			ResponseTime: result.RespTime.Nanoseconds(),
		}, nil
	}

	return nil, errNoSweepService
}

func (s *Server) handleDefaultChecker(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, err
	}

	available, message := c.Check(ctx)

	return &proto.StatusResponse{
		Available:   available,
		Message:     message,
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
	}, nil
}

func (s *Server) loadCheckerConfig(ctx context.Context, cfgLoader *config.Config, filePath string) (*CheckerConfig, error) {
	var conf *CheckerConfig

	// Determine KV path
	kvPath := filepath.Base(filePath)
	if s.config.AgentID != "" {
		kvPath = fmt.Sprintf("agents/%s/checkers/%s", s.config.AgentID, filepath.Base(filePath))
	}

	// Try KV if available
	var err error
	if s.kvStore != nil {
		if err = cfgLoader.LoadAndValidate(ctx, kvPath, &conf); err == nil {
			log.Printf("Loaded checker config from KV: %s", kvPath)

			return s.applyCheckerDefaults(conf), nil
		}

		log.Printf("Failed to load checker config from KV %s: %v", kvPath, err)
	}

	// Load from file (either directly or as fallback)
	if err = cfgLoader.LoadAndValidate(ctx, filePath, &conf); err != nil {
		return conf, fmt.Errorf("failed to load checker config %s: %w", filePath, err)
	}

	suffix := ""
	if s.kvStore != nil {
		suffix = " " + fallBackSuffix
	}

	log.Printf("Loaded checker config from file%s: %s", suffix, filePath)

	return s.applyCheckerDefaults(conf), nil
}

// applyCheckerDefaults sets default values for a CheckerConfig.
func (*Server) applyCheckerDefaults(conf *CheckerConfig) *CheckerConfig {
	if conf.Timeout == 0 {
		conf.Timeout = Duration(defaultTimeout)
	}

	if conf.Type == grpcType && conf.Address == "" {
		conf.Address = conf.ListenAddr
	}

	return conf
}

func (s *Server) loadCheckerConfigs(ctx context.Context, cfgLoader *config.Config) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		filePath := filepath.Join(s.configDir, file.Name())

		conf, err := s.loadCheckerConfig(ctx, cfgLoader, filePath)
		if err != nil {
			log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

			continue
		}

		s.checkerConfs[conf.Name] = conf

		log.Printf("Loaded checker config: %s (type: %s)", conf.Name, conf.Type)
	}

	return nil
}

func (s *Server) getSweepStatus(ctx context.Context) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			return provider.GetStatus(ctx)
		}
	}

	return &proto.StatusResponse{
		Available:   false,
		Message:     "Sweep service not configured",
		ServiceName: "network_sweep",
		ServiceType: "sweep",
	}, nil
}

func (s *Server) getChecker(ctx context.Context, req *proto.StatusRequest) (checker.Checker, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s:%s", req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	log.Printf("Getting checker for request - Type: %s, Name: %s, Details: %s",
		req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	if check, exists := s.checkers[key]; exists {
		return check, nil
	}

	details := req.GetDetails()

	log.Printf("Creating new checker with details: %s", details)

	check, err := s.registry.Get(ctx, req.ServiceType, req.ServiceName, details, s.config.Security)
	if err != nil {
		log.Printf("Failed to create checker for key %s: %v", key, err)

		return nil, fmt.Errorf("failed to create checker: %w", err)
	}

	s.checkers[key] = check

	log.Printf("Cached new checker for key: %s", key)

	return check, nil
}

func (s *Server) ListServices() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	services := make([]string, 0, len(s.checkerConfs))
	for name := range s.checkerConfs {
		services = append(services, name)
	}

	return services
}

func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		log.Printf("Error during stop: %v", err)

		return err
	}

	close(s.errChan)

	return nil
}
