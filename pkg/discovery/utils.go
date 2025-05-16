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
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/gosnmp/gosnmp"
)

// Utility functions for the discovery package

// expandSeeds expands a list of seed IP addresses or CIDR ranges to individual IP addresses
func expandSeeds(seeds []string) []string {
	var expandedSeeds []string

	for _, seed := range seeds {
		if strings.Contains(seed, "/") {
			// This is a CIDR range, expand it
			ips, err := expandCIDR(seed)
			if err != nil {
				log.Printf("Error expanding CIDR %s: %v", seed, err)
				continue
			}

			expandedSeeds = append(expandedSeeds, ips...)
		} else {
			// This is a single IP address, validate it
			if net.ParseIP(seed) != nil {
				expandedSeeds = append(expandedSeeds, seed)
			} else {
				log.Printf("Invalid IP address: %s", seed)
			}
		}
	}

	return expandedSeeds
}

// expandCIDR expands a CIDR range to individual IP addresses
func expandCIDR(cidr string) ([]string, error) {
	ip, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, err
	}

	var ips []string

	// Convert IP to 4-byte representation
	if ip.To4() == nil {
		return nil, fmt.Errorf("IPv6 not supported")
	}

	// Get the network size
	ones, bits := ipnet.Mask.Size()
	if bits-ones > 16 {
		// Limit expansion to avoid huge ranges
		return nil, fmt.Errorf("CIDR range too large (max /16)")
	}

	// Iterate through all IPs in the range
	for ip := ip.Mask(ipnet.Mask); ipnet.Contains(ip); incrementIP(ip) {
		ips = append(ips, ip.String())
	}

	// Remove network and broadcast addresses for IPv4
	if len(ips) > 2 {
		ips = ips[1 : len(ips)-1]
	}

	return ips, nil
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

// splitOID splits an OID string into its numeric components
func splitOID(oid string) []int {
	oidParts := make([]int, 0)

	// Remove the leading '.' if present
	if strings.HasPrefix(oid, ".") {
		oid = oid[1:]
	}

	parts := strings.Split(oid, ".")
	for _, part := range parts {
		value, err := strconv.Atoi(part)
		if err != nil {
			continue
		}

		oidParts = append(oidParts, value)
	}

	return oidParts
}

// formatChassisID formats a chassis ID from binary data
func formatChassisID(data []byte) string {
	// Chassis ID can be MAC address or another format
	// For simplicity, we'll convert to hex string
	var result strings.Builder

	for i, b := range data {
		if i > 0 {
			result.WriteString(":")
		}

		result.WriteString(fmt.Sprintf("%02x", b))
	}

	return result.String()
}

// formatMgmtAddr formats a management address from binary data
func formatMgmtAddr(data []byte) string {
	// Try to parse as IPv4 or IPv6
	if len(data) == 4 {
		// IPv4 address
		return net.IPv4(data[0], data[1], data[2], data[3]).String()
	} else if len(data) == 16 {
		// IPv6 address
		return net.IP(data).String()
	}

	// Unknown format, return hex string
	var result strings.Builder

	for i, b := range data {
		if i > 0 {
			result.WriteString(":")
		}

		result.WriteString(fmt.Sprintf("%02x", b))
	}

	return result.String()
}

// cleanupRoutine periodically cleans up completed jobs.
func (e *SnmpDiscoveryEngine) cleanupRoutine(ctx context.Context) {
	ticker := time.NewTicker(e.config.ResultRetention / 2) // Clean more frequently than retention
	defer ticker.Stop()

	log.Println("Discovery results cleanup routine started.")

	for {
		select {
		case <-ctx.Done(): // Main context cancelled
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
func (e *SnmpDiscoveryEngine) cleanupCompletedJobs() {
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

// LoadConfigFromFile loads the discovery engine configuration from a JSON file
func LoadConfigFromFile(filename string) (*Config, error) {
	data, err := ioutil.ReadFile(filename)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	return &config, nil
}

// createSNMPClient creates an SNMP client for the given target and credentials
func (e *SnmpDiscoveryEngine) createSNMPClient(targetIP string, credentials SNMPCredentials) (*gosnmp.GoSNMP, error) {
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

	// Set version and credentials
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

		// Set authentication protocol and password
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

		// Set privacy protocol and password
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

		client.SecurityParameters = usm
		client.MsgFlags = gosnmp.AuthPriv
	default:
		return nil, fmt.Errorf("unsupported SNMP version: %s", credentials.Version)
	}

	return client, nil
}
