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
	"net"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// PushLoop manages the periodic pushing of agent status to the gateway.
type PushLoop struct {
	server   *Server
	gateway  *GatewayClient
	interval time.Duration
	logger   logger.Logger
	done     chan struct{}
}

// NewPushLoop creates a new push loop.
func NewPushLoop(server *Server, gateway *GatewayClient, interval time.Duration, log logger.Logger) *PushLoop {
	if interval <= 0 {
		interval = defaultPushInterval
	}

	return &PushLoop{
		server:   server,
		gateway:  gateway,
		interval: interval,
		logger:   log,
		done:     make(chan struct{}),
	}
}

// Start begins the push loop. It runs until the context is cancelled.
func (p *PushLoop) Start(ctx context.Context) error {
	p.logger.Info().Dur("interval", p.interval).Msg("Starting push loop")

	// Initial connection attempt
	if err := p.gateway.Connect(ctx); err != nil {
		p.logger.Warn().Err(err).Msg("Initial gateway connection failed, will retry")
	}

	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()

	// Do an initial push immediately
	p.pushStatus(ctx)

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
	}

	// Collect status from all services
	statuses := p.collectAllStatuses(ctx)

	if len(statuses) == 0 {
		p.logger.Debug().Msg("No statuses to push")
		return
	}

	// Build the request
	req := &proto.GatewayStatusRequest{
		Services:  statuses,
		GatewayId: "", // Will be set by the gateway
		AgentId:   p.server.config.AgentID,
		Timestamp: time.Now().UnixNano(),
		Partition: p.server.config.Partition,
		SourceIp:  p.getSourceIP(),
		KvStoreId: p.server.config.KVAddress,
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
