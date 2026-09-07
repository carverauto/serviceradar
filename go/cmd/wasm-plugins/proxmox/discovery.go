package main

import (
	"net/url"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func addNodeDiscoveries(discovery *sdk.DeviceDiscovery, target Target, nodes []proxmoxNode, cluster []proxmoxClusterNode, warnings map[string]string) {
	// The /nodes API frequently omits a node's IP; cluster status carries it.
	clusterIPs := make(map[string]string, len(cluster))
	for _, member := range cluster {
		if ip := stripIPPrefix(member.IP); ip != "" && member.Name != "" {
			clusterIPs[strings.ToLower(member.Name)] = ip
		}
	}

	for _, node := range nodes {
		available := strings.EqualFold(node.Status, "online")
		hostname := firstNonEmpty(node.Node, target.Hostname)
		deviceID := "proxmox:pve:" + node.Node
		if targetMatchesNode(target, node) {
			deviceID = firstNonEmpty(target.DeviceID, deviceID)
		}

		ip := stripIPPrefix(node.IP)
		if ip == "" {
			ip = clusterIPs[strings.ToLower(node.Node)]
		}

		// Never create an address-less device: a row without an IP can't be
		// reconciled by DIRE with the same host discovered elsewhere, so it
		// lands as a useless duplicate. The node still appears in the
		// enrichment details; it just isn't emitted as a device until an IP
		// is known.
		if ip == "" {
			continue
		}

		// Emit the same cluster-scoped integration identity + host NIC MAC(s)
		// the enrichment path derives, so the two proxmox ingestion paths
		// reconcile into one device, and so the node merges with the agent's
		// own device row for the same physical host via a shared NIC MAC.
		scope := clusterScopeName(cluster, warnings, node.Node)
		integrationID := proxmoxNodeIntegrationID(node.Node, scope)
		macs := nodeManagementMACs(node)
		metadata := proxmoxDeviceMetadata(
			integrationID,
			proxmoxNodeLegacyIDs(node.Node, target.Hostname, integrationID),
			macs,
		)

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    deviceID,
			Hostname:    hostname,
			IP:          ip,
			MAC:         firstNonEmpty(macs...),
			VendorName:  "Proxmox",
			Model:       "PVE",
			Type:        "hypervisor",
			Role:        "proxmox_pve",
			Status:      node.Status,
			IsAvailable: &available,
			Labels: map[string]string{
				"provider": "proxmox",
				"role":     "pve",
			},
			Metadata: metadata,
		})
	}
}

func targetMatchesNode(target Target, node proxmoxNode) bool {
	for _, candidate := range []string{target.Hostname, hostFromURL(target.BaseURL)} {
		if sameHostOrNode(candidate, node.Node) {
			return true
		}
	}

	return false
}

func hostFromURL(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}

	return parsed.Hostname()
}

func sameHostOrNode(candidate, node string) bool {
	candidate = strings.ToLower(strings.TrimSpace(candidate))
	node = strings.ToLower(strings.TrimSpace(node))
	if candidate == "" || node == "" {
		return false
	}

	return candidate == node || strings.Split(candidate, ".")[0] == node
}

func addGuestDiscoveries(discovery *sdk.DeviceDiscovery, guests []proxmoxGuest, cluster []proxmoxClusterNode, warnings map[string]string) {
	for _, guest := range guests {
		kind := normalizeGuestKind(guest.Type)
		available := strings.EqualFold(guest.Status, "running")

		// Do not create devices for guests with no usable IP (typically
		// stopped guests with no static/cloud-init address): an address-less
		// row can't be DIRE-merged and pollutes the inventory. The guest is
		// still fully present in the enrichment details and will be emitted
		// once it runs (guest agent / LXC interfaces) or gains a configured
		// address.
		if primaryIP(guest.Interfaces) == "" {
			continue
		}

		// Emit the cluster-scoped, vmid-keyed integration identity + every
		// configured NIC MAC so this row (a) reconciles with the enrichment
		// path's row for the same guest and (b) merges with the guest's own
		// agent device row on a shared MAC — instead of fragmenting into a
		// name-keyed duplicate that rotates on rename/NIC change.
		scope := clusterScopeName(cluster, warnings, guest.Node)
		integrationID := proxmoxGuestIntegrationID(guest.proxmoxResource, scope)
		macs := configuredGuestMACs(guest.Interfaces)
		metadata := proxmoxDeviceMetadata(
			integrationID,
			proxmoxGuestLegacyIDs(guest.proxmoxResource, integrationID, macs),
			macs,
		)

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    proxmoxGuestID(guest.proxmoxResource),
			Hostname:    firstNonEmpty(guest.Name, guest.ID),
			IP:          primaryIP(guest.Interfaces),
			MAC:         primaryMAC(guest.Interfaces),
			VendorName:  "Proxmox",
			Model:       kind,
			Type:        kind,
			Role:        "proxmox_" + kind,
			Status:      guest.Status,
			IsAvailable: &available,
			Labels: map[string]string{
				"provider": "proxmox",
				"role":     kind,
			},
			Metadata: metadata,
		})
	}
}
