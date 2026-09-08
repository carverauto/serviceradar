package main

import (
	"strconv"
	"strings"
)

// This file mirrors the identity contract that core's
// ServiceRadar.Inventory.IntegrationIdentity /
// ServiceRadar.Inventory.ProxmoxEnrichmentIngestor implement, so the two
// proxmox ingestion paths (the device_discovery envelope this plugin emits and
// the proxmox_enrichment details the same result carries) mint the SAME stable,
// cluster-scoped integration identity and reconcile into ONE device instead of
// fragmenting into a name-keyed duplicate.
//
// Identity must stay behavioral: a distinct MAC is distinct hardware. We never
// bridge on a bare guest name (names are not unique across clusters); guest
// convergence keys on the cluster-scoped vmid and the NIC MAC(s) instead.

const proxmoxV2Prefix = "proxmox:v2:"

// proxmoxClusterName returns the Proxmox cluster name carried by the
// cluster-status entry of type "cluster". Mirrors the enrichment ingestor's
// cluster_record (name || id || "proxmox"). Returns "" when the slice has no
// cluster entry — i.e. a standalone node, or a failed cluster-status fetch.
func proxmoxClusterName(cluster []proxmoxClusterNode) string {
	for _, member := range cluster {
		if strings.EqualFold(strings.TrimSpace(member.Type), "cluster") {
			return firstNonEmpty(member.Name, member.ID, "proxmox")
		}
	}

	return ""
}

// clusterScopeName resolves the v2 identity scope for an object hosted on
// nodeName, mirroring ProxmoxEnrichmentIngestor.cluster_scope/scope_for:
//
//   - a named cluster              -> the cluster name
//   - a standalone node            -> the node name
//   - cluster-status fetch failed  -> "" so no unstable v2 id is minted
//     (we cannot tell standalone from clustered, so fall back to the
//     provider ref rather than risk a node-scoped id for a clustered guest)
//
// Keeping this identical to the enrichment path is what lets both proxmox
// ingestion paths converge on one device.
func clusterScopeName(cluster []proxmoxClusterNode, warnings map[string]string, nodeName string) string {
	if name := proxmoxClusterName(cluster); name != "" {
		return name
	}

	if warnings != nil {
		if _, failed := warnings["cluster_status"]; failed {
			return ""
		}
	}

	return strings.TrimSpace(nodeName)
}

// proxmoxSegment normalizes a v2 identifier segment: trim, downcase, and
// collapse runs of ':'/whitespace to a single '-'. Matches
// IntegrationIdentity.segment/1 so case/format churn cannot rotate the id.
func proxmoxSegment(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return ""
	}

	var b strings.Builder
	prevHyphen := false

	for _, r := range value {
		if r == ':' || isProxmoxSpace(r) {
			if !prevHyphen {
				b.WriteByte('-')
				prevHyphen = true
			}

			continue
		}

		b.WriteRune(r)
		prevHyphen = false
	}

	return b.String()
}

func isProxmoxSpace(r rune) bool {
	switch r {
	case ' ', '\t', '\n', '\r', '\f', '\v':
		return true
	default:
		return false
	}
}

// proxmoxGuestKindV2 maps a Proxmox guest type to the v2 kind segment
// (vm | lxc). Matches IntegrationIdentity.proxmox_guest_kind/1.
func proxmoxGuestKindV2(guestType string) string {
	switch strings.ToLower(strings.TrimSpace(guestType)) {
	case "qemu", "vm":
		return "vm"
	case "lxc", "container":
		return "lxc"
	case "":
		return ""
	default:
		return proxmoxSegment(guestType)
	}
}

// proxmoxGuestV2ID mints the cluster-scoped v2 integration id for a guest, or
// "" when any keying segment is missing. vmid must be >= 1: a zero vmid is the
// unset zero value and minting `...:<kind>:0` for several such guests would
// collapse them, so we decline instead.
func proxmoxGuestV2ID(scope, guestType string, vmid int) string {
	scopeSeg := proxmoxSegment(scope)
	kind := proxmoxGuestKindV2(guestType)

	if scopeSeg == "" || kind == "" || vmid < 1 {
		return ""
	}

	return proxmoxV2Prefix + scopeSeg + ":" + kind + ":" + strconv.Itoa(vmid)
}

// proxmoxNodeV2ID mints the cluster-scoped v2 integration id for a node, or ""
// when a segment is missing.
func proxmoxNodeV2ID(scope, node string) string {
	scopeSeg := proxmoxSegment(scope)
	nodeSeg := proxmoxSegment(node)

	if scopeSeg == "" || nodeSeg == "" {
		return ""
	}

	return proxmoxV2Prefix + scopeSeg + ":node:" + nodeSeg
}

// proxmoxGuestProviderRef is the current-gen provider ref for a guest. It is
// node+vmid scoped (unique), used as the integration_id fallback when the
// cluster scope is unknown, mirroring the enrichment provider_ref.
func proxmoxGuestProviderRef(guest proxmoxResource) string {
	guestType := strings.TrimSpace(guest.Type)
	if guestType == "" {
		guestType = "guest"
	}

	return "proxmox:guest:" + strings.TrimSpace(guest.Node) + ":" + guestType + ":" + strconv.Itoa(guest.VMID)
}

// proxmoxGuestIntegrationID returns the canonical integration_id for a guest:
// the cluster-scoped v2 id when the scope is known, else the node+vmid scoped
// provider ref. Returns "" when neither can be formed (no node / no vmid), in
// which case the ingestor falls back to its own (name-based) minting.
func proxmoxGuestIntegrationID(guest proxmoxResource, scope string) string {
	if v2 := proxmoxGuestV2ID(scope, guest.Type, guest.VMID); v2 != "" {
		return v2
	}

	if strings.TrimSpace(guest.Node) == "" || guest.VMID < 1 {
		return ""
	}

	return proxmoxGuestProviderRef(guest)
}

// proxmoxNodeIntegrationID returns the canonical integration_id for a node: the
// v2 id when the scope is known, else the provider ref (proxmox:node:<node>).
func proxmoxNodeIntegrationID(nodeName, scope string) string {
	if v2 := proxmoxNodeV2ID(scope, nodeName); v2 != "" {
		return v2
	}

	nodeName = strings.TrimSpace(nodeName)
	if nodeName == "" {
		return ""
	}

	return "proxmox:node:" + nodeName
}

// proxmoxGuestLegacyIDs produces the lookup-only legacy integration_id bridges
// for a guest so a device created before this identity change still resolves
// (no duplicate is minted). These are consulted at lookup time and must never
// be registered as new identifiers.
//
// Only vmid-scoped and MAC-keyed forms are emitted. The pure guest-name form
// (proxmox:<prefix>:<name>) is deliberately omitted: guest names are not unique
// across clusters, so bridging on a bare name could collapse distinct guests.
// Convergence with a pre-change name-keyed row instead happens through the
// shared NIC MAC (the plugin now emits every configured MAC) and the vmid
// forms; the enrichment path retains the name bridge for the narrow rename
// case.
func proxmoxGuestLegacyIDs(guest proxmoxResource, integrationID string, macs []string) []string {
	kind := proxmoxGuestKindV2(guest.Type)
	if kind == "" {
		kind = "guest"
	}

	namePrefix := proxmoxLegacyNamePrefix(kind)
	rawType := proxmoxRawGuestType(guest.Type, kind)
	vmid := guest.VMID
	node := strings.TrimSpace(guest.Node)

	guestID := strings.TrimSpace(guest.ID)
	if guestID == "" && vmid >= 1 {
		guestID = rawType + "/" + strconv.Itoa(vmid)
	}

	var out []string

	if node != "" && vmid >= 1 {
		out = append(out, proxmoxGuestProviderRef(guest))
	}

	if vmid >= 1 {
		types := uniqueStrings([]string{rawType, kind, namePrefix})
		vmidStr := strconv.Itoa(vmid)

		if node != "" {
			for _, t := range types {
				out = append(out,
					"proxmox:guest:"+node+":"+t+":"+vmidStr,
					"proxmox:"+t+":"+node+":"+vmidStr,
				)
			}
		}

		for _, t := range types {
			out = append(out, "proxmox:"+t+":"+vmidStr)
		}
	}

	// Gen-1 fallback where the raw resource id was the name (proxmox:vm:qemu/100).
	// vmid-scoped, so safe.
	if guestID != "" {
		out = append(out, "proxmox:"+namePrefix+":"+guestID)
	}

	// Gen-2 MAC-keyed ids (proxmox:vm:BC:24:11:...). Colon-separated uppercase.
	for _, mac := range macs {
		if colon := normalizeMACForOutput(mac); colon != "" {
			out = append(out, "proxmox:"+namePrefix+":"+colon)
		}
	}

	return dedupeExcluding(out, integrationID)
}

// proxmoxNodeLegacyIDs produces the lookup-only legacy integration_id bridges
// for a node. A node's identity is inherently name-based (there is no vmid), so
// these are node-name forms; over-merge protection for nodes comes from the
// distinct host NIC MACs the plugin now emits plus DIRE's merge guards.
func proxmoxNodeLegacyIDs(nodeName, targetHostname, integrationID string) []string {
	names := uniqueStrings([]string{strings.TrimSpace(nodeName), strings.TrimSpace(targetHostname)})

	var out []string
	for _, name := range names {
		out = append(out,
			"proxmox:node:"+name,
			"proxmox:pve:"+name,
			"proxmox:hypervisor:"+name,
		)
	}

	return dedupeExcluding(out, integrationID)
}

func proxmoxLegacyNamePrefix(kind string) string {
	switch kind {
	case "lxc":
		return "container"
	case "vm":
		return "vm"
	default:
		return kind
	}
}

func proxmoxRawGuestType(guestType, kind string) string {
	switch strings.ToLower(strings.TrimSpace(guestType)) {
	case "qemu", "vm":
		return "qemu"
	case "lxc", "container":
		return "lxc"
	default:
		return proxmoxDefaultRawType(kind)
	}
}

func proxmoxDefaultRawType(kind string) string {
	switch kind {
	case "vm":
		return "qemu"
	case "lxc":
		return "lxc"
	default:
		return kind
	}
}

// configuredGuestMACs returns the MACs of a guest's CONFIGURED NICs
// (net0/net1...) in canonical colon-uppercase form. Only configured NICs are
// used for identity: the guest agent also reports CNI/overlay interfaces
// (cali*, vxlan, ee:ee:ee:ee:ee:ee) whose locally-administered / ephemeral MACs
// would risk collapsing distinct guests. The stable proxmox-assigned NIC MAC is
// what the in-guest agent also reports, so it drives a correct behavioral merge.
func configuredGuestMACs(interfaces []proxmoxGuestNetworkInterface) []string {
	seen := make(map[string]bool)

	var out []string
	for _, iface := range interfaces {
		if iface.ConfigKey == "" {
			continue
		}

		mac := normalizeMACForOutput(iface.MACAddress)
		if mac == "" || seen[mac] {
			continue
		}

		seen[mac] = true
		out = append(out, mac)
	}

	return out
}

// nodeManagementMACs returns the MACs of a node's configured host NICs
// (physical, bond, bridge) from /nodes/{node}/network. That endpoint returns
// the persistent interface config, never ephemeral per-VM tap devices, so these
// MACs are the host's stable hardware identity — the same NICs the on-host agent
// reports, letting the proxmox node row reconcile with the agent's device row.
func nodeManagementMACs(node proxmoxNode) []string {
	seen := make(map[string]bool)

	var out []string
	for _, iface := range node.Network {
		mac := normalizeMACForOutput(iface.MACAddress)
		if mac == "" || seen[mac] {
			continue
		}

		seen[mac] = true
		out = append(out, mac)
	}

	return out
}

// proxmoxDeviceMetadata assembles the identity metadata a discovered device
// carries: the canonical integration_id, lookup-only legacy bridges, and the
// full MAC set. Returns nil when there is nothing to emit so the device omits
// the metadata object entirely.
func proxmoxDeviceMetadata(integrationID string, legacyIDs, macs []string) map[string]any {
	metadata := make(map[string]any)

	if integrationID != "" {
		metadata["integration_id"] = integrationID
	}

	if len(legacyIDs) > 0 {
		metadata["legacy_integration_ids"] = legacyIDs
	}

	if len(macs) > 0 {
		metadata["mac_addresses"] = macs
	}

	if len(metadata) == 0 {
		return nil
	}

	return metadata
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]bool)

	var out []string
	for _, v := range values {
		if v == "" || seen[v] {
			continue
		}

		seen[v] = true
		out = append(out, v)
	}

	return out
}

func dedupeExcluding(values []string, exclude string) []string {
	seen := make(map[string]bool)

	var out []string
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v == "" || v == exclude || seen[v] {
			continue
		}

		seen[v] = true
		out = append(out, v)
	}

	return out
}
