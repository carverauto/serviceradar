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
	"math"

	"strings"

	"github.com/gosnmp/gosnmp"
)

const (
	defaultPartsLengthCheck = 2
)

// updateIfDescr updates the interface description
func updateIfDescr(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if val, ok := snmpStringValue(pdu); ok {
		iface.IfDescr = val
	}
}

// updateIfName updates the interface name
func updateIfName(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if val, ok := snmpStringValue(pdu); ok {
		iface.IfName = val
	}
}

// updateIfAlias updates the interface alias
func updateIfAlias(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if val, ok := snmpStringValue(pdu); ok {
		iface.IfAlias = val
	}
}

// getInt32FromPDU safely converts a numeric SNMP PDU value to int32.
func (e *DiscoveryEngine) getInt32FromPDU(pdu gosnmp.SnmpPDU, fieldName string) (int32, bool) {
	if pdu.Type != gosnmp.Integer && pdu.Type != gosnmp.Gauge32 && pdu.Type != gosnmp.Counter32 {
		return 0, false
	}

	var val int64
	switch typed := pdu.Value.(type) {
	case int:
		val = int64(typed)
	case int32:
		val = int64(typed)
	case int64:
		val = typed
	case uint:
		val = int64(typed)
	case uint32:
		val = int64(typed)
	case uint64:
		if typed > math.MaxInt64 {
			val = math.MaxInt64
		} else {
			val = int64(typed)
		}
	default:
		if _, isString := pdu.Value.(string); isString {
			return 0, false
		}
		if _, isBytes := pdu.Value.([]byte); isBytes {
			return 0, false
		}
		bigVal := gosnmp.ToBigInt(pdu.Value)
		if bigVal == nil {
			return 0, false
		}
		val = bigVal.Int64()
	}

	if val > math.MaxInt32 || val < math.MinInt32 {
		e.logger.Warn().Str("field_name", fieldName).Int64("value", val).
			Msg("Value exceeds int32 range, using closest valid value")

		if val > math.MaxInt32 {
			return math.MaxInt32, true
		}

		return math.MinInt32, true
	}

	return int32(val), true
}

// updateIfType updates the interface type.
func (e *DiscoveryEngine) updateIfType(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if val, ok := e.getInt32FromPDU(pdu, "ifType"); ok {
		iface.IfType = val
	}
}

// updateIfPhysAddress updates the interface physical address
func updateIfPhysAddress(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if pdu.Type != gosnmp.OctetString {
		return
	}
	val, ok := pdu.Value.([]byte)
	if !ok {
		return
	}
	iface.IfPhysAddress = formatMACAddress(val)
}

func (e *DiscoveryEngine) updateIfAdminStatus(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if val, ok := e.getInt32FromPDU(pdu, "ifAdminStatus"); ok {
		iface.IfAdminStatus = val
	}
}

func (e *DiscoveryEngine) updateIfOperStatus(iface *DiscoveredInterface, pdu gosnmp.SnmpPDU) {
	if val, ok := e.getInt32FromPDU(pdu, "ifOperStatus"); ok {
		iface.IfOperStatus = val
	}
}

func matchesOIDPrefix(fullOID, prefixOID string) bool {
	// Normalize OIDs by removing leading dots if present
	fullOID = strings.TrimPrefix(fullOID, ".")
	prefixOID = strings.TrimPrefix(prefixOID, ".")

	// Check if the full OID starts with the prefix
	if !strings.HasPrefix(fullOID, prefixOID) {
		return false
	}

	// Make sure we're matching at a component boundary
	// (i.e., not matching .1.3.6.1.2.1.2.2.11 when looking for .1.3.6.1.2.1.2.2.1)
	if len(fullOID) > len(prefixOID) {
		// The next character should be a dot
		if fullOID[len(prefixOID)] != '.' {
			return false
		}
	}

	return true
}

// updateInterfaceFromOID updates interface properties based on the OID and PDU
func (e *DiscoveryEngine) updateInterfaceFromOID(
	iface *DiscoveredInterface, oidPrefix string, pdu gosnmp.SnmpPDU) {
	// Normalize the OID prefix
	oidPrefix = strings.TrimPrefix(oidPrefix, ".")

	switch {
	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfDescr, ".")):
		updateIfDescr(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfType, ".")):
		e.updateIfType(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfSpeed, ".")):
		e.updateIfSpeed(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfPhysAddress, ".")):
		updateIfPhysAddress(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfAdminStatus, ".")):
		e.updateIfAdminStatus(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfOperStatus, ".")):
		e.updateIfOperStatus(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfName, ".")):
		updateIfName(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfAlias, ".")):
		updateIfAlias(iface, pdu)

	case matchesOIDPrefix(oidPrefix, strings.TrimPrefix(oidIfHighSpeed, ".")):
		updateInterfaceHighSpeed(iface, pdu)
	default:
	}
}
