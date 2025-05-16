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

package discovery

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/agent"
	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/gosnmp/gosnmp"
)

// DiscoveryEngine manages the SNMP discovery process.
type DiscoveryEngine struct {
	config      *models.DiscoveryConfig
	snmpClient  *snmp.SNMPClientImpl
	icmpChecker *models.ICMPChecker
	results     chan DiscoveryResult
	store       *sync.Map // Stores DiscoveryResult by IP
	stopChan    chan struct{}
	wg          sync.WaitGroup
	logger      *log.Logger
	credentials []snmp.Target
	mu          sync.RWMutex
}

// NewDiscoveryEngine initializes a new discovery engine.
func NewDiscoveryEngine(config *models.DiscoveryConfig, logger *log.Logger) (*DiscoveryEngine, error) {
	if config.Concurrency <= 0 {
		config.Concurrency = 20
	}
	if config.Timeout == 0 {
		config.Timeout = models.Duration(5 * time.Second)
	}
	if config.Retries == 0 {
		config.Retries = 3
	}

	// Initialize a dummy SNMP client (will be configured per target)
	snmpClient := &snmp.SNMPClientImpl{
		Client: &gosnmp.GoSNMP{
			Timeout: time.Duration(config.Timeout),
			Retries: config.Retries,
			MaxOids: gosnmp.MaxOids,
		},
	}

	icmpChecker, err := agent.NewICMPChecker("127.0.0.1") // Default host, will be overridden
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP checker: %w", err)
	}

	return &DiscoveryEngine{
		config:      config,
		snmpClient:  snmpClient,
		icmpChecker: icmpChecker,
		results:     make(chan DiscoveryResult, config.Concurrency*2),
		store:       &sync.Map{},
		stopChan:    make(chan struct{}),
		logger:      logger,
		credentials: config.Credentials,
	}, nil
}

// Start implements agent.Service interface.
func (de *DiscoveryEngine) Start(ctx context.Context) error {
	de.logger.Printf("Starting SNMP discovery engine with interval %v", time.Duration(de.config.Interval))
	ticker := time.NewTicker(time.Duration(de.config.Interval))
	defer ticker.Stop()

	de.wg.Add(1)
	go de.processResults(ctx)

	for {
		select {
		case <-ctx.Done():
			de.logger.Printf("Context cancelled, stopping discovery engine")
			return ctx.Err()
		case <-de.stopChan:
			de.logger.Printf("Stop signal received, stopping discovery engine")
			return nil
		case <-ticker.C:
			de.logger.Printf("Starting new discovery cycle")
			if err := de.runDiscoveryCycle(ctx); err != nil {
				de.logger.Printf("Discovery cycle failed: %v", err)
			}
		}
	}
}

// Stop implements agent.Service interface.
func (de *DiscoveryEngine) Stop(_ context.Context) error {
	de.logger.Printf("Stopping SNMP discovery engine")
	close(de.stopChan)
	close(de.results)
	de.wg.Wait()
	if err := de.icmpChecker.Close(context.Background()); err != nil {
		return fmt.Errorf("failed to close ICMP checker: %w", err)
	}
	return nil
}

// Name implements agent.Service interface.
func (de *DiscoveryEngine) Name() string {
	return "snmp_discovery"
}

// UpdateConfig implements agent.Service interface.
func (de *DiscoveryEngine) UpdateConfig(config *models.Config) error {
	// Not implemented for now, as discovery config is separate
	return fmt.Errorf("config update not supported for discovery engine")
}

// GetDiscoveryResults returns the latest discovery results for the poller.
func (de *DiscoveryEngine) GetDiscoveryResults(_ context.Context, _ *proto.DiscoveryRequest) (*proto.DiscoveryResponse, error) {
	de.mu.RLock()
	defer de.mu.RUnlock()

	var sweepResults []*proto.SweepResult
	var interfaces []*proto.DiscoveredInterface
	var topologyEvents []*proto.TopologyDiscoveryEvent

	de.store.Range(func(key, value interface{}) bool {
		result := value.(DiscoveryResult)
		sweepResults = append(sweepResults, &proto.SweepResult{
			AgentId:         result.SweepResult.AgentID,
			PollerId:        result.SweepResult.PollerID,
			DiscoverySource: result.SweepResult.DiscoverySource,
			Ip:              result.SweepResult.IP,
			Mac:             result.SweepResult.MAC,
			Hostname:        result.SweepResult.Hostname,
			Timestamp:       result.SweepResult.Timestamp.UnixNano(),
			Available:       result.SweepResult.Available,
			Metadata:        result.SweepResult.Metadata,
		})
		for _, iface := range result.Interfaces {
			interfaces = append(interfaces, &proto.DiscoveredInterface{
				Timestamp:     iface.Timestamp.UnixNano(),
				AgentId:       iface.AgentID,
				PollerId:      iface.PollerID,
				DeviceIp:      iface.DeviceIP,
				DeviceId:      iface.DeviceID,
				IfIndex:       int32(iface.IfIndex),
				IfName:        iface.IfName,
				IfDescr:       iface.IfDescr,
				IfAlias:       iface.IfAlias,
				IfSpeed:       iface.IfSpeed,
				IfPhysAddress: iface.IfPhysAddress,
				IpAddresses:   iface.IPAddresses,
				IfAdminStatus: int32(iface.IfAdminStatus),
				IfOperStatus:  int32(iface.IfOperStatus),
				Metadata:      iface.Metadata,
			})
		}
		for _, neighbor := range append(result.LLDPNeighbors, result.CDPNeighbors...) {
			topologyEvents = append(topologyEvents, &proto.TopologyDiscoveryEvent{
				Timestamp:              neighbor.Timestamp.UnixNano(),
				AgentId:                neighbor.AgentID,
				PollerId:               neighbor.PollerID,
				LocalDeviceIp:          neighbor.LocalDeviceIP,
				LocalDeviceId:          neighbor.LocalDeviceID,
				LocalIfIndex:           int32(neighbor.LocalIfIndex),
				LocalIfName:            neighbor.LocalIfName,
				ProtocolType:           neighbor.ProtocolType,
				NeighborChassisId:      neighbor.NeighborChassisID,
				NeighborPortId:         neighbor.NeighborPortID,
				NeighborPortDescr:      neighbor.NeighborPortDescr,
				NeighborSystemName:     neighbor.NeighborSystemName,
				NeighborManagementAddr: neighbor.NeighborManagementAddr,
				Metadata:               neighbor.Metadata,
			})
		}
		return true
	})

	return &proto.DiscoveryResponse{
		SweepResults:   sweepResults,
		Interfaces:     interfaces,
		TopologyEvents: topologyEvents,
	}, nil
}

// runDiscoveryCycle executes a single discovery cycle.
func (de *DiscoveryEngine) runDiscoveryCycle(ctx context.Context) error {
	targets := de.generateTargets()
	workerPool := make(chan struct{}, de.config.Concurrency)

	for _, target := range targets {
		select {
		case workerPool <- struct{}{}:
			de.wg.Add(1)
			go func(ip string) {
				defer func() { <-workerPool }()
				defer de.wg.Done()
				de.discoverDevice(ctx, ip)
			}(target)
		case <-ctx.Done():
			return ctx.Err()
		case <-de.stopChan:
			return nil
		}
	}

	return nil
}

// generateTargets creates a list of IP addresses to scan.
func (de *DiscoveryEngine) generateTargets() []string {
	var targets []string
	seen := make(map[string]struct{})

	// Add seed IPs
	for _, ip := range de.config.SeedIPs {
		if net.ParseIP(ip) != nil {
			seen[ip] = struct{}{}
			targets = append(targets, ip)
		}
	}

	// Add IPs from subnets
	for _, subnet := range de.config.SeedSubnets {
		_, ipNet, err := net.ParseCIDR(subnet)
		if err != nil {
			de.logger.Printf("Invalid subnet %s: %v", subnet, err)
			continue
		}
		for ip := ipNet.IP; ipNet.Contains(ip); incIP(ip) {
			ipStr := ip.String()
			if _, exists := seen[ipStr]; !exists {
				seen[ipStr] = struct{}{}
				targets = append(targets, ipStr)
			}
		}
	}

	return targets
}

// incIP increments an IP address.
func incIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}

// discoverDevice performs SNMP discovery on a single device.
func (de *DiscoveryEngine) discoverDevice(ctx context.Context, ip string) {
	// Check reachability using ICMP
	de.icmpChecker.Host = ip
	available, _ := de.icmpChecker.Check(ctx)
	if !available {
		de.logger.Printf("Device %s is not reachable via ICMP", ip)
		return
	}

	for _, cred := range de.credentials {
		if result, err := de.probeDevice(ctx, ip, cred); err == nil {
			de.results <- result
			return
		} else {
			de.logger.Printf("Failed to probe %s with credential %v: %v", ip, cred, err)
		}
	}
}

// probeDevice attempts to collect data from a device using provided credentials.
func (de *DiscoveryEngine) probeDevice(ctx context.Context, ip string, cred snmp.Target) (DiscoveryResult, error) {
	// Configure SNMP client for this target
	cred.Host = ip
	client, err := snmp.NewSNMPClient(&cred)
	if err != nil {
		return DiscoveryResult{}, fmt.Errorf("failed to configure SNMP client for %s: %w", ip, err)
	}
	defer client.Close()

	// Connect to the device
	if err := client.Connect(); err != nil {
		return DiscoveryResult{}, fmt.Errorf("failed to connect to %s: %w", ip, err)
	}

	// Collect system information
	sysInfo, err := de.snmpClient.GetSystemInfo(ctx, client)
	if err != nil {
		return DiscoveryResult{}, fmt.Errorf("failed to get system info for %s: %w", ip, err)
	}

	// Collect interface information
	interfaces, err := de.snmpClient.GetInterfaces(ctx, client)
	if err != nil {
		de.logger.Printf("Failed to get interfaces for %s: %v", ip, err)
	}

	// Collect IP address mappings
	ipAddrs, err := de.snmpClient.GetIPAddresses(ctx, client)
	if err != nil {
		de.logger.Printf("Failed to get IP addresses for %s: %v", ip, err)
	}

	// Collect LLDP neighbors
	lldpNeighbors, err := de.snmpClient.GetLLDPNeighbors(ctx, client)
	if err != nil {
		de.logger.Printf("Failed to get LLDP neighbors for %s: %v", ip, err)
	}

	// Collect CDP neighbors
	cdpNeighbors, err := de.snmpClient.GetCDPNeighbors(ctx, client)
	if err != nil {
		de.logger.Printf("Failed to get CDP neighbors for %s: %v", ip, err)
	}

	result := DiscoveryResult{
		SweepResult: models.SweepResult{
			AgentID:         "agent-1",  // Replace with actual agent ID
			PollerID:        "poller-1", // Replace with actual poller ID
			DiscoverySource: "snmp_discovery",
			IP:              ip,
			Hostname:        sysInfo.SysName,
			Timestamp:       time.Now(),
			Available:       true,
			Metadata:        map[string]interface{}{"sysDescr": sysInfo.SysDescr, "sysObjectID": sysInfo.SysObjectID},
		},
		Interfaces:    interfaces,
		IPAddresses:   ipAddrs,
		LLDPNeighbors: lldpNeighbors,
		CDPNeighbors:  cdpNeighbors,
	}

	return result, nil
}

// DiscoveryResult holds the results of a device discovery.
type DiscoveryResult struct {
	SweepResult   models.SweepResult
	Interfaces    []models.DiscoveredInterface
	IPAddresses   map[int][]string
	LLDPNeighbors []models.TopologyDiscoveryEvent
	CDPNeighbors  []models.TopologyDiscoveryEvent
}

// processResults stores discovery results for poller queries.
func (de *DiscoveryEngine) processResults(ctx context.Context) {
	defer de.wg.Done()
	for result := range de.results {
		de.mu.Lock()
		de.store.Store(result.SweepResult.IP, result)
		de.mu.Unlock()
	}
}
