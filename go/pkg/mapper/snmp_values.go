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
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/gosnmp/gosnmp"
)

const maxPrimaryMACLabelProbes = 16

var errPrimaryMACLabelProbeLimit = errors.New("primary MAC interface label probe limit reached")

type interfaceMACCandidate struct {
	ifIndex int
	ifName  string
	ifDescr string
	mac     string
}

type snmpMACReader interface {
	Get(oids []string) (*gosnmp.SnmpPacket, error)
	BulkWalk(rootOID string, walkFn gosnmp.WalkFunc) error
	Walk(rootOID string, walkFn gosnmp.WalkFunc) error
}

type snmpVersionProvider interface {
	SNMPVersion() gosnmp.SnmpVersion
}

func selectPrimaryMAC(candidates []interfaceMACCandidate) string {
	ordered := append([]interfaceMACCandidate(nil), candidates...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].ifIndex < ordered[j].ifIndex
	})

	for _, candidate := range ordered {
		if !usableHardwareMAC(candidate.mac) {
			continue
		}

		if isVRRPInterfaceLabel(candidate.ifName) || isVRRPInterfaceLabel(candidate.ifDescr) {
			continue
		}

		return candidate.mac
	}

	return ""
}

func isVRRPInterfaceLabel(label string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(label)), "vrrp")
}

func interfaceIndexFromOID(oid string) (int, bool) {
	separator := strings.LastIndex(oid, ".")
	if separator < 0 || separator == len(oid)-1 {
		return 0, false
	}

	ifIndex, err := strconv.Atoi(oid[separator+1:])
	if err != nil {
		return 0, false
	}

	return ifIndex, true
}

func updateInterfaceMACCandidate(candidate *interfaceMACCandidate, pdu gosnmp.SnmpPDU) {
	switch {
	case matchesOIDPrefix(pdu.Name, oidIfPhysAddress):
		candidate.mac = usableMACFromPDUValue(pdu.Value)
	case matchesOIDPrefix(pdu.Name, oidIfDescr):
		if value, ok := snmpStringValue(pdu); ok {
			candidate.ifDescr = value
		}
	case matchesOIDPrefix(pdu.Name, oidIfName):
		if value, ok := snmpStringValue(pdu); ok {
			candidate.ifName = value
		}
	}
}

func interfaceMACCandidateAtIndex(
	client snmpMACReader,
	ifIndex int,
	includeMAC bool,
) (interfaceMACCandidate, error) {
	candidate := interfaceMACCandidate{ifIndex: ifIndex}
	oids := []string{
		fmt.Sprintf("%s.%d", oidIfDescr, ifIndex),
		fmt.Sprintf("%s.%d", oidIfName, ifIndex),
	}
	if includeMAC {
		oids = append([]string{fmt.Sprintf("%s.%d", oidIfPhysAddress, ifIndex)}, oids...)
	}

	variables, err := fetchSystemVariables(client.Get, oids)
	if err != nil {
		return candidate, err
	}

	for _, pdu := range variables {
		pduIndex, ok := interfaceIndexFromOID(pdu.Name)
		if !ok || pduIndex != ifIndex {
			continue
		}

		updateInterfaceMACCandidate(&candidate, pdu)
	}

	return candidate, nil
}

func walkInterfaceMACs(client snmpMACReader, walkFn gosnmp.WalkFunc) error {
	version := gosnmp.Version2c
	if provider, ok := client.(snmpVersionProvider); ok {
		version = provider.SNMPVersion()
	} else if concrete, ok := client.(*gosnmp.GoSNMP); ok {
		version = concrete.Version
	}

	if version == gosnmp.Version1 {
		return client.Walk(oidIfPhysAddress, walkFn)
	}

	return client.BulkWalk(oidIfPhysAddress, walkFn)
}

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
func (e *DiscoveryEngine) getMACAddress(client snmpMACReader, target, jobID string) string {
	// Try ifPhysAddress.1 (first interface). On Linux this is usually `lo`
	// with an empty or all-zero MAC — do not treat that as the chassis ID
	// or we skip the walk that would find eth0.
	firstCandidate, firstCandidateErr := interfaceMACCandidateAtIndex(client, 1, true)
	if firstCandidateErr == nil {
		if mac := selectPrimaryMAC([]interfaceMACCandidate{firstCandidate}); mac != "" {
			return mac
		}
	}

	var (
		mac         string
		labelErr    error
		labelProbes int
	)

	err := walkInterfaceMACs(client, func(pdu gosnmp.SnmpPDU) error {
		formattedMAC := usableMACFromPDUValue(pdu.Value)
		if formattedMAC == "" {
			return nil
		}

		ifIndex, ok := interfaceIndexFromOID(pdu.Name)
		if !ok {
			return nil
		}

		if labelProbes >= maxPrimaryMACLabelProbes {
			return errPrimaryMACLabelProbeLimit
		}
		labelProbes++

		candidate, err := interfaceMACCandidateAtIndex(client, ifIndex, false)
		if err != nil {
			if labelErr == nil {
				labelErr = err
			}

			return nil
		}

		candidate.mac = formattedMAC
		mac = selectPrimaryMAC([]interfaceMACCandidate{candidate})
		if mac != "" {
			return ErrFoundMACStoppingWalk
		}

		return nil
	})

	if err != nil && !errors.Is(err, ErrFoundMACStoppingWalk) {
		e.logger.Warn().Str("job_id", jobID).Str("target", target).Err(err).
			Msg("Failed to walk ifPhysAddress for MAC")
	} else if mac == "" && labelErr != nil {
		e.logger.Warn().Str("job_id", jobID).Str("target", target).Err(labelErr).
			Msg("Failed to resolve interface labels for MAC identity")
	}

	return mac
}
