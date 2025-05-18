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
	"log"
	"os"
	"strings"
	"time"

	"github.com/gosnmp/gosnmp"
)

// Utility functions for the discovery package

const (
	defaultResultRetentionDivisor = 2
)

// cleanupRoutine periodically cleans up completed jobs.
func (e *SNMPDiscoveryEngine) cleanupRoutine(ctx context.Context) {
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
func (e *SNMPDiscoveryEngine) cleanupCompletedJobs() {
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
	data, err := os.ReadFile(filename)
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
func (e *SNMPDiscoveryEngine) createSNMPClient(targetIP string, credentials *SNMPCredentials) (*gosnmp.GoSNMP, error) {
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
func (e *SNMPDiscoveryEngine) configureClientVersion(client *gosnmp.GoSNMP, credentials *SNMPCredentials) error {
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
func (*SNMPDiscoveryEngine) configureV3Authentication(usm *gosnmp.UsmSecurityParameters, credentials *SNMPCredentials) {
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
func (*SNMPDiscoveryEngine) configureV3Privacy(usm *gosnmp.UsmSecurityParameters, credentials *SNMPCredentials) {
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
