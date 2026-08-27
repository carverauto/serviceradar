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

	"strings"

	"github.com/gosnmp/gosnmp"
)

// processSNMPVariables processes SNMP variables and populates the device object
func (e *DiscoveryEngine) processSNMPVariables(device *DiscoveredDevice, variables []gosnmp.SnmpPDU) bool {
	return e.processSNMPVariablesWithErrors(device, variables, nil)
}

func (e *DiscoveryEngine) processSNMPVariablesWithErrors(
	device *DiscoveredDevice, variables []gosnmp.SnmpPDU, extractionErrors map[string]string,
) bool {
	foundSomething := false

	for _, v := range variables {
		// Skip NoSuchObject/NoSuchInstance
		if v.Type == gosnmp.NoSuchObject || v.Type == gosnmp.NoSuchInstance {
			continue
		}

		foundSomething = true

		updated := e.processSNMPVariable(device, v)
		if !updated && extractionErrors != nil {
			if field := snmpFieldKeyForOID(v.Name); field != "" {
				extractionErrors[field] = fmt.Sprintf("unsupported or malformed %s value", v.Name)
			}
		}
	}

	return foundSomething
}

// processSNMPVariable processes a single SNMP variable and updates the device
func (e *DiscoveryEngine) processSNMPVariable(device *DiscoveredDevice, v gosnmp.SnmpPDU) bool {
	switch v.Name {
	case oidSysDescr:
		return e.setStringValue(&device.SysDescr, v)
	case oidSysObjectID:
		return e.setObjectIDValue(&device.SysObjectID, v)
	case oidSysUptime:
		return e.setUptimeValue(&device.Uptime, v)
	case oidSysContact:
		return e.setStringValue(&device.SysContact, v)
	case oidSysName:
		updated := e.setStringValue(&device.SysName, v)
		if updated && device.Hostname == "" {
			device.Hostname = device.SysName
		}
		return updated
	case oidSysLocation:
		return e.setStringValue(&device.SysLocation, v)
	case oidIPForwarding:
		return e.setInt32Value(&device.IPForwarding, v)
	case oidDot1dBaseBridgeAddress:
		return e.setBridgeMACValue(&device.BridgeBaseMAC, v)
	}

	return false
}

// setStringValue sets a string value from an SNMP PDU if it's the correct type
func (*DiscoveryEngine) setStringValue(target *string, v gosnmp.SnmpPDU) bool {
	if val, ok := snmpStringValue(v); ok {
		*target = val
		return true
	}

	return false
}

// setObjectIDValue sets an object ID value from an SNMP PDU if it's the correct type
func (*DiscoveryEngine) setObjectIDValue(target *string, v gosnmp.SnmpPDU) bool {
	if val, ok := snmpObjectIDValue(v); ok {
		*target = val
		return true
	}

	return false
}

// setUptimeValue sets an uptime value from an SNMP PDU if it's the correct type
func (*DiscoveryEngine) setUptimeValue(target *int64, v gosnmp.SnmpPDU) bool {
	if v.Type != gosnmp.TimeTicks {
		return false
	}

	switch val := v.Value.(type) {
	case uint32:
		*target = int64(val)
		return true
	case int:
		if val >= 0 {
			*target = int64(val)
			return true
		}
	case int64:
		if val >= 0 {
			*target = val
			return true
		}
	}

	bigVal := gosnmp.ToBigInt(v.Value)
	if bigVal == nil || bigVal.Sign() < 0 {
		return false
	}
	*target = bigVal.Int64()
	return true
}

// setInt32Value sets a signed integer value from an SNMP PDU.
func (*DiscoveryEngine) setInt32Value(target *int32, v gosnmp.SnmpPDU) bool {
	switch val := v.Value.(type) {
	case int:
		*target = safeInt32(val)
		return true
	case int32:
		*target = val
		return true
	case int64:
		*target = safeInt32(int(val))
		return true
	case uint:
		*target = safeInt32(int(val))
		return true
	case uint32:
		*target = safeInt32(int(val))
		return true
	case uint64:
		*target = safeInt32(int(val))
		return true
	default:
		bigVal := gosnmp.ToBigInt(v.Value)
		if bigVal != nil {
			*target = safeInt32(int(bigVal.Int64()))
			return true
		}
	}

	return false
}

// setBridgeMACValue sets the bridge base MAC from an OctetString.
func (*DiscoveryEngine) setBridgeMACValue(target *string, v gosnmp.SnmpPDU) bool {
	if v.Type != gosnmp.OctetString {
		return false
	}

	switch val := v.Value.(type) {
	case []byte:
		if mac := formatMACAddress(val); mac != "" {
			*target = mac
			return true
		}
	case string:
		if val != "" {
			*target = val
			return true
		}
	}

	return false
}

// getMACAddress tries to get the MAC address of a device using SNMP
func (e *DiscoveryEngine) getMACAddress(client *gosnmp.GoSNMP, target, jobID string) string {
	// Try ifPhysAddress.1 (first interface). On Linux this is usually `lo`
	// with an empty or all-zero MAC — do not treat that as the chassis ID
	// or we skip the walk that would find eth0.
	macOID := ".1.3.6.1.2.1.2.2.1.6.1"

	result, err := client.Get([]string{macOID})
	if err == nil && len(result.Variables) > 0 && result.Variables[0].Type == gosnmp.OctetString {
		if mac := usableMACFromPDUValue(result.Variables[0].Value); mac != "" {
			return mac
		}
	}

	// If still empty, try walking ifPhysAddress table to find any MAC
	var mac string

	err = client.BulkWalk(oidIfPhysAddress, func(pdu gosnmp.SnmpPDU) error {
		if pdu.Type == gosnmp.OctetString {
			formattedMAC := usableMACFromPDUValue(pdu.Value)
			if formattedMAC != "" {
				mac = formattedMAC
				return ErrFoundMACStoppingWalk
			}
		}

		return nil
	})

	if err != nil && !strings.Contains(err.Error(), "found MAC, stopping walk") {
		e.logger.Warn().Str("job_id", jobID).Str("target", target).Err(err).
			Msg("Failed to walk ifPhysAddress for MAC")
	}

	return mac
}
