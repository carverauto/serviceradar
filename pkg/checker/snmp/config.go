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

// Package snmp pkg/checker/snmp/config.go

package snmp

import (
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// SNMPConfig is a local copy of models.SNMPConfig to allow receiver methods
type SNMPConfig struct {
	NodeAddress string                 `json:"node_address"`
	Timeout     models.Duration        `json:"timeout"`
	ListenAddr  string                 `json:"listen_addr"`
	Security    *models.SecurityConfig `json:"security"`
	Targets     []Target               `json:"targets"`
	Partition   string                 `json:"partition"`
	Logger      *logger.Config         `json:"logger,omitempty"`
}

const (
	defaultTimeout      = 5 * time.Minute
	defaultInterval     = 60 * time.Second
	defaultRetries      = 3
	defaultPort         = 161
	defaultMaxPoints    = 1000
	maxOIDNameLength    = 64
	maxTargetNameLength = 128
)

// Validate implements config.Validator interface.
func (c *SNMPConfig) Validate() error {
	if c.NodeAddress == "" {
		return errNodeAddressRequired
	}

	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	if c.Partition == "" {
		return errPartitionRequired
	}

	if len(c.Targets) == 0 {
		return errNoTargets
	}

	// Validate timeout
	if time.Duration(c.Timeout) == 0 {
		c.Timeout = models.Duration(defaultTimeout)
	}

	// Track target names to check for duplicates
	targetNames := make(map[string]bool)

	// Validate each target
	for i := range c.Targets {
		if err := c.validateTarget(&c.Targets[i], targetNames); err != nil {
			return fmt.Errorf("target %d: %w", i+1, err)
		}

		// set max data points
		if c.Targets[i].MaxPoints == 0 {
			c.Targets[i].MaxPoints = defaultMaxPoints
		}
	}

	return nil
}

// validateTarget validates a target configuration
func (*SNMPConfig) validateTarget(target *Target, targetNames map[string]bool) error {
	// Validate target name
	if err := validateTargetName(target.Name, targetNames); err != nil {
		return err
	}

	// Validate host address
	if err := validateHostAddress(target.Host); err != nil {
		return err
	}

	// Set default port if not specified
	if target.Port == 0 {
		target.Port = defaultPort
	}

	// Set default interval if not specified
	if time.Duration(target.Interval) < minInterval {
		target.Interval = Duration(defaultInterval)
	}

	// Set default retries if not specified
	if target.Retries == 0 {
		target.Retries = defaultRetries
	}

	// Validate OIDs
	if len(target.OIDs) == 0 {
		return errNoOIDs
	}

	// Track OID names to check for duplicates
	oidNames := make(map[string]bool)

	for i := range target.OIDs {
		if err := validateOIDConfig(&target.OIDs[i], oidNames); err != nil {
			return fmt.Errorf("OID %d: %w", i+1, err)
		}
	}

	return nil
}

func validateTargetName(name string, targetNames map[string]bool) error {
	if name == "" || len(name) > maxTargetNameLength {
		return errInvalidTargetName
	}

	// Check for duplicate names
	if targetNames[name] {
		return errDuplicateTargetName
	}

	targetNames[name] = true

	// Only allow alphanumeric, hyphens, and underscores
	for _, r := range name {
		if !isValidNameChar(r) {
			return errInvalidTargetName
		}
	}

	return nil
}

func validateHostAddress(host string) error {
	// Try to parse as IP address
	if ip := net.ParseIP(host); ip != nil {
		return nil
	}

	// Try to resolve hostname
	if _, err := net.LookupHost(host); err != nil {
		return fmt.Errorf("%w: %s", errInvalidHostAddress, host)
	}

	return nil
}

func validateOIDConfig(oid *OIDConfig, oidNames map[string]bool) error {
	// Validate OID name
	if oid.Name == "" {
		return errEmptyOIDName
	}

	if len(oid.Name) > maxOIDNameLength {
		return fmt.Errorf("%w %s", errOIDNameTooLong, oid.Name)
	}

	if oidNames[oid.Name] {
		return fmt.Errorf("%w %s", errOIDDuplicate, oid.Name)
	}

	oidNames[oid.Name] = true

	// Validate OID format
	if !isValidOID(oid.OID) {
		return errInvalidOID
	}

	// Validate data type
	if !isValidDataType(oid.DataType) {
		return errInvalidDataType
	}

	// Validate scale factor
	if oid.Scale < 0 {
		return errInvalidScale
	}

	if oid.Scale == 0 {
		oid.Scale = 1.0 // Set default scale
	}

	return nil
}

func isValidNameChar(r rune) bool {
	return (r >= 'a' && r <= 'z') ||
		(r >= 'A' && r <= 'Z') ||
		(r >= '0' && r <= '9') ||
		r == '-' || r == '_'
}

func isValidOID(oid string) bool {
	// Basic OID format validation
	if !strings.HasPrefix(oid, ".1.3.6.1.") {
		return false
	}

	// Check each part is a valid number
	parts := strings.Split(oid[1:], ".")
	for _, part := range parts {
		if part == "" {
			return false
		}

		for _, r := range part {
			if r < '0' || r > '9' {
				return false
			}
		}
	}

	return true
}

// isValidDataType checks if the data type is valid.
func isValidDataType(dt DataType) bool {
	switch dt {
	case TypeCounter, TypeGauge, TypeBoolean, TypeBytes, TypeString, TypeFloat:
		return true
	default:
		return false
	}
}
