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

// Package snmp pkg/agent/snmp/config.go

package snmp

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// SNMPConfig is a local copy of models.SNMPConfig to allow receiver methods
type SNMPConfig struct {
	Enabled     bool                   `json:"enabled"`
	NodeAddress string                 `json:"node_address"`
	Timeout     models.Duration        `json:"timeout"`
	ListenAddr  string                 `json:"listen_addr"`
	Security    *models.SecurityConfig `json:"security"`
	Targets     []Target               `json:"targets"`
	Partition   string                 `json:"partition"`
	Logger      *logger.Config         `json:"logger,omitempty"`
	ProfileID   string                 `json:"profile_id,omitempty"`
	ProfileName string                 `json:"profile_name,omitempty"`
}

const (
	defaultTimeout      = 5 * time.Minute
	defaultInterval     = 60 * time.Second
	defaultRetries      = 3
	defaultPort         = 161
	defaultMaxPoints    = 1000
	maxOIDNameLength    = 64
	maxTargetNameLength = 128

	// Walk bounds. A walked OID returns as many rows as the device wants to
	// report, so both a row cap and a wall-clock cap are always in effect - an
	// unbounded walk of a large or looping table would stall the poll loop.
	defaultWalkMaxRows        = 5000
	defaultWalkTimeout        = 30 * time.Second
	defaultWalkResultCapacity = 64
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
	ctx := context.Background()
	resolver := &net.Resolver{}
	if _, err := resolver.LookupHost(ctx, host); err != nil {
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

	// Validate retrieval mode and walk bounds
	return validateOIDMode(oid)
}

// validateOIDMode validates the retrieval mode and its walk bounds. An empty mode
// is left empty rather than normalized, so a config written before walk support
// existed serializes and hashes exactly as it did before.
func validateOIDMode(oid *OIDConfig) error {
	switch oid.Mode {
	case "", ModeGet, ModeWalk:
	default:
		return fmt.Errorf("%w %s", errInvalidOIDMode, oid.Mode)
	}

	if oid.MaxRows < 0 {
		return errInvalidWalkMaxRows
	}

	if time.Duration(oid.WalkTimeout) < 0 {
		return errInvalidWalkTimeout
	}

	return nil
}

// walkRowLimit returns the row cap for a walk of this OID, falling back to the
// default when the config leaves it unset.
func (o *OIDConfig) walkRowLimit() int {
	if o.MaxRows <= 0 {
		return defaultWalkMaxRows
	}

	return o.MaxRows
}

// walkTimeout returns the wall-clock bound for a walk of this OID, falling back
// to the default when the config leaves it unset.
func (o *OIDConfig) walkTimeout() time.Duration {
	if time.Duration(o.WalkTimeout) <= 0 {
		return defaultWalkTimeout
	}

	return time.Duration(o.WalkTimeout)
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

// DefaultConfig returns a default SNMP configuration for agent use.
// The default config has SNMP disabled (no targets configured).
func DefaultConfig() *SNMPConfig {
	return &SNMPConfig{
		Enabled: false,
		Timeout: models.Duration(defaultTimeout),
		Targets: []Target{},
	}
}

// LoadConfigFromFile loads an SNMPConfig from a JSON file.
func LoadConfigFromFile(path string) (*SNMPConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config SNMPConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	return &config, nil
}

// TargetRejection records one target dropped by ValidateForAgent and why.
type TargetRejection struct {
	Index int
	Name  string
	Host  string
	Err   error
}

// ValidateForAgent validates an SNMPConfig for agent use (less strict than standalone).
// This allows configs without NodeAddress, ListenAddr, and Partition.
//
// Unlike Validate, which is all-or-nothing, this DROPS an individual invalid
// target and keeps the rest, returning what it dropped so the caller can log
// it. The distinction matters because agent config is pushed from the control
// plane and covers an entire fleet: one device with an unresolvable hostname or
// a name the control plane did not sanitize would otherwise reject the whole
// config, and ApplyProtoConfig stops the running service before rebuilding it -
// so a single bad target left SNMP collection dead rather than degraded, for
// every other target on that agent including hand-built ones.
//
// An error is still returned when nothing is left to poll, since that is a
// configuration failure rather than a partial one.
func (c *SNMPConfig) ValidateForAgent() ([]TargetRejection, error) {
	if !c.Enabled {
		return nil, nil // Disabled config is always valid
	}

	if len(c.Targets) == 0 {
		return nil, errNoTargets
	}

	// Validate timeout
	if time.Duration(c.Timeout) == 0 {
		c.Timeout = models.Duration(defaultTimeout)
	}

	// Track target names to check for duplicates
	targetNames := make(map[string]bool)

	kept := c.Targets[:0]
	rejections := []TargetRejection(nil)

	for i := range c.Targets {
		if err := c.validateTarget(&c.Targets[i], targetNames); err != nil {
			rejections = append(rejections, TargetRejection{
				Index: i + 1,
				Name:  c.Targets[i].Name,
				Host:  c.Targets[i].Host,
				Err:   err,
			})

			continue
		}

		// set max data points
		if c.Targets[i].MaxPoints == 0 {
			c.Targets[i].MaxPoints = defaultMaxPoints
		}

		kept = append(kept, c.Targets[i])
	}

	c.Targets = kept

	if len(c.Targets) == 0 {
		return rejections, errNoTargets
	}

	return rejections, nil
}
