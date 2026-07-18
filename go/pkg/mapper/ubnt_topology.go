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
	"time"
)

// processLLDPTable processes LLDP table entries and creates topology links
func (*DiscoveryEngine) processLLDPTable(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	details *UniFiDeviceDetails,
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	lldpEntries := details.normalizedLLDPTable()
	links := make([]*TopologyLink, 0, len(lldpEntries))

	for i := range lldpEntries {
		entry := &lldpEntries[i]
		link := &TopologyLink{
			Protocol:           "LLDP",
			LocalDeviceIP:      device.IPAddress,
			LocalDeviceID:      deviceID,
			LocalIfIndex:       entry.ifIndex(),
			LocalIfName:        entry.ifName(),
			NeighborChassisID:  entry.chassisID(),
			NeighborPortID:     entry.portID(),
			NeighborPortDescr:  entry.portDescr(),
			NeighborSystemName: entry.systemName(),
			NeighborMgmtAddr:   entry.mgmtAddr(),
			Metadata: map[string]string{
				"discovery_id":    job.ID,
				"discovery_time":  time.Now().Format(time.RFC3339),
				"source":          "unifi-api-lldp",
				"evidence_class":  evidenceClassDirectPhysical,
				"relation_family": "CONNECTS_TO",
				"controller_url":  apiConfig.BaseURL,
				"site_id":         site.ID,
				"site_name":       site.Name,
				"controller_name": apiConfig.Name,
			},
		}
		applyUniFiDetailAdapterMetadata(link.Metadata, details)

		links = append(links, link)
	}

	return links
}

// processPortTable processes port table entries and creates topology links
func (*DiscoveryEngine) processPortTable(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	details *UniFiDeviceDetails,
	deviceCache map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	var links []*TopologyLink

	portEntries := details.normalizedPortTable()
	for i := range portEntries {
		port := &portEntries[i]
		peer := port.connected()
		peerMAC := peer.mac()
		peerIP := peer.ip()
		peerName := peer.Name
		peerDeviceID := peer.deviceID()
		if peerDeviceID != "" && (peerMAC == "" || peerIP == "" || strings.TrimSpace(peerName) == "") {
			if cached, exists := deviceCache[peerDeviceID]; exists {
				if peerMAC == "" {
					peerMAC = cached.MAC
				}
				if peerIP == "" {
					peerIP = cached.IP
				}
				if strings.TrimSpace(peerName) == "" {
					peerName = cached.Name
				}
			}
		}

		if peerMAC != "" || peerIP != "" {
			link := &TopologyLink{
				Protocol:           "UniFi-API",
				LocalDeviceIP:      device.IPAddress,
				LocalDeviceID:      deviceID,
				LocalIfIndex:       port.ifIndex(),
				LocalIfName:        port.Name,
				NeighborChassisID:  peerMAC,
				NeighborSystemName: peerName,
				NeighborMgmtAddr:   peerIP,
				Metadata: map[string]string{
					"discovery_id":    job.ID,
					"discovery_time":  time.Now().Format(time.RFC3339),
					"source":          "unifi-api-port-table",
					"evidence_class":  evidenceClassInferredSegment,
					"relation_family": "ATTACHED_TO",
					"controller_url":  apiConfig.BaseURL,
					"site_id":         site.ID,
					"site_name":       site.Name,
					"controller_name": apiConfig.Name,
					"neighbor_id":     peerDeviceID,
				},
			}
			applyUniFiDetailAdapterMetadata(link.Metadata, details)

			links = append(links, link)
		}
	}

	return links
}

func (*DiscoveryEngine) processWirelessClientAssociations(
	job *DiscoveryJob,
	clients []UniFiClient,
	deviceCache map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	links := make([]*TopologyLink, 0, len(clients))

	for i := range clients {
		client := clients[i]
		uplinkID := client.normalizedUplinkDeviceID()
		if uplinkID == "" {
			continue
		}

		ap, exists := deviceCache[uplinkID]
		if !exists || strings.TrimSpace(ap.IP) == "" || strings.TrimSpace(ap.DeviceID) == "" {
			continue
		}

		clientMAC := client.normalizedMAC()
		if clientMAC == "" {
			continue
		}

		metadata := map[string]string{
			"discovery_id":      job.ID,
			"discovery_time":    time.Now().Format(time.RFC3339),
			"source":            "unifi-api-wireless-client",
			"evidence_class":    "endpoint-attachment",
			"relation_type":     "ATTACHED_TO",
			"relation_family":   "ATTACHED_TO",
			"confidence_tier":   confidenceTierHigh,
			"confidence_reason": "controller_client_association",
			"controller_url":    apiConfig.BaseURL,
			"site_id":           site.ID,
			"site_name":         site.Name,
			"controller_name":   apiConfig.Name,
			"unifi_client_id":   strings.TrimSpace(client.ID),
			"client_type":       client.normalizedType(),
			"uplink_device_id":  uplinkID,
		}
		if accessType := client.Access.normalizedType(); accessType != "" {
			metadata["access_type"] = accessType
		}
		if connectedAt := strings.TrimSpace(client.ConnectedAt); connectedAt != "" {
			metadata["connected_at"] = connectedAt
		}

		links = append(links, &TopologyLink{
			Protocol:           "UniFi-API",
			LocalDeviceIP:      strings.TrimSpace(ap.IP),
			LocalDeviceID:      strings.TrimSpace(ap.DeviceID),
			LocalIfName:        "wireless",
			NeighborChassisID:  clientMAC,
			NeighborSystemName: client.normalizedName(),
			NeighborMgmtAddr:   client.normalizedIP(),
			Metadata:           metadata,
		})
	}

	return links
}

// processWiredClientAssociations mirrors processWirelessClientAssociations for
// WIRED clients from the Integration v1 /clients endpoint.
//
// Per-port wired detail requires the legacy stat/device port_table[].mac_table[]
// payload, which is owned by add-unifi-wifi-discovery-parity; this change emits
// switch-level attachment from Integration v1 /clients only and deliberately
// adds no /stat/sta fetch. When a controller payload does carry an uplink port
// index, the link is emitted per-port at full confidence.
func (*DiscoveryEngine) processWiredClientAssociations(
	job *DiscoveryJob,
	clients []UniFiClient,
	deviceCache map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	links := make([]*TopologyLink, 0, len(clients))

	for i := range clients {
		client := clients[i]
		uplinkID := client.normalizedUplinkDeviceID()
		if uplinkID == "" {
			continue
		}

		sw, exists := deviceCache[uplinkID]
		if !exists || strings.TrimSpace(sw.IP) == "" || strings.TrimSpace(sw.DeviceID) == "" {
			continue
		}

		clientMAC := client.normalizedMAC()
		if clientMAC == "" {
			continue
		}

		// applyTopologyEvidenceClass defaults endpoint-attachment to "high"
		// when the tier is unset, so the reduced switch-level tier must be
		// stamped explicitly here.
		confidenceTier := confidenceTierMedium
		confidenceReason := "controller_wired_client_switch_level"
		var localIfIndex int32
		if client.uplinkPortIndexPresent() {
			localIfIndex = client.uplinkPortIndex()
			confidenceTier = confidenceTierHigh
			confidenceReason = "controller_client_association"
		}

		metadata := map[string]string{
			"discovery_id":      job.ID,
			"discovery_time":    time.Now().Format(time.RFC3339),
			"source":            "unifi-api-wired-client",
			"evidence_class":    "endpoint-attachment",
			"relation_type":     "ATTACHED_TO",
			"relation_family":   "ATTACHED_TO",
			"confidence_tier":   confidenceTier,
			"confidence_reason": confidenceReason,
			"controller_url":    apiConfig.BaseURL,
			"site_id":           site.ID,
			"site_name":         site.Name,
			"controller_name":   apiConfig.Name,
			"unifi_client_id":   strings.TrimSpace(client.ID),
			"client_type":       client.normalizedType(),
			"uplink_device_id":  uplinkID,
		}
		if swMAC := client.normalizedUplinkDeviceMAC(); swMAC != "" {
			metadata["uplink_device_mac"] = swMAC
		}
		if accessType := client.Access.normalizedType(); accessType != "" {
			metadata["access_type"] = accessType
		}
		if connectedAt := strings.TrimSpace(client.ConnectedAt); connectedAt != "" {
			metadata["connected_at"] = connectedAt
		}

		// LocalIfName is left empty so resolveLocalInterfaceName binds the
		// interface scan's "Port-N" vertex when a port index is known.
		links = append(links, &TopologyLink{
			Protocol:           "UniFi-API",
			LocalDeviceIP:      strings.TrimSpace(sw.IP),
			LocalDeviceID:      strings.TrimSpace(sw.DeviceID),
			LocalIfIndex:       localIfIndex,
			NeighborChassisID:  clientMAC,
			NeighborSystemName: client.normalizedName(),
			NeighborMgmtAddr:   client.normalizedIP(),
			Metadata:           metadata,
		})
	}

	return links
}

// processUplinkInfo processes uplink information and creates topology links
func (*DiscoveryEngine) processUplinkInfo(
	job *DiscoveryJob,
	device *UniFiDevice,
	details *UniFiDeviceDetails,
	deviceCache map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	var links []*TopologyLink

	uplinkInfo := device.Uplink
	if uplinkInfo.upstreamDeviceID() == "" && details != nil {
		uplinkInfo = details.Uplink
	}

	if uplinkID := uplinkInfo.upstreamDeviceID(); uplinkID != "" {
		if uplink, exists := deviceCache[uplinkID]; exists {
			localIfIndex := uplinkInfo.parentPortIndex()
			localIfName := uplinkInfo.parentPortName()
			if localIfName == "" && uplinkInfo.parentPortIndexPresent() {
				localIfName = fmt.Sprintf("Port %d", localIfIndex)
			}

			link := &TopologyLink{
				Protocol:           "UniFi-API",
				LocalDeviceIP:      uplink.IP,
				LocalDeviceID:      uplink.DeviceID,
				LocalIfIndex:       localIfIndex,
				LocalIfName:        localIfName,
				NeighborChassisID:  device.MAC,
				NeighborSystemName: device.Name,
				NeighborMgmtAddr:   device.IPAddress,
				Metadata: map[string]string{
					"discovery_id":       job.ID,
					"discovery_time":     time.Now().Format(time.RFC3339),
					"source":             "unifi-api-uplink",
					"evidence_class":     evidenceClassDirectPhysical,
					"relation_family":    "CONNECTS_TO",
					"controller_url":     apiConfig.BaseURL,
					"site_id":            site.ID,
					"site_name":          site.Name,
					"controller_name":    apiConfig.Name,
					"uplink_device_id":   uplinkID,
					"uplink_device_name": uplink.Name,
				},
			}
			applyUniFiDetailAdapterMetadata(link.Metadata, details)
			links = append(links, link)
		}
	}

	return links
}
