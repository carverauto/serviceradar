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
	"encoding/binary"

	"github.com/gosnmp/gosnmp"
)

// convertToUint64 safely converts various numeric types to uint64.
func convertToUint64(value interface{}) (uint64, bool) {
	switch v := value.(type) {
	case uint:
		return uint64(v), true
	case uint32:
		return uint64(v), true
	case uint64:
		return v, true
	case int:
		if v >= 0 {
			return uint64(v), true
		}
	case int32:
		if v >= 0 {
			return uint64(v), true
		}
	case int64:
		if v >= 0 {
			return uint64(v), true
		}
	}

	return 0, false
}

// isMaxUint32 checks if the value is the maximum uint32 value.
func isMaxUint32(value uint64) bool {
	return value == maxUint32Value
}

// extractSpeedFromGauge32 extracts speed from Gauge32 type.
func (e *DiscoveryEngine) extractSpeedFromGauge32(value interface{}) uint64 {
	speed, ok := convertToUint64(value)
	if !ok {
		e.logger.Warn().Interface("value_type", value).Interface("value", value).Msg("Unexpected Gauge32 value type for ifSpeed")

		return 0
	}

	// Special handling for max uint32 value (4294967295)
	if isMaxUint32(speed) {
		// This usually means the speed is higher than can be represented in 32 bits
		// We should check ifHighSpeed for this interface
		return 0 // Will be updated by ifHighSpeed if available
	}

	return speed
}

// extractSpeedFromCounter32 extracts speed from Counter32 type.
func extractSpeedFromCounter32(value interface{}) uint64 {
	speed, ok := convertToUint64(value)
	if ok {
		return speed
	}

	return 0
}

// extractSpeedFromCounter64 extracts speed from Counter64 type.
func extractSpeedFromCounter64(value interface{}) uint64 {
	// First try standard conversion
	speed, ok := convertToUint64(value)
	if ok {
		return speed
	}

	// Fall back to gosnmp's BigInt conversion
	bigInt := gosnmp.ToBigInt(value)
	if bigInt != nil {
		return bigInt.Uint64()
	}

	return 0
}

// extractSpeedFromInteger extracts speed from Integer type.
func extractSpeedFromInteger(value interface{}) uint64 {
	speed, ok := convertToUint64(value)
	if ok {
		return speed
	}

	return 0
}

// extractSpeedFromUinteger32 extracts speed from Uinteger32 type.
func extractSpeedFromUinteger32(value interface{}) uint64 {
	speed, ok := convertToUint64(value)
	if ok {
		return speed
	}

	return 0
}

// extractSpeedFromOctetString extracts speed from OctetString type.
func extractSpeedFromOctetString(value interface{}) uint64 {
	if bytes, ok := value.([]byte); ok && len(bytes) >= 4 {
		// Try to parse as big-endian uint32
		return uint64(binary.BigEndian.Uint32(bytes[:4]))
	}

	return 0
}

// updateIfSpeed updates the interface speed.
func (e *DiscoveryEngine) updateIfSpeed(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	var speed uint64

	switch uint8(pdu.Type) {
	case uint8(gosnmp.Gauge32):
		speed = e.extractSpeedFromGauge32(pdu.Value)
	case uint8(gosnmp.Counter32):
		speed = extractSpeedFromCounter32(pdu.Value)
	case uint8(gosnmp.Counter64):
		speed = extractSpeedFromCounter64(pdu.Value)
	case uint8(gosnmp.Integer):
		speed = extractSpeedFromInteger(pdu.Value)
	case uint8(gosnmp.Uinteger32):
		speed = extractSpeedFromUinteger32(pdu.Value)
	case uint8(gosnmp.OctetString):
		speed = extractSpeedFromOctetString(pdu.Value)
	case uint8(gosnmp.NoSuchObject), uint8(gosnmp.NoSuchInstance):
		// Interface doesn't support speed reporting
		e.logger.Debug().Int("if_index", int(iface.IfIndex)).
			Msg("ifSpeed not supported (NoSuchObject/Instance)")

		speed = 0
	default:
		e.logger.Warn().Int("if_index", int(iface.IfIndex)).
			Interface("pdu_type", pdu.Type).Interface("value", pdu.Value).
			Msg("Unexpected PDU type for ifSpeed")

		speed = 0
	}

	iface.IfSpeed = speed
}
