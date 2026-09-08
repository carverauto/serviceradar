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

func safeIntToInt32(value int, fieldName string) (int32, error) {
	if value > math.MaxInt32 || value < math.MinInt32 {
		return 0, fmt.Errorf("%s value %d exceeds int32 range [%d, %d]: %w",
			fieldName, value, math.MinInt32, math.MaxInt32, ErrInt32RangeExceeded)
	}

	return int32(value), nil
}

func (e *DiscoveryEngine) processIfTablePDU(
	pdu gosnmp.SnmpPDU, target, deviceID string, ifMap map[int]*DiscoveredInterface) error {
	// Extract ifIndex from OID
	parts := strings.Split(pdu.Name, ".")
	if len(parts) < defaultPartsLengthCheck {
		return nil
	}

	ifIndexInt, err := strconv.Atoi(parts[len(parts)-1])
	if err != nil {
		return nil
	}

	ifIndex, err := safeIntToInt32(ifIndexInt, "ifIndex")
	if err != nil {
		e.logger.Warn().Err(err).Msg("Skipping interface")

		return nil
	}

	// Create interface if it doesn't exist
	if _, exists := ifMap[int(ifIndex)]; !exists {
		ifMap[int(ifIndex)] = &DiscoveredInterface{
			DeviceIP:    target,
			DeviceID:    deviceID,
			IfIndex:     ifIndex,
			IPAddresses: []string{},
			Metadata:    make(map[string]string),
		}
	}

	iface := ifMap[int(ifIndex)]

	// Parse specific OID
	oidPrefix := strings.Join(parts[:len(parts)-1], ".")
	e.updateInterfaceFromOID(iface, "."+oidPrefix, pdu)

	return nil
}
