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

package mapper

import (
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"github.com/gosnmp/gosnmp"
)

// Utility functions for the discovery package

const (
	defaultResultRetentionDivisor = 2
)

// cleanupRoutine periodically cleans up completed jobs.
func (e *DiscoveryEngine) cleanupRoutine(ctx context.Context) {
	ticker := time.NewTicker(
		e.config.ResultRetention / defaultResultRetentionDivisor) // Clean more frequently than retention
	defer ticker.Stop()

	log.Println("Discovery results cleanup routine started.")

	for {
		select {
		case <-ctx.Done(): // Main context canceled
			log.Println("Cleanup routine stopping due to main context cancellation.")
			return
		case <-e.done: // Engine stopping
			log.Println("Cleanup routine stopping due to engine shutdown.")
			return
		case <-ticker.C:
			e.cleanupCompletedJobs()
		}
	}
}

// cleanupCompletedJobs removes old completed jobs.
func (e *DiscoveryEngine) cleanupCompletedJobs() {
	e.mu.Lock()
	defer e.mu.Unlock()

	log.Printf("Cleaning up completed jobs (retention: %v)", e.config.ResultRetention)

	cutoff := time.Now().Add(-e.config.ResultRetention)
	removed := 0

	for id, results := range e.completedJobs {
		if results.Status.EndTime.Before(cutoff) {
			delete(e.completedJobs, id)

			removed++
		}
	}

	log.Printf("Removed %d expired completed jobs", removed)
}

// createSNMPClient creates an SNMP client for the given target and credentials
func (e *DiscoveryEngine) createSNMPClient(targetIP string, credentials *SNMPCredentials) (*gosnmp.GoSNMP, error) {
	// Check if there are target-specific credentials
	if credentials.TargetSpecific != nil {
		if targetCreds, ok := credentials.TargetSpecific[targetIP]; ok {
			credentials = targetCreds
		}
	}

	client := &gosnmp.GoSNMP{
		Target:             targetIP,
		Port:               161, // Default SNMP port
		Timeout:            e.config.Timeout,
		Retries:            e.config.Retries,
		MaxOids:            gosnmp.MaxOids,
		MaxRepetitions:     10,
		ExponentialTimeout: true,
	}

	// Configure client based on SNMP version
	err := e.configureClientVersion(client, credentials)
	if err != nil {
		return nil, err
	}

	return client, nil
}

// configureClientVersion sets up the SNMP client based on the version in the credentials
func (e *DiscoveryEngine) configureClientVersion(client *gosnmp.GoSNMP, credentials *SNMPCredentials) error {
	switch credentials.Version {
	case SNMPVersion1:
		client.Version = gosnmp.Version1
		client.Community = credentials.Community
	case SNMPVersion2c:
		client.Version = gosnmp.Version2c
		client.Community = credentials.Community
	case SNMPVersion3:
		client.Version = gosnmp.Version3

		// Set SNMPv3 security parameters
		usm := &gosnmp.UsmSecurityParameters{
			UserName: credentials.Username,
		}

		// Configure authentication and privacy
		e.configureV3Authentication(usm, credentials)
		e.configureV3Privacy(usm, credentials)

		client.SecurityParameters = usm
		client.MsgFlags = gosnmp.AuthPriv
	default:
		return fmt.Errorf("%w for version: %s", ErrUnsupportedSNMPVersion, credentials.Version)
	}

	return nil
}

// configureV3Authentication sets up the authentication protocol for SNMPv3
func (*DiscoveryEngine) configureV3Authentication(usm *gosnmp.UsmSecurityParameters, credentials *SNMPCredentials) {
	switch strings.ToUpper(credentials.AuthProtocol) {
	case "MD5":
		usm.AuthenticationProtocol = gosnmp.MD5
		usm.AuthenticationPassphrase = credentials.AuthPassword
	case "SHA":
		usm.AuthenticationProtocol = gosnmp.SHA
		usm.AuthenticationPassphrase = credentials.AuthPassword
	case "SHA224":
		usm.AuthenticationProtocol = gosnmp.SHA224
		usm.AuthenticationPassphrase = credentials.AuthPassword
	case "SHA256":
		usm.AuthenticationProtocol = gosnmp.SHA256
		usm.AuthenticationPassphrase = credentials.AuthPassword
	case "SHA384":
		usm.AuthenticationProtocol = gosnmp.SHA384
		usm.AuthenticationPassphrase = credentials.AuthPassword
	case "SHA512":
		usm.AuthenticationProtocol = gosnmp.SHA512
		usm.AuthenticationPassphrase = credentials.AuthPassword
	}
}

// configureV3Privacy sets up the privacy protocol for SNMPv3
func (*DiscoveryEngine) configureV3Privacy(usm *gosnmp.UsmSecurityParameters, credentials *SNMPCredentials) {
	switch strings.ToUpper(credentials.PrivacyProtocol) {
	case "DES":
		usm.PrivacyProtocol = gosnmp.DES
		usm.PrivacyPassphrase = credentials.PrivacyPassword
	case "AES":
		usm.PrivacyProtocol = gosnmp.AES
		usm.PrivacyPassphrase = credentials.PrivacyPassword
	case "AES192":
		usm.PrivacyProtocol = gosnmp.AES192
		usm.PrivacyPassphrase = credentials.PrivacyPassword
	case "AES256":
		usm.PrivacyProtocol = gosnmp.AES256
		usm.PrivacyPassphrase = credentials.PrivacyPassword
	}
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

func GenerateDeviceID(agentID, pollerID, mac string) string {
	// Normalize MAC address: remove colons/dashes and convert to lowercase
	normalizedMAC := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(mac, ":", ""), "-", ""))

	if normalizedMAC == "" {
		return "" // Don't generate ID without MAC
	}

	return fmt.Sprintf("%s:%s:%s", agentID, pollerID, normalizedMAC)
}

// NormalizeMAC normalizes a MAC address for consistent formatting
func NormalizeMAC(mac string) string {
	return strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(mac, ":", ""), "-", ""))
}
