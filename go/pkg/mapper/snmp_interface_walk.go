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
	"fmt"

	"math"

	"strconv"

	"strings"

	"github.com/gosnmp/gosnmp"
)

func (e *DiscoveryEngine) walkIfHighSpeed(client *gosnmp.GoSNMP, ifMap map[int]*DiscoveredInterface) {
	// Check which interfaces need ifHighSpeed
	var needsHighSpeed []int

	for ifIndex, iface := range ifMap {
		if iface.IfSpeed == 4294967295 || iface.IfSpeed == 0 {
			needsHighSpeed = append(needsHighSpeed, ifIndex)
		}
	}

	if len(needsHighSpeed) == 0 {
		return
	}

	// Walk ifHighSpeed
	err := client.BulkWalk(oidIfHighSpeed, func(pdu gosnmp.SnmpPDU) error {
		// Extract ifIndex
		parts := strings.Split(pdu.Name, ".")
		if len(parts) < 1 {
			return nil
		}

		ifIndexStr := parts[len(parts)-1]

		ifIndex, err := strconv.Atoi(ifIndexStr)
		if err != nil {
			return nil
		}

		if iface, exists := ifMap[ifIndex]; exists {
			updateInterfaceHighSpeed(iface, pdu)
		}

		return nil
	})
	if err != nil {
		e.logger.Debug().Err(err).Msg("Failed to walk ifHighSpeed")
	}
}

// walkIfTable walks the ifTable to get basic interface information
func (e *DiscoveryEngine) walkIfTable(
	client *gosnmp.GoSNMP,
	target string,
	ifMap map[int]*DiscoveredInterface,
	deviceID string,
) error {
	// First, let's walk the entire ifTable
	processedOIDs := make(map[string]int)

	e.logger.Debug().Str("target", target).Msg("Starting SNMP walk of ifTable")

	err := client.BulkWalk(oidIfTable, func(pdu gosnmp.SnmpPDU) error {
		// Track what OIDs we're getting
		parts := strings.Split(pdu.Name, ".")
		if len(parts) >= defaultPartsLenCheck {
			oidPrefix := strings.Join(parts[:len(parts)-1], ".")

			processedOIDs[oidPrefix]++
		}

		return e.processIfTablePDU(pdu, target, deviceID, ifMap)
	})
	if err != nil {
		return fmt.Errorf("failed to walk ifTable: %w", err)
	}

	// If we didn't get ifSpeed in the walk, try walking it specifically
	ifSpeedOIDPrefix := strings.TrimSuffix(oidIfSpeed, ".0")

	if count, found := processedOIDs[ifSpeedOIDPrefix]; !found || count == 0 {
		// Walk just the ifSpeed column
		err := client.BulkWalk(ifSpeedOIDPrefix, func(pdu gosnmp.SnmpPDU) error {
			return e.processIfSpeedPDU(pdu, target, ifMap)
		})
		if err != nil {
			e.logger.Debug().Err(err).Msg("Specific ifSpeed walk failed")
		}
	}

	return nil
}

func (e *DiscoveryEngine) processIfSpeedPDU(
	pdu gosnmp.SnmpPDU, target string, ifMap map[int]*DiscoveredInterface) error {
	// Extract ifIndex from OID (e.g., .1.3.6.1.2.1.2.2.1.5.1 -> 1)
	parts := strings.Split(pdu.Name, ".")
	if len(parts) < 1 {
		return nil
	}

	ifIndexStr := parts[len(parts)-1]

	ifIndexInt, err := strconv.Atoi(ifIndexStr)
	if err != nil {
		e.logger.Warn().Str("oid", pdu.Name).Err(err).Msg("Failed to parse ifIndex from OID")

		return nil
	}

	// FIXED: Safe conversion with error handling
	ifIndex, err := safeIntToInt32(ifIndexInt, "ifIndex")
	if err != nil {
		e.logger.Warn().Err(err).Msg("Skipping interface")

		return nil
	}

	// Create interface if it doesn't exist
	if _, exists := ifMap[int(ifIndex)]; !exists {
		ifMap[int(ifIndex)] = &DiscoveredInterface{
			DeviceIP:    target,
			IfIndex:     ifIndex,
			IfSpeed:     0,
			IPAddresses: []string{},
			Metadata:    make(map[string]string),
		}
	}

	iface := ifMap[int(ifIndex)]

	// Process the speed value
	e.updateIfSpeed(iface, pdu)

	return nil
}

const (
	defaultPartsLenCheck = 2
)

// processIfXTablePDU processes a single PDU from the ifXTable walk
func (e *DiscoveryEngine) processIfXTablePDU(pdu gosnmp.SnmpPDU, ifMap map[int]*DiscoveredInterface) error {
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
	e.updateInterfaceFromOID(iface, "."+oidPrefix, pdu)

	return nil
}

const (
	overflowValue    = 9223372036854775807
	defaultHighSpeed = 1000000 // 1 million, for converting Mbps to bps
	defaultOverflow  = 1000000

	// Progress calculation constants
	progressInitial   = 5.0   // Initial progress percentage
	progressScanning  = 90.0  // Percentage allocated for scanning
	progressCompleted = 100.0 // Final progress percentage when completed

	// Network constants
	maxUint32Value = 4294967295 // Maximum value for a uint32

	// Overflow heuristic constants
	overflowHeuristicDivisor = 2 // Divisor used in overflow detection heuristic
)

// updateInterfaceHighSpeed updates the interface speed from ifHighSpeed value
func updateInterfaceHighSpeed(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	// Accept both Integer and Gauge32 types for high speed
	if pdu.Type != gosnmp.Integer && pdu.Type != gosnmp.Gauge32 {
		return
	}

	var mbps uint64

	switch v := pdu.Value.(type) {
	case uint:
		mbps = uint64(v)
	case int:
		if v < 0 {
			return
		}

		mbps = uint64(v)
	default:
		return
	}

	// If mbps is 0, set IfSpeed to 0
	if mbps == 0 {
		iface.IfSpeed = 0
		return
	}

	// Convert to bps (uint64)
	bps := mbps * defaultHighSpeed // Multiply by 1 million

	// Check for overflow before assignment if necessary, though unlikely for interface speeds
	if bps > math.MaxUint64/overflowHeuristicDivisor &&
		mbps > math.MaxUint64/(overflowHeuristicDivisor*defaultHighSpeed) { // Simple overflow heuristic
		bps = math.MaxUint64
	}

	// Always update the speed, not just if higher
	iface.IfSpeed = bps
}

// walkIfXTable walks the ifXTable to get additional interface information
func (e *DiscoveryEngine) walkIfXTable(client *gosnmp.GoSNMP, ifMap map[int]*DiscoveredInterface) error {
	err := client.BulkWalk(oidIfXTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processIfXTablePDU(pdu, ifMap)
	})

	return err
}
