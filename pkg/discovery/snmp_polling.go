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
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

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
	oidIfTable       = ".1.3.6.1.2.1.2.2.1"
	oidIfIndex       = ".1.3.6.1.2.1.2.2.1.1"
	oidIfDescr       = ".1.3.6.1.2.1.2.2.1.2"
	oidIfType        = ".1.3.6.1.2.1.2.2.1.3"
	oidIfMtu         = ".1.3.6.1.2.1.2.2.1.4"
	oidIfSpeed       = ".1.3.6.1.2.1.2.2.1.5"
	oidIfPhysAddress = ".1.3.6.1.2.1.2.2.1.6"
	oidIfAdminStatus = ".1.3.6.1.2.1.2.2.1.7"
	oidIfOperStatus  = ".1.3.6.1.2.1.2.2.1.8"

	// IP address table OIDs
	oidIpAddrTable    = ".1.3.6.1.2.1.4.20.1"
	oidIpAdEntAddr    = ".1.3.6.1.2.1.4.20.1.1"
	oidIpAdEntIfIndex = ".1.3.6.1.2.1.4.20.1.2"

	// Extended interface table (ifXTable)
	oidIfXTable    = ".1.3.6.1.2.1.31.1.1.1"
	oidIfName      = ".1.3.6.1.2.1.31.1.1.1.1"
	oidIfAlias     = ".1.3.6.1.2.1.31.1.1.1.18"
	oidIfHighSpeed = ".1.3.6.1.2.1.31.1.1.1.15"

	// LLDP OIDs
	oidLldpRemTable     = ".1.0.8802.1.1.2.1.4.1.1"
	oidLldpRemChassisId = ".1.0.8802.1.1.2.1.4.1.1.5"
	oidLldpRemPortId    = ".1.0.8802.1.1.2.1.4.1.1.7"
	oidLldpRemPortDesc  = ".1.0.8802.1.1.2.1.4.1.1.8"
	oidLldpRemSysName   = ".1.0.8802.1.1.2.1.4.1.1.9"
	oidLldpRemManAddr   = ".1.0.8802.1.1.2.1.4.2.1.3"

	// CDP OIDs (Cisco Discovery Protocol)
	oidCdpCacheTable      = ".1.3.6.1.4.1.9.9.23.1.2.1.1"
	oidCdpCacheDeviceId   = ".1.3.6.1.4.1.9.9.23.1.2.1.1.6"
	oidCdpCacheDevicePort = ".1.3.6.1.4.1.9.9.23.1.2.1.1.7"
	oidCdpCacheAddress    = ".1.3.6.1.4.1.9.9.23.1.2.1.1.4"

	// Default concurrency settings
	defaultConcurrency = 10
	defaultMaxIPRange  = 256 // Maximum IPs to process from a CIDR range
)

// runDiscoveryJob performs the actual SNMP discovery for a job
func (e *SnmpDiscoveryEngine) runDiscoveryJob(ctx context.Context, job *DiscoveryJob) {
	log.Printf("Running discovery for job %s. Seeds: %v, Type: %s", job.ID, job.Params.Seeds, job.Params.Type)

	// Process seeds into target IPs
	job.scanQueue = expandSeeds(job.Params.Seeds)
	totalTargets := len(job.scanQueue)

	if totalTargets == 0 {
		job.mu.Lock()
		job.Status.Status = DiscoveryStatusFailed
		job.Status.Error = "No valid targets to scan after processing seeds"
		job.Status.Progress = 100
		job.mu.Unlock()
		log.Printf("Job %s: Failed - no valid targets to scan", job.ID)
		return
	}

	log.Printf("Job %s: Expanded seeds to %d target IPs", job.ID, totalTargets)

	// Set up concurrency
	concurrency := job.Params.Concurrency
	if concurrency <= 0 {
		concurrency = defaultConcurrency
	}
	if concurrency > totalTargets {
		concurrency = totalTargets // Don't create more workers than needed
	}

	// Create channels for worker pool
	var wg sync.WaitGroup
	targetChan := make(chan string, concurrency*2)
	resultChan := make(chan bool, concurrency) // For progress tracking

	// Start worker goroutines
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
					if pingErr := pingHost(ctx, target); pingErr != nil {
						log.Printf("Job %s: Host %s is not responding to ICMP ping: %v", job.ID, target, pingErr)
						return
					}

					e.scanTarget(job, target)
					resultChan <- true // Signal completion for progress tracking
				}
			}
		}(i)
	}

	// Progress tracking goroutine
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
				// Continue processing
			}
		}
	}()

	// Feed targets to workers
	job.mu.Lock()
	job.Status.Progress = 5 // Initial progress
	job.mu.Unlock()

	log.Printf("Job %s: Scan queue: %v", job.ID, job.scanQueue)

	for _, target := range job.scanQueue {
		select {
		case targetChan <- target:
			// Target sent to worker
		case <-job.ctx.Done():
			log.Printf("Job %s: Stopping target feed due to cancellation", job.ID)
			close(targetChan)
			close(resultChan)
			return
		case <-e.done:
			log.Printf("Job %s: Stopping target feed due to engine shutdown", job.ID)
			close(targetChan)
			close(resultChan)
			return
		}
	}
	close(targetChan)

	// Wait for all workers to finish
	wg.Wait()
	close(resultChan)

	// Check for cancellation
	select {
	case <-job.ctx.Done():
		job.mu.Lock()
		job.Status.Status = DiscoverStatusCanceled
		job.Status.Error = "Job canceled during execution"
		job.mu.Unlock()
		log.Printf("Job %s: Canceled during execution", job.ID)
		return
	case <-e.done:
		job.mu.Lock()
		job.Status.Status = DiscoveryStatusFailed
		job.Status.Error = "Engine shutting down"
		job.mu.Unlock()
		log.Printf("Job %s: Failed due to engine shutdown", job.ID)
		return
	default:
		// Job completed successfully
	}

	// Final job status update
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

// expandSeeds expands CIDR ranges and individual IPs into a list of IPs
func expandSeeds(seeds []string) []string {
	var targets []string
	seen := make(map[string]bool) // To avoid duplicates

	for _, seed := range seeds {
		// Check if the seed is a CIDR notation
		if strings.Contains(seed, "/") {
			ip, ipNet, err := net.ParseCIDR(seed)
			if err != nil {
				log.Printf("Invalid CIDR %s: %v", seed, err)
				continue
			}

			// Check if range is too large
			ones, bits := ipNet.Mask.Size()
			hostBits := bits - ones
			if hostBits > 8 { // More than 256 hosts
				log.Printf("CIDR range %s too large (/%d), limiting scan", seed, ones)
				// Only scan first 256 IPs
				count := 0
				for ip := ip.Mask(ipNet.Mask); ipNet.Contains(ip) && count < defaultMaxIPRange; incrementIP(ip) {
					ipStr := ip.String()
					if !seen[ipStr] {
						targets = append(targets, ipStr)
						seen[ipStr] = true
						count++
					}
				}
			} else {
				// Process all IPs in the range
				for ip := ip.Mask(ipNet.Mask); ipNet.Contains(ip); incrementIP(ip) {
					ipStr := ip.String()
					if !seen[ipStr] {
						targets = append(targets, ipStr)
						seen[ipStr] = true
					}
				}
			}

			// For IPv4, remove network and broadcast addresses for subnets larger than /30
			if ip.To4() != nil && ones < 31 && len(targets) > 2 {
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
				targets = filteredTargets
			}
		} else {
			// It's a single IP
			ip := net.ParseIP(seed)
			if ip == nil {
				log.Printf("Invalid IP %s", seed)
				continue
			}

			ipStr := ip.String()
			if !seen[ipStr] {
				targets = append(targets, ipStr)
				seen[ipStr] = true
			}
		}
	}

	return targets
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

// scanTarget performs SNMP scanning of a single target IP
func (e *SnmpDiscoveryEngine) scanTarget(job *DiscoveryJob, target string) {
	log.Printf("Job %s: Scanning target %s", job.ID, target)

	// Skip if already discovered (concurrency check)
	job.mu.Lock()
	if job.discoveredIPs[target] {
		log.Printf("Job %s: Skipping already discovered target %s", job.ID, target)
		job.mu.Unlock()
		return
	}
	job.discoveredIPs[target] = true
	job.mu.Unlock()

	// Create SNMP client
	client, err := e.createSNMPClient(target, job.Params.Credentials)
	if err != nil {
		log.Printf("Job %s: Failed to create SNMP client for %s: %v", job.ID, target, err)
		return
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
		log.Printf("Job %s: Failed to connect to %s: %v", job.ID, target, err)
		return
	}
	defer client.Conn.Close()

	// Query system information
	device, err := e.querySysInfo(client, target, job.ID)
	if err != nil {
		log.Printf("Job %s: Failed to query system info for %s: %v", job.ID, target, err)
		return
	}

	// Add device to results
	job.mu.Lock()
	job.Results.Devices = append(job.Results.Devices, device)
	job.mu.Unlock()

	// Publish device
	if e.publisher != nil {
		if err := e.publisher.PublishDevice(job.ctx, device); err != nil {
			log.Printf("Job %s: Failed to publish device %s: %v", job.ID, target, err)
		}
	}

	// Query interfaces if needed
	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeInterfaces {
		interfaces, err := e.queryInterfaces(client, target, job.ID)
		if err != nil {
			log.Printf("Job %s: Failed to query interfaces for %s: %v", job.ID, target, err)
		} else if len(interfaces) > 0 {
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
	}

	// Query topology if needed
	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeTopology {
		// Try LLDP first
		lldpLinks, lldpErr := e.queryLLDP(client, target, job.ID)
		if lldpErr == nil && len(lldpLinks) > 0 {
			job.mu.Lock()
			job.Results.TopologyLinks = append(job.Results.TopologyLinks, lldpLinks...)
			job.mu.Unlock()

			// Publish LLDP links
			if e.publisher != nil {
				for _, link := range lldpLinks {
					if err := e.publisher.PublishTopologyLink(job.ctx, link); err != nil {
						log.Printf("Job %s: Failed to publish LLDP link %s/%d: %v",
							job.ID, target, link.LocalIfIndex, err)
					}
				}
			}
		} else {
			log.Printf("Job %s: LLDP not supported or no neighbors on %s: %v", job.ID, target, lldpErr)

			// Try CDP if LLDP failed
			cdpLinks, cdpErr := e.queryCDP(client, target, job.ID)
			if cdpErr == nil && len(cdpLinks) > 0 {
				job.mu.Lock()
				job.Results.TopologyLinks = append(job.Results.TopologyLinks, cdpLinks...)
				job.mu.Unlock()

				// Publish CDP links
				if e.publisher != nil {
					for _, link := range cdpLinks {
						if err := e.publisher.PublishTopologyLink(job.ctx, link); err != nil {
							log.Printf("Job %s: Failed to publish CDP link %s/%d: %v",
								job.ID, target, link.LocalIfIndex, err)
						}
					}
				}
			} else {
				log.Printf("Job %s: CDP not supported or no neighbors on %s: %v", job.ID, target, cdpErr)
			}
		}
	}
}

// querySysInfo queries basic system information via SNMP
func (e *SnmpDiscoveryEngine) querySysInfo(client *gosnmp.GoSNMP, target, jobID string) (*DiscoveredDevice, error) {
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
		return nil, fmt.Errorf("SNMP Get failed: %w", err)
	}

	if result.Error != gosnmp.NoError {
		return nil, fmt.Errorf("SNMP error: %s", result.Error)
	}

	// Create device and populate from results
	device := &DiscoveredDevice{
		IP:        target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
		Metadata:  make(map[string]string),
	}

	foundSomething := false
	for _, v := range result.Variables {
		// Skip NoSuchObject/NoSuchInstance
		if v.Type == gosnmp.NoSuchObject || v.Type == gosnmp.NoSuchInstance {
			continue
		}

		foundSomething = true

		switch v.Name {
		case oidSysDescr:
			if v.Type == gosnmp.OctetString {
				device.SysDescr = string(v.Value.([]byte))
			}
		case oidSysObjectID:
			if v.Type == gosnmp.ObjectIdentifier {
				device.SysObjectID = v.Value.(string)
			}
		case oidSysUptime:
			if v.Type == gosnmp.TimeTicks {
				device.Uptime = int64(v.Value.(uint32))
			}
		case oidSysContact:
			if v.Type == gosnmp.OctetString {
				device.SysContact = string(v.Value.([]byte))
			}
		case oidSysName:
			if v.Type == gosnmp.OctetString {
				device.Hostname = string(v.Value.([]byte))
			}
		case oidSysLocation:
			if v.Type == gosnmp.OctetString {
				device.SysLocation = string(v.Value.([]byte))
			}
		}
	}

	if !foundSomething {
		return nil, fmt.Errorf("no SNMP data returned")
	}

	// Use IP as hostname if not provided
	if device.Hostname == "" {
		device.Hostname = target
	}

	// Add job metadata
	device.Metadata["discovery_id"] = jobID
	device.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)

	return device, nil
}

// queryInterfaces queries interface information via SNMP
func (e *SnmpDiscoveryEngine) queryInterfaces(client *gosnmp.GoSNMP, target, jobID string) ([]*DiscoveredInterface, error) {
	// Map to store interfaces by index
	ifMap := make(map[int]*DiscoveredInterface)

	// Walk ifTable to get basic interface information
	err := client.BulkWalk(oidIfTable, func(pdu gosnmp.SnmpPDU) error {
		// Extract ifIndex from OID
		parts := strings.Split(pdu.Name, ".")
		if len(parts) < 2 {
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

		switch "." + oidPrefix {
		case oidIfDescr:
			if pdu.Type == gosnmp.OctetString {
				iface.IfDescr = string(pdu.Value.([]byte))
			}
		case oidIfType:
			if pdu.Type == gosnmp.Integer {
				iface.IfType = int(pdu.Value.(int))
			}
		case oidIfSpeed:
			switch pdu.Type {
			case gosnmp.Gauge32:
				iface.IfSpeed = int64(pdu.Value.(uint))
			case gosnmp.Counter32, gosnmp.Counter64:
				iface.IfSpeed = int64(gosnmp.ToBigInt(pdu.Value).Int64())
			}
		case oidIfPhysAddress:
			if pdu.Type == gosnmp.OctetString {
				iface.IfPhysAddress = formatMACAddress(pdu.Value.([]byte))
			}
		case oidIfAdminStatus:
			if pdu.Type == gosnmp.Integer {
				iface.IfAdminStatus = int(pdu.Value.(int))
			}
		case oidIfOperStatus:
			if pdu.Type == gosnmp.Integer {
				iface.IfOperStatus = int(pdu.Value.(int))
			}
		}

		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk ifTable: %w", err)
	}

	// Try to get additional interface info from ifXTable (if available)
	client.BulkWalk(oidIfXTable, func(pdu gosnmp.SnmpPDU) error {
		parts := strings.Split(pdu.Name, ".")
		if len(parts) < 2 {
			return nil
		}

		ifIndex, err := strconv.Atoi(parts[len(parts)-1])
		if err != nil {
			return nil
		}

		if iface, exists := ifMap[ifIndex]; exists {
			oidPrefix := strings.Join(parts[:len(parts)-1], ".")

			switch "." + oidPrefix {
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
					highSpeed := int64(pdu.Value.(uint)) * 1000000
					if highSpeed > iface.IfSpeed {
						iface.IfSpeed = highSpeed
					}
				}
			}
		}

		return nil
	})

	// Get IP addresses from ipAddrTable
	ipToIfIndex := make(map[string]int)

	client.BulkWalk(oidIpAddrTable, func(pdu gosnmp.SnmpPDU) error {
		// Handle ipAdEntIfIndex to get the mapping of IP to ifIndex
		if strings.HasPrefix(pdu.Name, oidIpAdEntIfIndex) {
			if pdu.Type == gosnmp.Integer {
				ifIndex := int(pdu.Value.(int))

				// Extract IP from OID (.1.3.6.1.2.1.4.20.1.2.X.X.X.X)
				parts := strings.Split(pdu.Name, ".")
				if len(parts) >= 5 {
					// Last 4 parts of OID are the IP address
					ip := strings.Join(parts[len(parts)-4:], ".")
					ipToIfIndex[ip] = ifIndex
				}
			}
		}

		// Now get the actual IP addresses
		if strings.HasPrefix(pdu.Name, oidIpAdEntAddr) {
			var ipString string

			switch pdu.Type {
			case gosnmp.IPAddress:
				ipString = pdu.Value.(string)
			case gosnmp.OctetString:
				// Some devices return IP as octet string
				ipBytes := pdu.Value.([]byte)
				if len(ipBytes) == 4 {
					ipString = fmt.Sprintf("%d.%d.%d.%d", ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3])
				}
			}

			// If we got an IP, extract the IP from the OID too (for matching)
			if ipString != "" {
				parts := strings.Split(pdu.Name, ".")
				if len(parts) >= 5 {
					// Last 4 parts of OID are the IP address
					ip := strings.Join(parts[len(parts)-4:], ".")
					ipToIfIndex[ip] = 0 // Placeholder, will be filled by ipAdEntIfIndex
				}
			}
		}

		return nil
	})

	// Associate IPs with interfaces
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

	// Convert map to slice and finalize interfaces
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

		// Add metadata
		iface.Metadata["discovery_id"] = jobID
		iface.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)

		interfaces = append(interfaces, iface)
	}

	return interfaces, nil
}

// queryLLDP queries LLDP topology information
func (e *SnmpDiscoveryEngine) queryLLDP(client *gosnmp.GoSNMP, target, jobID string) ([]*TopologyLink, error) {
	linkMap := make(map[string]*TopologyLink) // Key is "timeMark.localPort.index"

	// Walk LLDP remote table
	err := client.BulkWalk(oidLldpRemTable, func(pdu gosnmp.SnmpPDU) error {
		parts := strings.Split(pdu.Name, ".")
		if len(parts) < 11 {
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
			localPortIdx, _ := strconv.Atoi(localPort)
			linkMap[key] = &TopologyLink{
				Protocol:      "LLDP",
				LocalDeviceIP: target,
				LocalIfIndex:  localPortIdx,
				Metadata:      make(map[string]string),
			}
		}

		link := linkMap[key]

		// Extract OID suffix for comparison
		oidSuffix := parts[len(parts)-4]

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

		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk LLDP table: %w", err)
	}

	// Walk LLDP management address table for neighbor IPs
	client.BulkWalk(oidLldpRemManAddr, func(pdu gosnmp.SnmpPDU) error {
		if pdu.Type != gosnmp.OctetString {
			return nil
		}

		// Try to extract IP address from management address
		bytes := pdu.Value.([]byte)
		if len(bytes) >= 5 {
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
	})

	// Convert map to slice
	links := make([]*TopologyLink, 0, len(linkMap))
	for _, link := range linkMap {
		// Basic validation - need at least one neighbor identifier
		if link.NeighborChassisID == "" && link.NeighborSystemName == "" && link.NeighborPortID == "" {
			continue
		}

		// Add metadata
		link.Metadata["discovery_id"] = jobID
		link.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
		link.Metadata["protocol"] = "LLDP"

		links = append(links, link)
	}

	if len(links) == 0 {
		return nil, fmt.Errorf("no LLDP neighbors found")
	}

	return links, nil
}

// queryCDP queries CDP (Cisco Discovery Protocol) topology information
func (e *SnmpDiscoveryEngine) queryCDP(client *gosnmp.GoSNMP, target, jobID string) ([]*TopologyLink, error) {
	linkMap := make(map[string]*TopologyLink) // Key is "ifIndex.index"

	// Walk CDP cache table
	err := client.BulkWalk(oidCdpCacheTable, func(pdu gosnmp.SnmpPDU) error {
		parts := strings.Split(pdu.Name, ".")
		if len(parts) < 12 {
			return nil
		}

		// Extract ifIndex.index from OID
		// Format: .1.3.6.1.4.1.9.9.23.1.2.1.1.X.ifIndex.index
		ifIndex := parts[len(parts)-2]
		index := parts[len(parts)-1]
		key := fmt.Sprintf("%s.%s", ifIndex, index)

		// Create topology link if not exists
		if _, exists := linkMap[key]; !exists {
			ifIdx, _ := strconv.Atoi(ifIndex)
			linkMap[key] = &TopologyLink{
				Protocol:      "CDP",
				LocalDeviceIP: target,
				LocalIfIndex:  ifIdx,
				Metadata:      make(map[string]string),
			}
		}

		link := linkMap[key]

		// Extract OID suffix for comparison
		oidSuffix := parts[len(parts)-3]

		// Parse based on the OID suffix
		switch oidSuffix {
		case "6": // oidCdpCacheDeviceId
			if pdu.Type == gosnmp.OctetString {
				link.NeighborSystemName = string(pdu.Value.([]byte))
				// Use as chassis ID if not set
				if link.NeighborChassisID == "" {
					link.NeighborChassisID = link.NeighborSystemName
				}
			}
		case "7": // oidCdpCacheDevicePort
			if pdu.Type == gosnmp.OctetString {
				port := string(pdu.Value.([]byte))
				link.NeighborPortID = port
				link.NeighborPortDescr = port
			}
		case "4": // oidCdpCacheAddress
			if pdu.Type == gosnmp.OctetString {
				bytes := pdu.Value.([]byte)

				// CDP address format varies, try to extract IP
				if len(bytes) >= 6 { // CDP often has header bytes before the actual IP
					// Try to extract IPv4 address
					// Typical format: type(1) + len(4) + addr(4)
					if bytes[0] == 1 && len(bytes) >= 6 { // Type 1 = IP
						ip := net.IPv4(bytes[len(bytes)-4], bytes[len(bytes)-3],
							bytes[len(bytes)-2], bytes[len(bytes)-1])
						link.NeighborMgmtAddr = ip.String()
					}
				}
			}
		}

		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk CDP table: %w", err)
	}

	// Convert map to slice
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
		return nil, fmt.Errorf("no CDP neighbors found")
	}

	return links, nil
}

// formatMACAddress formats a byte array as a MAC address string
func formatMACAddress(mac []byte) string {
	if len(mac) != 6 {
		return ""
	}

	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
		mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
}

// formatLLDPID formats LLDP identifiers which may be MAC addresses or other formats
func formatLLDPID(bytes []byte) string {
	// Check if it looks like a MAC address (common for chassis ID)
	if len(bytes) == 6 {
		return formatMACAddress(bytes)
	}

	// If it's a printable string, return as is
	return string(bytes)
}

func pingHost(ctx context.Context, host string) error {
	// Use the existing ICMPSweeper from your scan package
	sweeper, err := scan.NewICMPSweeper(1*time.Second, 100)
	if err != nil {
		return err
	}
	defer sweeper.Stop(ctx)

	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	targets := []models.Target{
		{Host: host, Mode: models.ModeICMP},
	}

	resultCh, err := sweeper.Scan(ctx, targets)
	if err != nil {
		return err
	}

	for result := range resultCh {
		if !result.Available {
			return fmt.Errorf("host unreachable")
		}
		return nil
	}

	return fmt.Errorf("no ICMP response")
}
