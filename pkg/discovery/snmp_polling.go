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
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/gosnmp/gosnmp"
)

// Common SNMP OIDs - defined as constants for clarity and maintainability
const (
	// System OIDs
	oidSysDescr    = ".1.3.6.1.2.1.1.1.0"
	oidSysObjectID = ".1.3.6.1.2.1.1.2.0"
	oidSysUptime   = ".1.3.6.1.2.1.1.3.0"
	oidSysContact  = ".1.3.6.1.2.1.1.4.0"
	oidSysName     = ".1.3.6.1.2.1.1.5.0"
	oidSysLocation = ".1.3.6.1.2.1.1.6.0"

	// Interface table OIDs
	oidIfTable = ".1.3.6.1.2.1.2.2.1"
	// oidIfIndex       = ".1.3.6.1.2.1.2.2.1.1"
	oidIfDescr = ".1.3.6.1.2.1.2.2.1.2"
	oidIfType  = ".1.3.6.1.2.1.2.2.1.3"
	// oidIfMtu         = ".1.3.6.1.2.1.2.2.1.4"
	oidIfSpeed       = ".1.3.6.1.2.1.2.2.1.5"
	oidIfPhysAddress = ".1.3.6.1.2.1.2.2.1.6"
	oidIfAdminStatus = ".1.3.6.1.2.1.2.2.1.7"
	oidIfOperStatus  = ".1.3.6.1.2.1.2.2.1.8"

	// IP address table OIDs
	oidIPAddrTable    = ".1.3.6.1.2.1.4.20.1"
	oidIPAdEntAddr    = ".1.3.6.1.2.1.4.20.1.1"
	oidIPAdEntIfIndex = ".1.3.6.1.2.1.4.20.1.2"

	// Extended interface table (ifXTable)
	oidIfXTable    = ".1.3.6.1.2.1.31.1.1.1"
	oidIfName      = ".1.3.6.1.2.1.31.1.1.1.1"
	oidIfAlias     = ".1.3.6.1.2.1.31.1.1.1.18"
	oidIfHighSpeed = ".1.3.6.1.2.1.31.1.1.1.15"

	// LLDP OIDs
	oidLLDPRemTable = ".1.0.8802.1.1.2.1.4.1.1"
	// oidLldpRemChassisId = ".1.0.8802.1.1.2.1.4.1.1.5"
	// oidLldpRemPortId    = ".1.0.8802.1.1.2.1.4.1.1.7"
	// oidLldpRemPortDesc  = ".1.0.8802.1.1.2.1.4.1.1.8"
	// oidLldpRemSysName   = ".1.0.8802.1.1.2.1.4.1.1.9"
	// oidLLDPRemManAddr = ".1.0.8802.1.1.2.1.4.2.1.3"
	oidLLDPRemManAddr = ".1.0.8802.1.1.2.1.4.2.1.3"

	// CDP OIDs (Cisco Discovery Protocol)
	// oidCDPCacheTable = ".1.3.6.1.4.1.9.9.23.1.2.1.1"
	oidCDPCacheTable = ".1.3.6.1.4.1.9.9.23.1.2.1.1"
	// oidCdpCacheDeviceId   = ".1.3.6.1.4.1.9.9.23.1.2.1.1.6"
	// oidCdpCacheDevicePort = ".1.3.6.1.4.1.9.9.23.1.2.1.1.7"
	// oidCdpCacheAddress    = ".1.3.6.1.4.1.9.9.23.1.2.1.1.4"

	// Default concurrency settings
	defaultConcurrency = 10
	defaultMaxIPRange  = 256 // Maximum IPs to process from a CIDR range
)

// handleEmptyTargetList updates job status when no valid targets are found
func (*SNMPDiscoveryEngine) handleEmptyTargetList(job *DiscoveryJob) {
	job.mu.Lock()
	job.Status.Status = DiscoveryStatusFailed
	job.Status.Error = "No valid targets to scan after processing seeds"
	job.Status.Progress = 100
	job.mu.Unlock()

	log.Printf("Job %s: Failed - no valid targets to scan", job.ID)
}

// determineConcurrency calculates the appropriate concurrency level.
func (*SNMPDiscoveryEngine) determineConcurrency(job *DiscoveryJob, totalTargets int) int {
	concurrency := job.Params.Concurrency

	if concurrency <= 0 {
		concurrency = defaultConcurrency
	}

	if concurrency > totalTargets {
		concurrency = totalTargets // Don't create more workers than needed
	}

	return concurrency
}

// startWorkers launches worker goroutines to process targets.
func (e *SNMPDiscoveryEngine) startWorkers(
	job *DiscoveryJob, wg *sync.WaitGroup, targetChan <-chan string, resultChan chan<- bool, concurrency int) {
	for i := 0; i < concurrency; i++ {
		wg.Add(1)

		go func(workerID int) {
			defer wg.Done()

			for target := range targetChan {
				// Check for cancellation before processing each target
				select {
				case <-job.ctx.Done():
					log.Printf("Job %s: Worker %d stopping due to cancellation", job.ID, workerID)
					return
				case <-e.done:
					log.Printf("Job %s: Worker %d stopping due to engine shutdown", job.ID, workerID)
					return
				default:
					// Process target
					if pingErr := pingHost(job.ctx, target); pingErr != nil {
						log.Printf("Job %s: Host %s is not responding to ICMP ping: %v", job.ID, target, pingErr)
						return
					}

					e.scanTarget(job, target, job.Params.AgentID, job.Params.PollerID)

					resultChan <- true // Signal completion for progress tracking
				}
			}
		}(i)
	}
}

// startProgressTracking starts a goroutine to track job progress
func (e *SNMPDiscoveryEngine) startProgressTracking(job *DiscoveryJob, resultChan <-chan bool, totalTargets int) {
	go func() {
		processed := 0

		for range resultChan {
			processed++
			// Update progress
			job.mu.Lock()
			progress := float64(processed)/float64(totalTargets)*90.0 + 5.0 // 5% at start, 5% at end

			job.Status.Progress = progress
			job.Status.DevicesFound = len(job.Results.Devices)
			job.Status.InterfacesFound = len(job.Results.Interfaces)
			job.Status.TopologyLinks = len(job.Results.TopologyLinks)

			log.Printf("Job %s: Progress %.2f%%, Devices: %d, Interfaces: %d, Links: %d",
				job.ID, job.Status.Progress, job.Status.DevicesFound,
				job.Status.InterfacesFound, job.Status.TopologyLinks)
			job.mu.Unlock()

			// Check for cancellation
			select {
			case <-job.ctx.Done():
				log.Printf("Job %s: Progress tracking stopping due to cancellation", job.ID)
				return
			case <-e.done:
				log.Printf("Job %s: Progress tracking stopping due to engine shutdown", job.ID)
				return
			default:
			}
		}
	}()
}

// initializeJobProgress sets the initial progress value
func (*SNMPDiscoveryEngine) initializeJobProgress(job *DiscoveryJob) {
	job.mu.Lock()
	job.Status.Progress = 5 // Initial progress
	job.mu.Unlock()

	log.Printf("Job %s: Scan queue: %v", job.ID, job.scanQueue)
}

// feedTargetsToWorkers sends targets to worker goroutines
// Returns true if job was canceled during feeding
func (e *SNMPDiscoveryEngine) feedTargetsToWorkers(job *DiscoveryJob, targetChan chan<- string) bool {
	for _, target := range job.scanQueue {
		select {
		case targetChan <- target:
			// Target sent to worker
		case <-job.ctx.Done():
			log.Printf("Job %s: Stopping target feed due to cancellation", job.ID)
			close(targetChan)

			return true
		case <-e.done:
			log.Printf("Job %s: Stopping target feed due to engine shutdown", job.ID)
			close(targetChan)

			return true
		}
	}

	close(targetChan)

	return false
}

// checkJobCancellation checks if the job was canceled or the engine is shutting down
// Returns true if the job was canceled
func (e *SNMPDiscoveryEngine) checkJobCancellation(job *DiscoveryJob) bool {
	select {
	case <-job.ctx.Done():
		job.mu.Lock()
		job.Status.Status = DiscoverStatusCanceled
		job.Status.Error = "Job canceled during execution"
		job.mu.Unlock()

		log.Printf("Job %s: Canceled during execution", job.ID)

		return true
	case <-e.done:
		job.mu.Lock()
		job.Status.Status = DiscoveryStatusFailed
		job.Status.Error = "Engine shutting down"
		job.mu.Unlock()

		log.Printf("Job %s: Failed due to engine shutdown", job.ID)

		return true
	default:
		// Job completed successfully
		return false
	}
}

// finalizeJobStatus updates the job status after completion
func (*SNMPDiscoveryEngine) finalizeJobStatus(job *DiscoveryJob) {
	job.mu.Lock()
	if job.Status.Status == DiscoveryStatusRunning {
		job.Status.Status = DiscoveryStatusCompleted
		job.Status.Progress = 100

		if len(job.Results.Devices) == 0 {
			job.Status.Error = "No SNMP devices found"
			log.Printf("Job %s: Completed - no SNMP devices found", job.ID)
		} else {
			log.Printf("Job %s: Completed successfully. Found %d devices, %d interfaces, %d topology links",
				job.ID, len(job.Results.Devices), len(job.Results.Interfaces), len(job.Results.TopologyLinks))
		}
	}
	job.mu.Unlock()
}

const (
	defaultConcurrencyMultiplier = 2 // Multiplier for target channel size
)

// runDiscoveryJob performs the actual SNMP discovery for a job
func (e *SNMPDiscoveryEngine) runDiscoveryJob(job *DiscoveryJob) {
	log.Printf("Running discovery for job %s. Seeds: %v, Type: %s", job.ID, job.Params.Seeds, job.Params.Type)

	// Process seeds into target IPs
	job.scanQueue = expandSeeds(job.Params.Seeds)

	totalTargets := len(job.scanQueue)

	if totalTargets == 0 {
		e.handleEmptyTargetList(job)

		return
	}

	log.Printf("Job %s: Expanded seeds to %d target IPs", job.ID, totalTargets)

	// Set up concurrency
	concurrency := e.determineConcurrency(job, totalTargets)

	// Create channels for worker pool
	var wg sync.WaitGroup

	targetChan := make(chan string, concurrency*defaultConcurrencyMultiplier)
	resultChan := make(chan bool, concurrency) // For progress tracking

	// Start worker goroutines
	e.startWorkers(job, &wg, targetChan, resultChan, concurrency)

	// Start progress tracking goroutine
	e.startProgressTracking(job, resultChan, totalTargets)

	// Feed targets to workers
	e.initializeJobProgress(job)

	if e.feedTargetsToWorkers(job, targetChan) {
		return // Job was canceled during target feeding
	}

	// Wait for all workers to finish
	wg.Wait()

	close(resultChan)

	// Check for cancellation
	if e.checkJobCancellation(job) {
		return
	}

	// Final job status update
	e.finalizeJobStatus(job)
}

// expandSeeds expands CIDR ranges and individual IPs into a list of IPs
func expandSeeds(seeds []string) []string {
	var targets []string

	seen := make(map[string]bool) // To avoid duplicates

	for _, seed := range seeds {
		// Check if the seed is a CIDR notation
		if strings.Contains(seed, "/") {
			cidrTargets := expandCIDR(seed, seen)
			targets = append(targets, cidrTargets...)
		} else {
			// It's a single IP
			if ipTarget := processSingleIP(seed, seen); ipTarget != "" {
				targets = append(targets, ipTarget)
			}
		}
	}

	return targets
}

const (
	// 31 - broadcast
	defaultBroadCastMask = 31
	defaultCountCheckMin = 2
)

// expandCIDR expands a CIDR notation into individual IP addresses
func expandCIDR(cidr string, seen map[string]bool) []string {
	var targets []string

	ip, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		log.Printf("Invalid CIDR %s: %v", cidr, err)
		return targets
	}

	// Check if range is too large
	ones, bits := ipNet.Mask.Size()
	hostBits := bits - ones

	// Collect IPs based on range size
	targets = collectIPsFromRange(ip, ipNet, hostBits, seen)

	// Filter out network and broadcast addresses if needed
	if ip.To4() != nil && ones < defaultBroadCastMask && len(targets) > defaultCountCheckMin {
		targets = filterNetworkAndBroadcast(targets, ip, ipNet)
	}

	return targets
}

const (
	defaultHostBitsCheckMin = 8
)

// collectIPsFromRange collects IPs from a CIDR range, limiting if necessary
func collectIPsFromRange(ip net.IP, ipNet *net.IPNet, hostBits int, seen map[string]bool) []string {
	var targets []string

	if hostBits > defaultHostBitsCheckMin { // More than 256 hosts
		log.Printf("CIDR range %s too large (/%d), limiting scan", ipNet.String(), hostBits)

		// Only scan first 256 IPs
		count := 0
		ipCopy := make(net.IP, len(ip))

		copy(ipCopy, ip)

		for i := ipCopy.Mask(ipNet.Mask); ipNet.Contains(ip) && count < defaultMaxIPRange; incrementIP(ip) {
			// changed from ip to i, to avoid modifying the original IP
			ipStr := i.String()

			if !seen[ipStr] {
				targets = append(targets, ipStr)
				seen[ipStr] = true
				count++
			}
		}
	} else {
		// Process all IPs in the range
		ipCopy := make(net.IP, len(ip))
		copy(ipCopy, ip)

		for ip := ipCopy.Mask(ipNet.Mask); ipNet.Contains(ip); incrementIP(ip) {
			ipStr := ip.String()

			if !seen[ipStr] {
				targets = append(targets, ipStr)
				seen[ipStr] = true
			}
		}
	}

	return targets
}

// filterNetworkAndBroadcast removes network and broadcast addresses from the targets
func filterNetworkAndBroadcast(targets []string, ip net.IP, ipNet *net.IPNet) []string {
	// Skip first and last IP if they exist in the targets
	networkIP := ip.Mask(ipNet.Mask).String()

	// Calculate broadcast IP
	broadcastIP := make(net.IP, len(ip))
	copy(broadcastIP, ip.Mask(ipNet.Mask))

	for i := range broadcastIP {
		broadcastIP[i] |= ^ipNet.Mask[i]
	}

	broadcastIPStr := broadcastIP.String()

	// Create a new slice without network and broadcast IPs
	filteredTargets := make([]string, 0, len(targets))

	for _, target := range targets {
		if target != networkIP && target != broadcastIPStr {
			filteredTargets = append(filteredTargets, target)
		}
	}

	return filteredTargets
}

// processSingleIP processes a single IP address
func processSingleIP(ipStr string, seen map[string]bool) string {
	ip := net.ParseIP(ipStr)

	if ip == nil {
		log.Printf("Invalid IP %s", ipStr)
		return ""
	}

	ipStr = ip.String()

	if !seen[ipStr] {
		seen[ipStr] = true
		return ipStr
	}

	return ""
}

// incrementIP increments an IP address by 1
func incrementIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++

		if ip[j] > 0 {
			break
		}
	}
}

// checkAndMarkDiscovered checks if a target is already discovered and marks it as discovered
// Returns true if the target should be processed (not already discovered)
func (*SNMPDiscoveryEngine) checkAndMarkDiscovered(job *DiscoveryJob, target string) bool {
	job.mu.Lock()
	defer job.mu.Unlock()

	if job.discoveredIPs[target] {
		log.Printf("Job %s: Skipping already discovered target %s", job.ID, target)
		return false
	}

	job.discoveredIPs[target] = true

	return true
}

// publishDevice adds a device to results and publishes it if a publisher is available
func (e *SNMPDiscoveryEngine) publishDevice(job *DiscoveryJob, device *DiscoveredDevice) {
	// Add device to results
	job.mu.Lock()
	job.Results.Devices = append(job.Results.Devices, device)
	job.mu.Unlock()

	// Publish device
	if e.publisher != nil {
		if err := e.publisher.PublishDevice(job.ctx, device); err != nil {
			log.Printf("Job %s: Failed to publish device %s: %v", job.ID, device.IP, err)
		}
	}
}

// handleInterfaceDiscovery queries and publishes interface information
func (e *SNMPDiscoveryEngine) handleInterfaceDiscovery(
	job *DiscoveryJob, client *gosnmp.GoSNMP, target, agentID, pollerID string) {
	interfaces, err := e.queryInterfaces(client, target, job.ID, agentID, pollerID)
	if err != nil {
		log.Printf("Job %s: Failed to query interfaces for %s: %v", job.ID, target, err)
		return
	}

	if len(interfaces) == 0 {
		return
	}

	// Add interfaces to results
	job.mu.Lock()
	job.Results.Interfaces = append(job.Results.Interfaces, interfaces...)
	job.mu.Unlock()

	// Publish interfaces
	if e.publisher != nil {
		for _, iface := range interfaces {
			if err := e.publisher.PublishInterface(job.ctx, iface); err != nil {
				log.Printf("Job %s: Failed to publish interface %s/%d: %v",
					job.ID, target, iface.IfIndex, err)
			}
		}
	}
}

// publishTopologyLinks adds topology links to results and publishes them
func (e *SNMPDiscoveryEngine) publishTopologyLinks(job *DiscoveryJob, links []*TopologyLink, target, protocol string) {
	if len(links) == 0 {
		return
	}

	job.mu.Lock()
	job.Results.TopologyLinks = append(job.Results.TopologyLinks, links...)
	job.mu.Unlock()

	// Publish links
	if e.publisher != nil {
		for _, link := range links {
			if err := e.publisher.PublishTopologyLink(job.ctx, link); err != nil {
				log.Printf("Job %s: Failed to publish %s link %s/%d: %v",
					job.ID, protocol, target, link.LocalIfIndex, err)
			}
		}
	}
}

// handleTopologyDiscovery queries and publishes topology information (LLDP or CDP)
func (e *SNMPDiscoveryEngine) handleTopologyDiscovery(
	job *DiscoveryJob, client *gosnmp.GoSNMP, targetIP, agentID, pollerID string) {
	// Try LLDP first
	lldpLinks, lldpErr := e.queryLLDP(client, targetIP, agentID, pollerID, job.ID)
	if lldpErr == nil && len(lldpLinks) > 0 {
		e.publishTopologyLinks(job, lldpLinks, targetIP, "LLDP")
		return
	}

	log.Printf("Job %s: LLDP not supported or no neighbors on %s: %v", job.ID, targetIP, lldpErr)

	// Try CDP if LLDP failed
	cdpLinks, cdpErr := e.queryCDP(client, targetIP, agentID, pollerID, job.ID)
	if cdpErr == nil && len(cdpLinks) > 0 {
		e.publishTopologyLinks(job, cdpLinks, targetIP, "CDP")
		return
	}

	log.Printf("Job %s: CDP not supported or no neighbors on %s: %v", job.ID, targetIP, cdpErr)
}

// setupSNMPClient creates and configures an SNMP client
func (e *SNMPDiscoveryEngine) setupSNMPClient(job *DiscoveryJob, target string) (*gosnmp.GoSNMP, error) {
	// Create SNMP client
	client, err := e.createSNMPClient(target, job.Params.Credentials)
	if err != nil {
		return nil, err
	}

	// Override timeout and retries if specified in job params
	if job.Params.Timeout > 0 {
		client.Timeout = job.Params.Timeout
	}

	if job.Params.Retries > 0 {
		client.Retries = job.Params.Retries
	}

	// Connect to target
	if err := client.Connect(); err != nil {
		return nil, err
	}

	return client, nil
}

// scanTarget performs SNMP scanning of a single target IP
func (e *SNMPDiscoveryEngine) scanTarget(job *DiscoveryJob, targetIP, agentID, pollerID string) {
	log.Printf("Job %s: Scanning target %s", job.ID, targetIP)

	// Skip if already discovered (concurrency check)
	if !e.checkAndMarkDiscovered(job, targetIP) {
		return
	}

	// Create and connect SNMP client
	client, err := e.setupSNMPClient(job, targetIP)
	if err != nil {
		log.Printf("Job %s: Failed to setup SNMP client for %s: %v", job.ID, targetIP, err)
		return
	}
	defer func(Conn net.Conn) {
		err = Conn.Close()
		if err != nil {
			log.Printf("Job %s: Failed to close SNMP connection: %v", job.ID, err)
		}
	}(client.Conn)

	// Query system information
	device, err := e.querySysInfo(client, targetIP, job.ID)
	if err != nil {
		log.Printf("Job %s: Failed to query system info for %s: %v", job.ID, targetIP, err)
		return
	}

	// Add device to results and publish
	e.publishDevice(job, device)

	// Query interfaces if needed
	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeInterfaces {
		e.handleInterfaceDiscovery(job, client, targetIP, agentID, pollerID)
	}

	// Query topology if needed
	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeTopology {
		e.handleTopologyDiscovery(job, client, targetIP, agentID, pollerID)
	}
}

// initializeDevice creates and initializes a new DiscoveredDevice
func (*SNMPDiscoveryEngine) initializeDevice(target string) *DiscoveredDevice {
	return &DiscoveredDevice{
		IP:        target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
		Metadata:  make(map[string]string),
	}
}

// processSnmpVariables processes SNMP variables and populates the device object
func (e *SNMPDiscoveryEngine) processSnmpVariables(device *DiscoveredDevice, variables []gosnmp.SnmpPDU) bool {
	foundSomething := false

	for _, v := range variables {
		// Skip NoSuchObject/NoSuchInstance
		if v.Type == gosnmp.NoSuchObject || v.Type == gosnmp.NoSuchInstance {
			continue
		}

		foundSomething = true

		e.processSnmpVariable(device, v)
	}

	return foundSomething
}

// processSnmpVariable processes a single SNMP variable and updates the device
func (e *SNMPDiscoveryEngine) processSnmpVariable(device *DiscoveredDevice, v gosnmp.SnmpPDU) {
	switch v.Name {
	case oidSysDescr:
		e.setStringValue(&device.SysDescr, v)
	case oidSysObjectID:
		e.setObjectIDValue(&device.SysObjectID, v)
	case oidSysUptime:
		e.setUptimeValue(&device.Uptime, v)
	case oidSysContact:
		e.setStringValue(&device.SysContact, v)
	case oidSysName:
		e.setStringValue(&device.Hostname, v)
	case oidSysLocation:
		e.setStringValue(&device.SysLocation, v)
	}
}

// setStringValue sets a string value from an SNMP PDU if it's the correct type
func (*SNMPDiscoveryEngine) setStringValue(target *string, v gosnmp.SnmpPDU) {
	if v.Type == gosnmp.OctetString {
		*target = string(v.Value.([]byte))
	}
}

// setObjectIDValue sets an object ID value from an SNMP PDU if it's the correct type
func (*SNMPDiscoveryEngine) setObjectIDValue(target *string, v gosnmp.SnmpPDU) {
	if v.Type == gosnmp.ObjectIdentifier {
		*target = v.Value.(string)
	}
}

// setUptimeValue sets an uptime value from an SNMP PDU if it's the correct type
func (*SNMPDiscoveryEngine) setUptimeValue(target *int64, v gosnmp.SnmpPDU) {
	if v.Type == gosnmp.TimeTicks {
		*target = int64(v.Value.(uint32))
	}
}

// finalizeDevice performs final setup on the device before returning it
func (*SNMPDiscoveryEngine) finalizeDevice(device *DiscoveredDevice, target, jobID string) {
	// Use IP as hostname if not provided
	if device.Hostname == "" {
		device.Hostname = target
	}

	// Add job metadata
	device.Metadata["discovery_id"] = jobID
	device.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
}

// querySysInfo queries basic system information via SNMP
func (e *SNMPDiscoveryEngine) querySysInfo(client *gosnmp.GoSNMP, target, jobID string) (*DiscoveredDevice, error) {
	// System OIDs to query
	oids := []string{
		oidSysDescr,
		oidSysObjectID,
		oidSysUptime,
		oidSysContact,
		oidSysName,
		oidSysLocation,
	}

	// Perform SNMP Get
	result, err := client.Get(oids)
	if err != nil {
		return nil, fmt.Errorf("%w %w", ErrSNMPGetFailed, err)
	}

	if result.Error != gosnmp.NoError {
		return nil, fmt.Errorf("%w %s", ErrSNMPError, result.Error)
	}

	// Create and initialize device
	device := e.initializeDevice(target)

	// Process SNMP variables
	foundSomething := e.processSnmpVariables(device, result.Variables)
	if !foundSomething {
		return nil, ErrNoSNMPDataReturned
	}

	// Finalize device setup
	e.finalizeDevice(device, target, jobID)

	return device, nil
}

// queryInterfaces queries interface information via SNMP
func (e *SNMPDiscoveryEngine) queryInterfaces(
	client *gosnmp.GoSNMP, target, jobID, agentID, pollerID string) ([]*DiscoveredInterface, error) {
	// Map to store interfaces by index
	ifMap := make(map[int]*DiscoveredInterface)

	// Walk ifTable to get basic interface information
	if err := e.walkIfTable(client, target, ifMap); err != nil {
		return nil, err
	}

	// Try to get additional interface info from ifXTable (if available)
	if err := e.walkIfXTable(client, ifMap); err != nil {
		return nil, err
	}

	// Get IP addresses from ipAddrTable
	ipToIfIndex, err := e.walkIPAddrTable(client)
	if err != nil {
		return nil, err
	}

	// Associate IPs with interfaces
	e.associateIPsWithInterfaces(ipToIfIndex, ifMap)

	// Convert map to slice and finalize interfaces
	return e.finalizeInterfaces(ifMap, jobID, agentID, pollerID), nil
}

const (
	defaultPartsLengthCheck = 2
)

// processIfTablePDU processes a single PDU from the ifTable walk
func (e *SNMPDiscoveryEngine) processIfTablePDU(pdu gosnmp.SnmpPDU, target string, ifMap map[int]*DiscoveredInterface) error {
	// Extract ifIndex from OID
	parts := strings.Split(pdu.Name, ".")
	if len(parts) < defaultPartsLengthCheck {
		return nil
	}

	ifIndex, err := strconv.Atoi(parts[len(parts)-1])
	if err != nil {
		return nil
	}

	// Create interface if it doesn't exist
	if _, exists := ifMap[ifIndex]; !exists {
		ifMap[ifIndex] = &DiscoveredInterface{
			DeviceIP:    target,
			IfIndex:     ifIndex,
			IPAddresses: []string{},
			Metadata:    make(map[string]string),
		}
	}

	iface := ifMap[ifIndex]

	// Parse specific OID
	oidPrefix := strings.Join(parts[:len(parts)-1], ".")
	e.updateInterfaceFromOID(iface, "."+oidPrefix, pdu)

	return nil
}

// updateIfDescr updates the interface description
func updateIfDescr(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		iface.IfDescr = string(pdu.Value.([]byte))
	}
}

// updateIfType updates the interface type
func updateIfType(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.Integer {
		iface.IfType = pdu.Value.(int)
	}
}

const (
	defaultMaxInt64 = 9223372036854775807
)

// updateIfSpeed updates the interface speed
func updateIfSpeed(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	//nolint:exhaustive // Default case handles all unlisted types
	switch pdu.Type {
	case gosnmp.Gauge32:
		uintVal := pdu.Value.(uint)
		if uintVal > uint(defaultMaxInt64) { // max int64 value
			iface.IfSpeed = defaultMaxInt64 // math.MaxInt64
		} else {
			iface.IfSpeed = int64(uintVal)
		}
	case gosnmp.Counter32, gosnmp.Counter64:
		iface.IfSpeed = gosnmp.ToBigInt(pdu.Value).Int64()
	case gosnmp.Integer:
		// For Integer type, convert to int64
		if val, ok := pdu.Value.(int); ok {
			iface.IfSpeed = int64(val)
		}
	case gosnmp.Uinteger32:
		// For Uinteger32, convert to int64
		if val, ok := pdu.Value.(uint32); ok {
			iface.IfSpeed = int64(val)
		}
	default:
	}
}

// updateIfPhysAddress updates the interface physical address
func updateIfPhysAddress(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		iface.IfPhysAddress = formatMACAddress(pdu.Value.([]byte))
	}
}

// updateIfAdminStatus updates the interface admin status
func updateIfAdminStatus(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.Integer {
		iface.IfAdminStatus = pdu.Value.(int)
	}
}

// updateIfOperStatus updates the interface operational status
func updateIfOperStatus(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.Integer {
		iface.IfOperStatus = pdu.Value.(int)
	}
}

// updateInterfaceFromOID updates interface properties based on the OID and PDU
func (*SNMPDiscoveryEngine) updateInterfaceFromOID(iface *DiscoveredInterface, oidPrefix string, pdu gosnmp.SnmpPDU) {
	switch oidPrefix {
	case oidIfDescr:
		updateIfDescr(iface, pdu)
	case oidIfType:
		updateIfType(iface, pdu)
	case oidIfSpeed:
		updateIfSpeed(iface, pdu)
	case oidIfPhysAddress:
		updateIfPhysAddress(iface, pdu)
	case oidIfAdminStatus:
		updateIfAdminStatus(iface, pdu)
	case oidIfOperStatus:
		updateIfOperStatus(iface, pdu)
	}
}

// walkIfTable walks the ifTable to get basic interface information
func (e *SNMPDiscoveryEngine) walkIfTable(client *gosnmp.GoSNMP, target string, ifMap map[int]*DiscoveredInterface) error {
	err := client.BulkWalk(oidIfTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processIfTablePDU(pdu, target, ifMap)
	})

	if err != nil {
		return fmt.Errorf("failed to walk ifTable: %w", err)
	}

	return nil
}

const (
	defaultPartsLenCheck = 2
)

// processIfXTablePDU processes a single PDU from the ifXTable walk
func (e *SNMPDiscoveryEngine) processIfXTablePDU(pdu gosnmp.SnmpPDU, ifMap map[int]*DiscoveredInterface) error {
	parts := strings.Split(pdu.Name, ".")
	if len(parts) < defaultPartsLenCheck {
		return nil
	}

	ifIndex, err := strconv.Atoi(parts[len(parts)-1])
	if err != nil {
		return nil
	}

	iface, exists := ifMap[ifIndex]
	if !exists {
		return nil
	}

	oidPrefix := strings.Join(parts[:len(parts)-1], ".")
	e.updateInterfaceFromPDU(iface, "."+oidPrefix, pdu)

	return nil
}

const (
	overflowValue    = 9223372036854775807
	defaultHighSpeed = 1000000
	defaultOverflow  = 1000000
)

// updateInterfaceFromPDU updates interface properties based on the OID prefix and PDU value
func (*SNMPDiscoveryEngine) updateInterfaceFromPDU(iface *DiscoveredInterface, oidWithPrefix string, pdu gosnmp.SnmpPDU) {
	switch oidWithPrefix {
	case oidIfName:
		if pdu.Type == gosnmp.OctetString {
			iface.IfName = string(pdu.Value.([]byte))
		}
	case oidIfAlias:
		if pdu.Type == gosnmp.OctetString {
			iface.IfAlias = string(pdu.Value.([]byte))
		}
	case oidIfHighSpeed:
		if pdu.Type == gosnmp.Gauge32 {
			// IfHighSpeed is in Mbps, convert to bps
			uintVal := pdu.Value.(uint)

			var highSpeed int64

			if uintVal > uint(overflowValue/defaultOverflow) { // Prevent overflow when multiplying
				highSpeed = overflowValue // math.MaxInt64
			} else {
				highSpeed = int64(uintVal) * defaultHighSpeed
			}

			if highSpeed > iface.IfSpeed {
				iface.IfSpeed = highSpeed
			}
		}
	}
}

// walkIfXTable walks the ifXTable to get additional interface information
func (e *SNMPDiscoveryEngine) walkIfXTable(client *gosnmp.GoSNMP, ifMap map[int]*DiscoveredInterface) error {
	err := client.BulkWalk(oidIfXTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processIfXTablePDU(pdu, ifMap)
	})

	return err
}

const (
	defaultTooManyParts = 5
	ipv4Length          = 4
)

// extractIPFromOID extracts an IP address from the last 4 parts of an OID
func extractIPFromOID(oid string) (string, bool) {
	parts := strings.Split(oid, ".")
	if len(parts) >= defaultTooManyParts {
		// Last 4 parts of OID are the IP address
		return strings.Join(parts[len(parts)-ipv4Length:], "."), true
	}

	return "", false
}

// handleIPAdEntIfIndex processes an ipAdEntIfIndex PDU and updates the IP to ifIndex mapping
func handleIPAdEntIfIndex(pdu gosnmp.SnmpPDU, ipToIfIndex map[string]int) {
	if pdu.Type == gosnmp.Integer {
		ifIndex := pdu.Value.(int)

		// Extract IP from OID (.1.3.6.1.2.1.4.20.1.2.X.X.X.X)
		if ip, ok := extractIPFromOID(pdu.Name); ok {
			ipToIfIndex[ip] = ifIndex
		}
	}
}

const (
	defaultIPBytesLength = 4
)

// handleIPAdEntAddr processes an ipAdEntAddr PDU and updates the IP to ifIndex mapping
func handleIPAdEntAddr(pdu gosnmp.SnmpPDU, ipToIfIndex map[string]int) {
	var ipString string

	//nolint:exhaustive // Default case handles all unlisted types
	switch pdu.Type {
	case gosnmp.IPAddress:
		ipString = pdu.Value.(string)
	case gosnmp.OctetString:
		// Some devices return IP as octet string
		ipBytes := pdu.Value.([]byte)
		if len(ipBytes) == defaultIPBytesLength {
			ipString = fmt.Sprintf("%d.%d.%d.%d", ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3])
		}
	default:
	}

	// If we got an IP, extract the IP from the OID too (for matching)
	if ipString != "" {
		if ip, ok := extractIPFromOID(pdu.Name); ok {
			ipToIfIndex[ip] = 0 // Placeholder, will be filled by ipAdEntIfIndex
		}
	}
}

// walkIPAddrTable walks the ipAddrTable to get IP address information
func (*SNMPDiscoveryEngine) walkIPAddrTable(client *gosnmp.GoSNMP) (map[string]int, error) {
	ipToIfIndex := make(map[string]int)

	err := client.BulkWalk(oidIPAddrTable, func(pdu gosnmp.SnmpPDU) error {
		// Handle ipAdEntIfIndex to get the mapping of IP to ifIndex
		if strings.HasPrefix(pdu.Name, oidIPAdEntIfIndex) {
			handleIPAdEntIfIndex(pdu, ipToIfIndex)
		}

		// Now get the actual IP addresses
		if strings.HasPrefix(pdu.Name, oidIPAdEntAddr) {
			handleIPAdEntAddr(pdu, ipToIfIndex)
		}

		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk ipAddrTable: %w", err)
	}

	return ipToIfIndex, nil
}

// associateIPsWithInterfaces associates IP addresses with interfaces
func (*SNMPDiscoveryEngine) associateIPsWithInterfaces(ipToIfIndex map[string]int, ifMap map[int]*DiscoveredInterface) {
	for ip, ifIndex := range ipToIfIndex {
		if iface, exists := ifMap[ifIndex]; exists {
			// Check if we already have this IP
			found := false

			for _, existingIP := range iface.IPAddresses {
				if existingIP == ip {
					found = true
					break
				}
			}

			if !found {
				iface.IPAddresses = append(iface.IPAddresses, ip)
			}
		}
	}
}

// finalizeInterfaces finalizes the interfaces by ensuring they have names and adding metadata
func (*SNMPDiscoveryEngine) finalizeInterfaces(
	ifMap map[int]*DiscoveredInterface, jobID string, agentID string, pollerID string) []*DiscoveredInterface {
	interfaces := make([]*DiscoveredInterface, 0, len(ifMap))

	for _, iface := range ifMap {
		// Ensure interface has a name
		if iface.IfName == "" {
			if iface.IfDescr != "" {
				iface.IfName = iface.IfDescr
			} else {
				iface.IfName = fmt.Sprintf("Interface-%d", iface.IfIndex)
			}
		}

		// Populate DeviceID if not already set
		if iface.DeviceID == "" && iface.DeviceIP != "" && agentID != "" && pollerID != "" {
			iface.DeviceID = fmt.Sprintf("%s:%s:%s", iface.DeviceIP, agentID, pollerID)
		} else if iface.DeviceID == "" {
			log.Printf("Job %s: Could not generate DeviceID for interface on %s due to"+
				" missing components (agent: %s, poller: %s)", jobID, iface.DeviceIP, agentID, pollerID)
		}

		// Add metadata
		iface.Metadata["discovery_id"] = jobID
		iface.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)

		interfaces = append(interfaces, iface)
	}

	return interfaces
}

const (
	defaultLLDPPartsCount = 11
)

// processLLDPRemoteTableEntry processes a single LLDP remote table entry
func (e *SNMPDiscoveryEngine) processLLDPRemoteTableEntry(
	pdu gosnmp.SnmpPDU, linkMap map[string]*TopologyLink, targetIP, agentID, pollerID, jobID string) error {
	parts := strings.Split(pdu.Name, ".")
	if len(parts) < defaultLLDPPartsCount {
		return nil
	}

	// Extract timeMark.localPort.index from OID
	// Format: .1.0.8802.1.1.2.1.4.1.1.X.timeMark.localPort.index
	timeMark := parts[len(parts)-3]
	localPort := parts[len(parts)-2]
	index := parts[len(parts)-1]

	key := fmt.Sprintf("%s.%s.%s", timeMark, localPort, index)

	// Create topology link if not exists
	if _, exists := linkMap[key]; !exists {
		localDeviceID := ""
		if targetIP != "" && agentID != "" && pollerID != "" {
			localDeviceID = fmt.Sprintf("%s:%s:%s", targetIP, agentID, pollerID)
		} else if targetIP != "" {
			log.Printf("Warning: AgentID or PollerID missing for job %s when creating LocalDeviceID for target %s",
				jobID, targetIP)

			localDeviceID = targetIP
		}

		localPortIdx, _ := strconv.Atoi(localPort)
		linkMap[key] = &TopologyLink{
			Protocol:      "LLDP",
			LocalDeviceIP: targetIP,
			LocalDeviceID: localDeviceID,
			LocalIfIndex:  localPortIdx,
			Metadata:      make(map[string]string),
		}
	}

	link := linkMap[key]

	// Extract OID suffix for comparison
	oidSuffix := parts[len(parts)-4]

	// Process the PDU based on OID suffix
	e.processLLDPOIDSuffix(oidSuffix, pdu, link)

	return nil
}

// processLLDPOIDSuffix processes a PDU based on its OID suffix
func (*SNMPDiscoveryEngine) processLLDPOIDSuffix(oidSuffix string, pdu gosnmp.SnmpPDU, link *TopologyLink) {
	// Parse based on the OID suffix
	switch oidSuffix {
	case "5": // oidLldpRemChassisId
		if pdu.Type == gosnmp.OctetString {
			link.NeighborChassisID = formatLLDPID(pdu.Value.([]byte))
		}
	case "7": // oidLldpRemPortId
		if pdu.Type == gosnmp.OctetString {
			link.NeighborPortID = formatLLDPID(pdu.Value.([]byte))
		}
	case "8": // oidLldpRemPortDesc
		if pdu.Type == gosnmp.OctetString {
			link.NeighborPortDescr = string(pdu.Value.([]byte))
		}
	case "9": // oidLldpRemSysName
		if pdu.Type == gosnmp.OctetString {
			link.NeighborSystemName = string(pdu.Value.([]byte))
		}
	}
}

const (
	// 5
	defaultByteLengthCheck = 5
)

// processLLDPManagementAddress processes LLDP management address entries
func (*SNMPDiscoveryEngine) processLLDPManagementAddress(pdu gosnmp.SnmpPDU, linkMap map[string]*TopologyLink) error {
	if pdu.Type != gosnmp.OctetString {
		return nil
	}

	// Try to extract IP address from management address
	bytes := pdu.Value.([]byte)
	if len(bytes) >= defaultByteLengthCheck {
		// First byte is usually the address type (1=IPv4)
		if bytes[0] == 1 && len(bytes) >= 5 {
			ip := net.IPv4(bytes[1], bytes[2], bytes[3], bytes[4])

			// Try to match with existing links
			// This is approximate since LLDP MIB structure doesn't make a perfect match easy
			for _, link := range linkMap {
				if link.NeighborMgmtAddr == "" {
					link.NeighborMgmtAddr = ip.String()
					break
				}
			}
		}
	}

	return nil
}

// isValidLLDPLink checks if a link has at least one neighbor identifier
func (*SNMPDiscoveryEngine) isValidLLDPLink(link *TopologyLink) bool {
	return link.NeighborChassisID != "" || link.NeighborSystemName != "" || link.NeighborPortID != ""
}

// setLocalDeviceIDIfNeeded sets the LocalDeviceID if it's empty but has other required components
func (*SNMPDiscoveryEngine) setLocalDeviceIDIfNeeded(link *TopologyLink, agentID, pollerID, jobID string) {
	if link.LocalDeviceID == "" && link.LocalDeviceIP != "" && agentID != "" && pollerID != "" {
		link.LocalDeviceID = fmt.Sprintf("%s:%s:%s", link.LocalDeviceIP, agentID, pollerID)
	} else if link.LocalDeviceID == "" {
		log.Printf("Job %s: Could not generate LocalDeviceID for LLDP link on %s "+
			"due to missing components (agent: %s, poller: %s)", jobID, link.LocalDeviceIP, agentID, pollerID)
	}
}

// addLLDPMetadata adds metadata to a link
func (*SNMPDiscoveryEngine) addLLDPMetadata(link *TopologyLink, jobID string) {
	link.Metadata["discovery_id"] = jobID
	link.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
	link.Metadata["protocol"] = "LLDP"
}

// finalizeLLDPLinks validates and finalizes LLDP links
func (e *SNMPDiscoveryEngine) finalizeLLDPLinks(
	linkMap map[string]*TopologyLink, agentID, pollerID, jobID string) ([]*TopologyLink, error) {
	links := make([]*TopologyLink, 0, len(linkMap))

	for _, link := range linkMap {
		// Skip invalid links
		if !e.isValidLLDPLink(link) {
			continue
		}

		e.setLocalDeviceIDIfNeeded(link, agentID, pollerID, jobID)
		e.addLLDPMetadata(link, jobID)
		links = append(links, link)
	}

	if len(links) == 0 {
		return nil, ErrNoLLDPNeighborsFound
	}

	return links, nil
}

// queryLLDP queries LLDP topology information
func (e *SNMPDiscoveryEngine) queryLLDP(client *gosnmp.GoSNMP, targetIP, agentID, pollerID, jobID string) ([]*TopologyLink, error) {
	linkMap := make(map[string]*TopologyLink) // Key is "timeMark.localPort.index"

	// Walk LLDP remote table
	err := client.BulkWalk(oidLLDPRemTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processLLDPRemoteTableEntry(pdu, linkMap, targetIP, agentID, pollerID, jobID)
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk LLDP table: %w", err)
	}

	// Walk LLDP management address table for neighbor IPs
	err = client.BulkWalk(oidLLDPRemManAddr, func(pdu gosnmp.SnmpPDU) error {
		return e.processLLDPManagementAddress(pdu, linkMap)
	})
	if err != nil {
		return nil, err
	}

	return e.finalizeLLDPLinks(linkMap, agentID, pollerID, jobID)
}

const (
	defaultPartsCount = 12
)

// processCDPPDU processes a single CDP PDU and updates the link map
func (e *SNMPDiscoveryEngine) processCDPPDU(
	pdu gosnmp.SnmpPDU, linkMap map[string]*TopologyLink, targetIP, agentID, pollerID, jobID string) error {
	parts := strings.Split(pdu.Name, ".")

	if len(parts) < defaultPartsCount {
		return nil
	}

	// Extract ifIndex.index from OID
	// Format: .1.3.6.1.4.1.9.9.23.1.2.1.1.X.ifIndex.index
	ifIndex := parts[len(parts)-2]
	index := parts[len(parts)-1]
	key := fmt.Sprintf("%s.%s", ifIndex, index)

	// Create topology link if not exists
	e.ensureCDPLinkExists(linkMap, key, ifIndex, targetIP, agentID, pollerID, jobID)

	link := linkMap[key]

	// Extract OID suffix for comparison
	oidSuffix := parts[len(parts)-3]

	// Update link based on OID suffix
	e.updateCDPLinkFromPDU(link, oidSuffix, pdu)

	return nil
}

// ensureCDPLinkExists creates a new topology link if it doesn't exist in the map
func (e *SNMPDiscoveryEngine) ensureCDPLinkExists(
	linkMap map[string]*TopologyLink, key, ifIndex, targetIP, agentID, pollerID, jobID string) {
	if _, exists := linkMap[key]; !exists {
		localDeviceID := e.createLocalDeviceID(targetIP, agentID, pollerID, jobID)
		ifIdx, _ := strconv.Atoi(ifIndex)

		linkMap[key] = &TopologyLink{
			Protocol:      "CDP",
			LocalDeviceIP: targetIP,
			LocalDeviceID: localDeviceID,
			LocalIfIndex:  ifIdx,
			Metadata:      make(map[string]string),
		}
	}
}

// createLocalDeviceID creates a local device ID based on available parameters
func (*SNMPDiscoveryEngine) createLocalDeviceID(targetIP, agentID, pollerID, jobID string) string {
	if targetIP != "" && agentID != "" && pollerID != "" {
		return fmt.Sprintf("%s:%s:%s", targetIP, agentID, pollerID)
	} else if targetIP != "" {
		log.Printf("Warning: AgentID or PollerID missing for job %s when creating LocalDeviceID for CDP target %s", jobID, targetIP)
		return targetIP
	}

	return ""
}

// updateCDPLinkFromPDU updates a topology link based on the OID suffix and PDU value
func (e *SNMPDiscoveryEngine) updateCDPLinkFromPDU(link *TopologyLink, oidSuffix string, pdu gosnmp.SnmpPDU) {
	switch oidSuffix {
	case "6": // oidCdpCacheDeviceId
		e.updateCDPDeviceID(link, pdu)
	case "7": // oidCdpCacheDevicePort
		e.updateCDPDevicePort(link, pdu)
	case "4": // oidCdpCacheAddress
		e.updateCDPDeviceAddress(link, pdu)
	}
}

// updateCDPDeviceID updates the neighbor system name and chassis ID
func (*SNMPDiscoveryEngine) updateCDPDeviceID(link *TopologyLink, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		link.NeighborSystemName = string(pdu.Value.([]byte))
		// Use as chassis ID if not set
		if link.NeighborChassisID == "" {
			link.NeighborChassisID = link.NeighborSystemName
		}
	}
}

// updateCDPDevicePort updates the neighbor port ID and description
func (*SNMPDiscoveryEngine) updateCDPDevicePort(link *TopologyLink, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		port := string(pdu.Value.([]byte))
		link.NeighborPortID = port
		link.NeighborPortDescr = port
	}
}

// updateCDPDeviceAddress updates the neighbor management address
func (e *SNMPDiscoveryEngine) updateCDPDeviceAddress(link *TopologyLink, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		bytes := pdu.Value.([]byte)
		link.NeighborMgmtAddr = e.extractCDPIPAddress(bytes)
	}
}

// extractCDPIPAddress extracts an IP address from CDP address bytes
func (*SNMPDiscoveryEngine) extractCDPIPAddress(bytes []byte) string {
	// CDP address format varies, try to extract IP
	if len(bytes) >= defaultByteLength { // CDP often has header bytes before the actual IP
		// Try to extract IPv4 address
		// Typical format: type(1) + len(4) + addr(4)
		if bytes[0] == 1 && len(bytes) >= defaultByteLength { // Type 1 = IP
			ip := net.IPv4(bytes[len(bytes)-4], bytes[len(bytes)-3],
				bytes[len(bytes)-2], bytes[len(bytes)-1])

			return ip.String()
		}
	}

	return ""
}

// finalizeCDPLinks converts the link map to a slice and adds metadata
func (*SNMPDiscoveryEngine) finalizeCDPLinks(linkMap map[string]*TopologyLink, jobID string) ([]*TopologyLink, error) {
	links := make([]*TopologyLink, 0, len(linkMap))

	for _, link := range linkMap {
		// Basic validation - need at least one neighbor identifier
		if link.NeighborSystemName == "" && link.NeighborPortID == "" {
			continue
		}

		// Add metadata
		link.Metadata["discovery_id"] = jobID
		link.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
		link.Metadata["protocol"] = "CDP"

		links = append(links, link)
	}

	if len(links) == 0 {
		return nil, ErrNoCDPNeighborsFound
	}

	return links, nil
}

// queryCDP queries CDP (Cisco Discovery Protocol) topology information
func (e *SNMPDiscoveryEngine) queryCDP(client *gosnmp.GoSNMP, targetIP, agentID, pollerID, jobID string) ([]*TopologyLink, error) {
	linkMap := make(map[string]*TopologyLink) // Key is "ifIndex.index"

	// Walk CDP cache table
	err := client.BulkWalk(oidCDPCacheTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processCDPPDU(pdu, linkMap, targetIP, agentID, pollerID, jobID)
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk CDP table: %w", err)
	}

	return e.finalizeCDPLinks(linkMap, jobID)
}

// formatMACAddress formats a byte array as a MAC address string
func formatMACAddress(mac []byte) string {
	if len(mac) != defaultByteLength {
		return ""
	}

	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
		mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
}

const (
	defaultByteLength = 6
)

// formatLLDPID formats LLDP identifiers which may be MAC addresses or other formats
func formatLLDPID(bytes []byte) string {
	// Check if it looks like a MAC address (common for chassis ID)
	if len(bytes) == defaultByteLength {
		return formatMACAddress(bytes)
	}

	// If it's a printable string, return as is
	return string(bytes)
}

const (
	defaultTimeoutDuration   = 2 * time.Second
	defaultRateLimit         = 100
	defaultRateLimitDuration = 1 * time.Second
)

func pingHost(ctx context.Context, host string) error {
	// Use the existing ICMPSweeper from your scan package
	sweeper, err := scan.NewICMPSweeper(defaultRateLimitDuration, defaultRateLimit)
	if err != nil {
		return err
	}
	defer func(sweeper *scan.ICMPSweeper, ctx context.Context) {
		err = sweeper.Stop(ctx)
		if err != nil {
			log.Printf("Error stopping sweeper: %v", err)
		}
	}(sweeper, ctx)

	ctx, cancel := context.WithTimeout(ctx, defaultTimeoutDuration)
	defer cancel()

	targets := []models.Target{
		{Host: host, Mode: models.ModeICMP},
	}

	resultCh, err := sweeper.Scan(ctx, targets)
	if err != nil {
		return err
	}

	hostReachable := false

	for result := range resultCh {
		if !result.Available {
			// Don't return immediately, continue processing the channel
			continue
		}

		// Mark that we found at least one successful ping
		hostReachable = true
	}

	if hostReachable {
		return nil
	}

	return ErrNoICMPResponse
}
