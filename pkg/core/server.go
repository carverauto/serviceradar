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

// Package core pkg/core/server.go
package core

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
)

const (
	defaultPollerStatusUpdateInterval = 5 * time.Second
	shutdownTimeout                   = 10 * time.Second
	oneDay                            = 24 * time.Hour
	oneWeek                           = 7 * oneDay
	serviceradarDirPerms              = 0700
	pollerHistoryLimit                = 1000
	pollerDiscoveryTimeout            = 30 * time.Second
	pollerNeverReportedTimeout        = 30 * time.Second
	defaultDBPath                     = "/var/lib/serviceradar/serviceradar.db"
	statusUnknown                     = "unknown"
	sweepService                      = "sweep"
	dailyCleanupInterval              = 24 * time.Hour
	monitorInterval                   = 30 * time.Second
	defaultSkipInterval               = 5 * time.Minute
	defaultTimeout                    = 30 * time.Second
	defaultFlushInterval              = 10 * time.Second

	snmpDiscoveryResultsServiceType = "snmp-discovery-results"
	mapperDiscoveryServiceType      = "mapper_discovery"
)

func NewServer(ctx context.Context, config *models.DBConfig) (*Server, error) {
	normalizedConfig := normalizeConfig(config)

	database, err := db.New(ctx, normalizedConfig)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errDatabaseError, err)
	}

	authConfig, err := initializeAuthConfig(normalizedConfig)
	if err != nil {
		return nil, err
	}

	metricsConfig := models.MetricsConfig{
		Enabled:    normalizedConfig.Metrics.Enabled,
		Retention:  normalizedConfig.Metrics.Retention,
		MaxPollers: normalizedConfig.Metrics.MaxPollers,
	}

	metricsManager := metrics.NewManager(metricsConfig, database)

	// Initialize the NEW authoritative device registry
	deviceRegistry := registry.NewDeviceRegistry(database)

	// Initialize the DiscoveryService
	discoveryService := NewDiscoveryService(database, deviceRegistry)

	server := &Server{
		DB:                  database,
		DeviceRegistry:      deviceRegistry,
		discoveryService:    discoveryService,
		alertThreshold:      normalizedConfig.AlertThreshold,
		webhooks:            make([]alerts.AlertService, 0),
		ShutdownChan:        make(chan struct{}),
		pollerPatterns:      normalizedConfig.PollerPatterns,
		metrics:             metricsManager,
		snmpManager:         metricstore.NewSNMPManager(database),
		rperfManager:        metricstore.NewRperfManager(database),
		config:              normalizedConfig,
		authService:         auth.NewAuth(authConfig, database),
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		serviceBuffers:      make(map[string][]*models.ServiceStatus),
		serviceListBuffers:  make(map[string][]*models.Service),
		sysmonBuffers:       make(map[string][]*sysmonMetricBuffer),
		pollerStatusCache:   make(map[string]*models.PollerStatus),
		pollerStatusUpdates: make(map[string]*models.PollerStatus),
	}

	// Initialize the cache on startup
	if _, err := server.getPollerStatuses(ctx, true); err != nil {
		log.Printf("Warning: Failed to initialize poller status cache: %v", err)
	}

	// Initialize NATS event publisher if configured
	if err := server.initializeEventPublisher(ctx, normalizedConfig); err != nil {
		log.Printf("Warning: Failed to initialize event publisher: %v", err)
	}

	go server.flushBuffers(ctx)
	go server.flushPollerStatusUpdates(ctx)

	server.initializeWebhooks(normalizedConfig.Webhooks)

	return server, nil
}

func (s *Server) Start(ctx context.Context) error {
	log.Printf("Starting core service...")

	if err := s.cleanupUnknownPollers(ctx); err != nil {
		log.Printf("Warning: Failed to clean up unknown pollers: %v", err)
	}

	if s.grpcServer != nil {
		errCh := make(chan error, 1)

		go func() {
			if err := s.grpcServer.Start(); err != nil {
				select {
				case errCh <- err:
				default:
					log.Printf("gRPC server error: %v", err)
				}
			}
		}()
	}

	if err := s.sendStartupNotification(ctx); err != nil {
		log.Printf("Failed to send startup notification: %v", err)
	}

	go s.runMetricsCleanup(ctx)
	go s.monitorPollers(ctx)

	return nil
}

func (s *Server) Stop(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	if err := s.sendShutdownNotification(ctx); err != nil {
		log.Printf("Failed to send shutdown notification: %v", err)
	}

	if s.grpcServer != nil {
		s.grpcServer.Stop(ctx)
	}

	if err := s.DB.Close(); err != nil {
		log.Printf("Error closing database: %v", err)
	}

	// Close NATS connection if it exists
	if s.natsConn != nil {
		s.natsConn.Close()
		log.Printf("NATS connection closed")
	}

	close(s.ShutdownChan)

	return nil
}

func (s *Server) GetMetricsManager() metrics.MetricCollector {
	return s.metrics
}

func (s *Server) GetSNMPManager() metricstore.SNMPManager {
	return s.snmpManager
}

func (s *Server) GetDeviceRegistry() registry.Manager {
	return s.DeviceRegistry
}

func (s *Server) runMetricsCleanup(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if s.metrics != nil {
				s.metrics.CleanupStalePollers(oneWeek)
			} else {
				log.Printf("Error: metrics manager is nil")
			}
		}
	}
}

func (s *Server) Shutdown(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	if err := s.DB.Close(); err != nil {
		log.Printf("Error closing database: %v", err)
	}

	if len(s.webhooks) > 0 {
		alert := alerts.WebhookAlert{
			Level: alerts.Warning,
			Title: "Core Service Stopping",
			Message: fmt.Sprintf("ServiceRadar core service shutting down at %s",
				time.Now().Format(time.RFC3339)),
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			PollerID:  "core",
			Details: map[string]any{
				"hostname": getHostname(),
				"pid":      os.Getpid(),
			},
		}

		err := s.sendAlert(ctx, &alert)
		if err != nil {
			log.Printf("Error sending shutdown alert: %v", err)

			return
		}
	}

	close(s.ShutdownChan)
}

const (
	defaultShortTimeout = 10 * time.Second
)

func (s *Server) SetAPIServer(ctx context.Context, apiServer api.Service) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.apiServer = apiServer
	apiServer.SetKnownPollers(s.config.KnownPollers)

	apiServer.SetPollerHistoryHandler(ctx, func(pollerID string) ([]api.PollerHistoryPoint, error) {
		ctxWithTimeout, cancel := context.WithTimeout(ctx, defaultShortTimeout)
		defer cancel()

		points, err := s.DB.GetPollerHistoryPoints(ctxWithTimeout, pollerID, pollerHistoryLimit)
		if err != nil {
			return nil, fmt.Errorf("failed to get poller history: %w", err)
		}

		apiPoints := make([]api.PollerHistoryPoint, len(points))
		for i, p := range points {
			apiPoints[i] = api.PollerHistoryPoint{
				Timestamp: p.Timestamp,
				IsHealthy: p.IsHealthy,
			}
		}

		return apiPoints, nil
	})
}

func (s *Server) updateAPIState(pollerID string, apiStatus *api.PollerStatus) {
	if s.apiServer == nil {
		log.Printf("Warning: API server not initialized, state not updated")

		return
	}

	s.apiServer.UpdatePollerStatus(pollerID, apiStatus)

	log.Printf("Updated API server state for poller: %s", pollerID)
}

func (s *Server) GetRperfManager() metricstore.RperfManager {
	return s.rperfManager
}

func (s *Server) GetAuth() *auth.Auth {
	return s.authService
}
