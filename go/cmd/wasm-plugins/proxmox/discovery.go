package main

import (
	"net/url"
	"strings"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func addNodeDiscoveries(discovery *sdk.DeviceDiscovery, target Target, nodes []proxmoxNode) {
	for _, node := range nodes {
		available := strings.EqualFold(node.Status, "online")
		hostname := firstNonEmpty(node.Node, target.Hostname)
		deviceID := "proxmox:pve:" + node.Node
		if targetMatchesNode(target, node) {
			deviceID = firstNonEmpty(target.DeviceID, deviceID)
		}

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    deviceID,
			Hostname:    hostname,
			IP:          stripIPPrefix(node.IP),
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

func addGuestDiscoveries(discovery *sdk.DeviceDiscovery, guests []proxmoxGuest) {
	for _, guest := range guests {
		kind := normalizeGuestKind(guest.Type)
		available := strings.EqualFold(guest.Status, "running")

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
		})
	}
}
