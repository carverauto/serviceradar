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
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultConfigPath = "/etc/serviceradar/checkers"
	defaultInterval   = 60 * time.Second
	pollTimeout       = 5 * time.Second
	grpcRetries       = 3
)

type SNMPChecker struct {
	config      *snmp.Config
	client      *grpc.Client // Updated to use grpc.Client
	agentClient proto.AgentServiceClient
	interval    time.Duration
	mu          sync.RWMutex
	wg          sync.WaitGroup
	done        chan struct{}
}

func (c *SNMPChecker) Check(ctx context.Context) (available bool, msg string) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	req := &proto.StatusRequest{
		ServiceType: "snmp",
		ServiceName: "snmp",
	}

	resp, err := c.agentClient.GetStatus(ctx, req)
	if err != nil {
		log.Printf("Failed to get SNMP status: %v", err)
		return false, fmt.Sprintf("Failed to get status: %v", err)
	}

	return resp.Available, resp.Message
}

func (c *SNMPChecker) Start(ctx context.Context) error {
	c.wg.Add(1)

	go c.healthCheckLoop(ctx)

	log.Printf("Started SNMP checker monitoring")

	return nil
}

func (c *SNMPChecker) Stop(ctx context.Context) error {
	log.Printf("Stopping SNMP checker...")
	close(c.done)

	done := make(chan struct{})
	go func() {
		c.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Printf("SNMP checker monitoring stopped")
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
		log.Printf("Initial SNMP health check failed: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping SNMP health checks")
			return
		case <-c.done:
			log.Printf("Received stop signal, stopping SNMP health checks")
			return
		case <-ticker.C:
			if err := c.checkHealth(ctx); err != nil {
				log.Printf("SNMP health check failed: %v", err)
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

	log.Printf("SNMP service health check passed")

	return nil
}

func NewSNMPChecker(ctx context.Context, serviceName, details string) (checker.Checker, error) {
	// Server will pass the pre-initialized client via connections
	s := ctx.Value("server").(*Server) // Assume Server is passed via context (see registry update)
	if s == nil {
		return nil, fmt.Errorf("server context not provided for SNMP checker")
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	var address string
	var conf *CheckerConfig
	if c, ok := s.checkerConfs[serviceName]; ok && c.Type == "snmp" {
		conf = c
		address = c.Address
		if address == "" {
			address = c.ListenAddr
		}
	}
	if address == "" {
		address = details // Fallback to details if no config
	}

	conn, exists := s.connections[address]
	if !exists {
		return nil, fmt.Errorf("no gRPC connection available for SNMP checker at %s", address)
	}

	var cfg snmp.Config
	if conf != nil {
		if err := json.Unmarshal(conf.Additional, &cfg); err != nil {
			log.Printf("No additional SNMP config found for %s, using defaults: %v", serviceName, err)
		}
		if conf.Timeout != 0 {
			cfg.Timeout = config.Duration(conf.Timeout)
		}
	} else {
		cfg = snmp.Config{
			Timeout: config.Duration(defaultInterval),
		}
	}

	c := &SNMPChecker{
		config:      &cfg,
		client:      conn.client,
		agentClient: proto.NewAgentServiceClient(conn.client.GetConnection()),
		interval:    defaultInterval,
		done:        make(chan struct{}),
	}

	log.Printf("Successfully created SNMP checker for %s using shared client", address)

	return c, nil
}
