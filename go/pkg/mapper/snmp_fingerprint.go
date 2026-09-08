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
	"encoding/hex"

	"sort"

	"strconv"

	"strings"

	"github.com/gosnmp/gosnmp"
)

func (e *DiscoveryEngine) enrichSNMPBridgeFingerprint(
	client *gosnmp.GoSNMP, fp *SNMPFingerprint, extractionErrors map[string]string,
) {
	if client == nil || fp == nil || fp.Bridge == nil {
		return
	}

	if result, err := client.Get([]string{oidDot1dBaseNumPorts}); err == nil && result != nil {
		for _, v := range result.Variables {
			if v.Name != oidDot1dBaseNumPorts {
				continue
			}
			if !e.setInt32Value(&fp.Bridge.BridgePortCount, v) {
				if extractionErrors != nil {
					extractionErrors["bridge.base_num_ports"] = "malformed dot1dBaseNumPorts value"
				}
			}
		}
	} else if err != nil && extractionErrors != nil && !isSNMPOIDUnsupportedError(err) {
		extractionErrors["bridge.base_num_ports"] = err.Error()
	}

	var forwardingCount int32
	err := client.BulkWalk(oidDot1dStpPortState, func(pdu gosnmp.SnmpPDU) error {
		val, ok := e.getInt32FromPDU(pdu, "dot1dStpPortState")
		if !ok {
			return nil
		}
		// dot1dStpPortState forwarding(5)
		if val == 5 {
			forwardingCount++
		}
		return nil
	})
	if err != nil {
		if extractionErrors != nil && !isSNMPOIDUnsupportedError(err) {
			extractionErrors["bridge.stp_port_state"] = err.Error()
		}
	} else {
		fp.Bridge.STPForwardingPortCount = forwardingCount
	}
}

func (e *DiscoveryEngine) enrichSNMPVLANFingerprint(
	client *gosnmp.GoSNMP, fp *SNMPFingerprint, extractionErrors map[string]string,
) {
	if client == nil || fp == nil {
		return
	}

	vlanIDs := make(map[int32]struct{})
	pvidDistribution := make(map[int32]int32)
	portEvidence := make(map[int32]*SNMPVLANPortEvidence)
	foundAny := false

	err := client.BulkWalk(oidDot1qPvid, func(pdu gosnmp.SnmpPDU) error {
		pvid, ok := e.getInt32FromPDU(pdu, "dot1qPvid")
		if !ok {
			return nil
		}
		pvidDistribution[pvid]++
		vlanIDs[pvid] = struct{}{}
		foundAny = true
		return nil
	})
	if err != nil && extractionErrors != nil && !isSNMPOIDUnsupportedError(err) {
		extractionErrors["vlan.pvid_distribution"] = err.Error()
	}

	collectPortEvidence := func(rootOID string, update func(ev *SNMPVLANPortEvidence, hexValue string)) {
		walkErr := client.BulkWalk(rootOID, func(pdu gosnmp.SnmpPDU) error {
			if pdu.Type != gosnmp.OctetString {
				return nil
			}
			raw, ok := pdu.Value.([]byte)
			if !ok {
				return nil
			}
			vlanID, ok := parseVLANIDFromOID(pdu.Name)
			if !ok {
				return nil
			}
			vlanIDs[vlanID] = struct{}{}
			ev, exists := portEvidence[vlanID]
			if !exists {
				ev = &SNMPVLANPortEvidence{VLANID: vlanID}
				portEvidence[vlanID] = ev
			}
			update(ev, bytesToHexString(raw))
			foundAny = true
			return nil
		})
		if walkErr != nil && extractionErrors != nil && !isSNMPOIDUnsupportedError(walkErr) {
			extractionErrors["vlan."+rootOID] = walkErr.Error()
		}
	}

	collectPortEvidence(oidDot1qVlanStaticEgress, func(ev *SNMPVLANPortEvidence, hexValue string) {
		ev.EgressPortsHex = hexValue
	})
	collectPortEvidence(oidDot1qVlanStaticUntagged, func(ev *SNMPVLANPortEvidence, hexValue string) {
		ev.UntaggedPortsHex = hexValue
	})

	// Fall back to current egress table when static tables are unavailable.
	if len(portEvidence) == 0 {
		collectPortEvidence(oidDot1qVlanCurrentEgress, func(ev *SNMPVLANPortEvidence, hexValue string) {
			ev.EgressPortsHex = hexValue
		})
	}

	if !foundAny {
		return
	}

	vlan := &SNMPVLANFingerprint{}
	for id := range vlanIDs {
		vlan.VLANIDsSeen = append(vlan.VLANIDsSeen, id)
	}
	sort.Slice(vlan.VLANIDsSeen, func(i, j int) bool {
		return vlan.VLANIDsSeen[i] < vlan.VLANIDsSeen[j]
	})

	for pvid, count := range pvidDistribution {
		vlan.PVIDDistribution = append(vlan.PVIDDistribution, SNMPPVIDCount{
			PVID:  pvid,
			Count: count,
		})
	}
	sort.Slice(vlan.PVIDDistribution, func(i, j int) bool {
		return vlan.PVIDDistribution[i].PVID < vlan.PVIDDistribution[j].PVID
	})

	for _, vlanID := range vlan.VLANIDsSeen {
		if ev, ok := portEvidence[vlanID]; ok {
			vlan.PortEvidence = append(vlan.PortEvidence, *ev)
		}
	}

	fp.VLAN = vlan
}

func isSNMPOIDUnsupportedError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "no such name") ||
		strings.Contains(msg, "nosuchname") ||
		strings.Contains(msg, "no such object") ||
		strings.Contains(msg, "nosuchobject") ||
		strings.Contains(msg, "no such instance") ||
		strings.Contains(msg, "nosuchinstance") ||
		strings.Contains(msg, "unknown object identifier")
}

func isSNMPPacketUnsupportedError(err gosnmp.SNMPError) bool {
	msg := strings.ToLower(err.String())
	return strings.Contains(msg, "no such name") ||
		strings.Contains(msg, "nosuchname") ||
		strings.Contains(msg, "no such object") ||
		strings.Contains(msg, "nosuchobject") ||
		strings.Contains(msg, "no such instance") ||
		strings.Contains(msg, "nosuchinstance")
}

func isSNMPPacketNoDataError(err gosnmp.SNMPError) bool {
	return err == gosnmp.AuthorizationError
}

func parseVLANIDFromOID(oid string) (int32, bool) {
	if oid == "" {
		return 0, false
	}
	parts := strings.Split(strings.TrimPrefix(oid, "."), ".")
	if len(parts) == 0 {
		return 0, false
	}
	last := parts[len(parts)-1]
	id64, err := strconv.ParseInt(last, 10, 32)
	if err != nil {
		return 0, false
	}
	return int32(id64), true
}

func bytesToHexString(raw []byte) string {
	if len(raw) == 0 {
		return ""
	}
	return strings.ToUpper(hex.EncodeToString(raw))
}

func snmpStringValue(v gosnmp.SnmpPDU) (string, bool) {
	if v.Type != gosnmp.OctetString && v.Type != gosnmp.ObjectDescription {
		return "", false
	}

	switch val := v.Value.(type) {
	case []byte:
		return string(val), true
	case string:
		return val, true
	}

	return "", false
}

func snmpObjectIDValue(v gosnmp.SnmpPDU) (string, bool) {
	if v.Type != gosnmp.ObjectIdentifier {
		return "", false
	}
	switch val := v.Value.(type) {
	case string:
		return val, true
	case []byte:
		return string(val), true
	}
	return "", false
}

func snmpFieldKeyForOID(oid string) string {
	switch oid {
	case oidSysDescr:
		return "system.sys_descr"
	case oidSysObjectID:
		return "system.sys_object_id"
	case oidSysUptime:
		return "system.uptime"
	case oidSysContact:
		return "system.sys_contact"
	case oidSysName:
		return "system.sys_name"
	case oidSysLocation:
		return "system.sys_location"
	case oidIPForwarding:
		return "system.ip_forwarding"
	case oidDot1dBaseBridgeAddress:
		return "bridge.base_mac"
	default:
		return ""
	}
}

// queryInterfaces queries interface information via SNMP
