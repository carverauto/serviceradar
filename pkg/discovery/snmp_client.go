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
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gosnmp/gosnmp"
)

// SystemInfo holds system-level information from SNMP.
type SystemInfo struct {
	SysDescr    string
	SysObjectID string
	SysName     string
	SysUpTime   uint32
	SysContact  string
	SysLocation string
}

// GetSystemInfo retrieves system information from the device.
func (sc *snmp.SNMPClientImpl) GetSystemInfo(ctx context.Context, client snmp.SNMPClient) (SystemInfo, error) {
	oids := []string{
		"1.3.6.1.2.1.1.1.0", // sysDescr
		"1.3.6.1.2.1.1.2.0", // sysObjectID
		"1.3.6.1.2.1.1.5.0", // sysName
		"1.3.6.1.2.1.1.3.0", // sysUpTime
		"1.3.6.1.2.1.1.4.0", // sysContact
		"1.3.6.1.2.1.1.6.0", // sysLocation
	}

	result, err := client.Get(oids)
	if err != nil {
		return SystemInfo{}, fmt.Errorf("failed to get system info: %w", err)
	}

	var sysInfo SystemInfo
	for oid, value := range result {
		switch oid {
		case "1.3.6.1.2.1.1.1.0":
			if s, ok := value.(string); ok {
				sysInfo.SysDescr = s
			}
		case "1.3.6.1.2.1.1.2.0":
			if s, ok := value.(string); ok {
				sysInfo.SysObjectID = s
			}
		case "1.3.6.1.2.1.1.5.0":
			if s, ok := value.(string); ok {
				sysInfo.SysName = s
			}
		case "1.3.6.1.2.1.1.3.0":
			if t, ok := value.(time.Duration); ok {
				sysInfo.SysUpTime = uint32(t / time.Second)
			}
		case "1.3.6.1.2.1.1.4.0":
			if s, ok := value.(string); ok {
				sysInfo.SysContact = s
			}
		case "1.3.6.1.2.1.1.6.0":
			if s, ok := value.(string); ok {
				sysInfo.SysLocation = s
			}
		}
	}

	return sysInfo, nil
}

// GetInterfaces retrieves interface information from the device.
func (sc *snmp.SNMPClientImpl) GetInterfaces(ctx context.Context, client snmp.SNMPClient) ([]models.DiscoveredInterface, error) {
	var interfaces []models.DiscoveredInterface

	oids := []string{
		"1.3.6.1.2.1.2.2.1.1",     // ifIndex
		"1.3.6.1.2.1.2.2.1.2",     // ifDescr
		"1.3.6.1.2.1.31.1.1.1.1",  // ifName
		"1.3.6.1.2.1.31.1.1.1.18", // ifAlias
		"1.3.6.1.2.1.2.2.1.5",     // ifSpeed
		"1.3.6.1.2.1.2.2.1.6",     // ifPhysAddress
		"1.3.6.1.2.1.2.2.1.7",     // ifAdminStatus
		"1.3.6.1.2.1.2.2.1.8",     // ifOperStatus
	}

	results, err := sc.bulkWalkAll(ctx, client, oids[0])
	if err != nil {
		return nil, fmt.Errorf("failed to walk interfaces: %w", err)
	}

	ifaceMap := make(map[int]*models.DiscoveredInterface)
	for _, result := range results {
		parts := strings.Split(result.Name, ".")
		if len(parts) == 0 {
			continue
		}
		ifIndex := atoi(parts[len(parts)-1])
		if ifIndex == 0 {
			continue
		}

		if _, exists := ifaceMap[ifIndex]; !exists {
			ifaceMap[ifIndex] = &models.DiscoveredInterface{
				Timestamp: time.Now(),
				AgentID:   "agent-1",  // Replace with actual agent ID
				PollerID:  "poller-1", // Replace with actual poller ID
				DeviceIP:  sc.target.Host,
				IfIndex:   ifIndex,
				Metadata:  make(map[string]interface{}),
			}
		}

		iface := ifaceMap[ifIndex]
		switch {
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.2.2.1.2"):
			if s, ok := result.Value.(string); ok {
				iface.IfDescr = s
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.31.1.1.1.1"):
			if s, ok := value.(string); ok {
				iface.IfName = s
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.31.1.1.1.18"):
			if s, ok := value.(string); ok {
				iface.IfAlias = s
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.2.2.1.5"):
			if v, ok := value.(uint64); ok {
				iface.IfSpeed = int64(v)
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.2.2.1.6"):
			if b, ok := value.([]byte); ok {
				iface.IfPhysAddress = net.HardwareAddr(b).String()
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.2.2.1.7"):
			if v, ok := value.(int); ok {
				iface.IfAdminStatus = v
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.2.1.2.2.1.8"):
			if v, ok := value.(int); ok {
				iface.IfOperStatus = v
			}
		}
	}

	for _, iface := range ifaceMap {
		interfaces = append(interfaces, *iface)
	}

	return interfaces, nil
}

// GetIPAddresses retrieves IP address mappings for interfaces.
func (sc *snmp.SNMPClientImpl) GetIPAddresses(ctx context.Context, client snmp.SNMPClient) (map[int][]string, error) {
	ipAddrs := make(map[int][]string)

	results, err := sc.bulkWalkAll(ctx, client, "1.3.6.1.2.1.4.20.1.2") // ipAdEntIfIndex
	if err != nil {
		return nil, fmt.Errorf("failed to walk IP addresses: %w", err)
	}

	for _, result := range results {
		parts := strings.Split(result.Name, ".")
		if len(parts) < 2 {
			continue
		}
		ifIndex := atoi(parts[len(parts)-1])
		if ifIndex == 0 {
			continue
		}

		addrOID := "1.3.6.1.2.1.4.20.1.1." + strings.Join(parts[len(parts)-4:], ".")
		addrResults, err := client.Get([]string{addrOID})
		if err != nil {
			continue
		}
		for _, value := range addrResults {
			if ip, ok := value.(string); ok && net.ParseIP(ip) != nil {
				ipAddrs[ifIndex] = append(ipAddrs[ifIndex], ip)
			}
		}
	}

	return ipAddrs, nil
}

// GetLLDPNeighbors retrieves LLDP neighbor information.
func (sc *snmp.SNMPClientImpl) GetLLDPNeighbors(ctx context.Context, client snmp.SNMPClient) ([]models.TopologyDiscoveryEvent, error) {
	var neighbors []models.TopologyDiscoveryEvent

	oids := []string{
		"1.0.8802.1.1.2.1.4.1.1.5", // lldpRemChassisId
		"1.0.8802.1.1.2.1.4.1.1.7", // lldpRemPortId
		"1.0.8802.1.1.2.1.4.1.1.8", // lldpRemPortDesc
		"1.0.8802.1.1.2.1.4.1.1.9", // lldpRemSysName
		"1.0.8802.1.1.2.1.4.2.1.3", // lldpRemManAddr
	}

	results, err := sc.bulkWalkAll(ctx, client, oids[0])
	if err != nil {
		return nil, fmt.Errorf("failed to walk LLDP neighbors: %w", err)
	}

	neighborMap := make(map[string]*models.TopologyDiscoveryEvent)
	for _, result := range results {
		parts := strings.Split(result.Name, ".")
		if len(parts) < 2 {
			continue
		}
		key := strings.Join(parts[len(parts)-2:], ".") // Use localIfIndex and remoteIndex as key
		if _, exists := neighborMap[key]; !exists {
			neighborMap[key] = &models.TopologyDiscoveryEvent{
				Timestamp:     time.Now(),
				AgentID:       "agent-1",  // Replace with actual agent ID
				PollerID:      "poller-1", // Replace with actual poller ID
				LocalDeviceIP: sc.target.Host,
				ProtocolType:  "LLDP",
				Metadata:      make(map[string]interface{}),
			}
		}

		neighbor := neighborMap[key]
		switch {
		case strings.HasPrefix(result.Name, "1.0.8802.1.1.2.1.4.1.1.5"):
			if b, ok := result.Value.([]byte); ok {
				neighbor.NeighborChassisID = string(b)
			}
		case strings.HasPrefix(result.Name, "1.0.8802.1.1.2.1.4.1.1.7"):
			if s, ok := result.Value.(string); ok {
				neighbor.NeighborPortID = s
			}
		case strings.HasPrefix(result.Name, "1.0.8802.1.1.2.1.4.1.1.8"):
			if s, ok := result.Value.(string); ok {
				neighbor.NeighborPortDescr = s
			}
		case strings.HasPrefix(result.Name, "1.0.8802.1.1.2.1.4.1.1.9"):
			if s, ok := result.Value.(string); ok {
				neighbor.NeighborSystemName = s
			}
		case strings.HasPrefix(result.Name, "1.0.8802.1.1.2.1.4.2.1.3"):
			if ip, ok := result.Value.(string); ok && net.ParseIP(ip) != nil {
				neighbor.NeighborManagementAddr = ip
			}
		}
	}

	for _, neighbor := range neighborMap {
		neighbors = append(neighbors, *neighbor)
	}

	return neighbors, nil
}

// GetCDPNeighbors retrieves CDP neighbor information.
func (sc *snmp.SNMPClientImpl) GetCDPNeighbors(ctx context.Context, client snmp.SNMPClient) ([]models.TopologyDiscoveryEvent, error) {
	var neighbors []models.TopologyDiscoveryEvent

	oids := []string{
		"1.3.6.1.4.1.9.9.23.1.2.1.1.4", // cdpCacheAddress
		"1.3.6.1.4.1.9.9.23.1.2.1.1.6", // cdpCacheDeviceId
		"1.3.6.1.4.1.9.9.23.1.2.1.1.7", // cdpCacheDevicePort
	}

	results, err := sc.bulkWalkAll(ctx, client, oids[0])
	if err != nil {
		return nil, fmt.Errorf("failed to walk CDP neighbors: %w", err)
	}

	neighborMap := make(map[string]*models.TopologyDiscoveryEvent)
	for _, result := range results {
		parts := strings.Split(result.Name, ".")
		if len(parts) < 2 {
			continue
		}
		key := strings.Join(parts[len(parts)-2:], ".") // Use localIfIndex and remoteIndex as key
		if _, exists := neighborMap[key]; !exists {
			neighborMap[key] = &models.TopologyDiscoveryEvent{
				Timestamp:     time.Now(),
				AgentID:       "agent-1",  // Replace with actual agent ID
				PollerID:      "poller-1", // Replace with actual poller ID
				LocalDeviceIP: sc.target.Host,
				ProtocolType:  "CDP",
				Metadata:      make(map[string]interface{}),
			}
		}

		neighbor := neighborMap[key]
		switch {
		case strings.HasPrefix(result.Name, "1.3.6.1.4.1.9.9.23.1.2.1.1.4"):
			if ip, ok := result.Value.(string); ok && net.ParseIP(ip) != nil {
				neighbor.NeighborManagementAddr = ip
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.4.1.9.9.23.1.2.1.1.6"):
			if s, ok := result.Value.(string); ok {
				neighbor.NeighborChassisID = s
			}
		case strings.HasPrefix(result.Name, "1.3.6.1.4.1.9.9.23.1.2.1.1.7"):
			if s, ok := result.Value.(string); ok {
				neighbor.NeighborPortID = s
			}
		}
	}

	for _, neighbor := range neighborMap {
		neighbors = append(neighbors, *neighbor)
	}

	return neighbors, nil
}

// bulkWalkAll performs a bulk walk for the given OID.
func (sc *snmp.SNMPClientImpl) bulkWalkAll(ctx context.Context, client snmp.SNMPClient, rootOID string) ([]gosnmp.SnmpPDU, error) {
	var results []gosnmp.SnmpPDU
	oid := rootOID

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
			// Use GETNEXT to walk the OID tree
			resp, err := sc.client.GetNext([]string{oid})
			if err != nil {
				return nil, fmt.Errorf("failed to get next for %s: %w", oid, err)
			}
			if len(resp.Variables) == 0 {
				break
			}

			variable := resp.Variables[0]
			if !strings.HasPrefix(variable.Name, rootOID) || variable.Type == gosnmp.EndOfMibView {
				break
			}

			results = append(results, variable)
			oid = variable.Name
		}
	}

	return results, nil
}

// atoi converts a string to an integer, returning 0 on error.
func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}
