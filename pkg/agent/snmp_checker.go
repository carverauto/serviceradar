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
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultConfigPath = "/etc/serviceradar/checkers"
	defaultInterval   = 60 * time.Second
	pollTimeout       = 5 * time.Second
	grpcRetries       = 3
)

type SNMPChecker struct {
	config      *snmp.SNMPConfig
	client      *grpc.Client // Updated to use grpc.Client
	agentClient proto.AgentServiceClient
	interval    time.Duration
	mu          sync.RWMutex
	wg          sync.WaitGroup
	done        chan struct{}
	logger      logger.Logger
}

func NewSNMPChecker(ctx context.Context, address string, security *models.SecurityConfig, log logger.Logger) (checker.Checker, error) {
	log.Info().Str("address", address).Msg("Creating new SNMP checker client")

	configPath := filepath.Join(defaultConfigPath, "snmp.json")
	if _, err := os.Stat(configPath); err != nil {
		return nil, fmt.Errorf("config file error: %w", err)
	}

	var cfg snmp.SNMPConfig

	cfgLoader := config.NewConfig(log)
	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load SNMP config: %w", err)
	}

	// Use provided security config, with a fallback if nil
	if security == nil {
		log.Warn().Msg("No security config provided for SNMP checker, using insecure defaults")

		security = &models.SecurityConfig{
			Mode: "none",
		}
	}

	clientCfg := grpc.ClientConfig{
		Address:    address,
		MaxRetries: grpcRetries,
		Logger:     log,
	}

	// Set server name from address if not provided
	if security.ServerName == "" {
		security.ServerName = strings.Split(address, ":")[0]
	}

	provider, err := grpc.NewSecurityProvider(ctx, security, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create security provider: %w", err)
	}

	clientCfg.SecurityProvider = provider

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create gRPC client: %w", err)
	}

	agentClient := proto.NewAgentServiceClient(client.GetConnection())

	c := &SNMPChecker{
		config:      &cfg,
		client:      client,
		agentClient: agentClient,
		interval:    defaultInterval,
		done:        make(chan struct{}),
		logger:      log,
	}

	return c, nil
}

func (c *SNMPChecker) Check(ctx context.Context, req *proto.StatusRequest) (available bool, msg json.RawMessage) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	reqCheck := &proto.StatusRequest{
		ServiceType: "snmp",
		ServiceName: "snmp",
		AgentId:     req.AgentId,
		PollerId:    req.PollerId,
	}

	resp, err := c.agentClient.GetStatus(ctx, reqCheck)
	if err != nil {
		c.logger.Error().Err(err).Msg("Failed to get SNMP status")
		return false, jsonError(fmt.Sprintf("Failed to get status: %v", err))
	}

	return resp.Available, resp.Message
}

func (c *SNMPChecker) Start(ctx context.Context) error {
	c.wg.Add(1)

	go c.healthCheckLoop(ctx)

	c.logger.Info().Msg("Started SNMP checker monitoring")

	return nil
}

func (c *SNMPChecker) Stop(ctx context.Context) error {
	c.logger.Info().Msg("Stopping SNMP checker...")
	close(c.done)

	done := make(chan struct{})

	go func() {
		c.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		c.logger.Info().Msg("SNMP checker monitoring stopped")
	case <-ctx.Done():
		return fmt.Errorf("timeout waiting for SNMP checker to stop: %w", ctx.Err())
	}

	if err := c.client.Close(); err != nil {
		return fmt.Errorf("failed to close gRPC client: %w", err)
	}

	return nil
}

func (c *SNMPChecker) healthCheckLoop(ctx context.Context) {
	defer c.wg.Done()

	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	if err := c.checkHealth(ctx); err != nil {
		c.logger.Error().Err(err).Msg("Initial SNMP health check failed")
	}

	for {
		select {
		case <-ctx.Done():
			c.logger.Info().Msg("Context canceled, stopping SNMP health checks")
			return
		case <-c.done:
			c.logger.Info().Msg("Received stop signal, stopping SNMP health checks")
			return
		case <-ticker.C:
			if err := c.checkHealth(ctx); err != nil {
				c.logger.Error().Err(err).Msg("SNMP health check failed")
			}
		}
	}
}

func (c *SNMPChecker) checkHealth(ctx context.Context) error {
	checkCtx, cancel := context.WithTimeout(ctx, time.Duration(c.config.Timeout))
	defer cancel()

	healthy, err := c.client.CheckHealth(checkCtx, "")
	if err != nil {
		return fmt.Errorf("health check failed: %w", err)
	}

	if !healthy {
		return errSNMPServiceUnhealthy
	}

	c.logger.Info().Msg("SNMP service health check passed")

	return nil
}
