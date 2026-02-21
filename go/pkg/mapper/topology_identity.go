package mapper

import "strings"

// NormalizeTopologyLinkNeighborIdentity builds a canonical neighbor identity from
// explicit topology fields and metadata fallback keys.
func NormalizeTopologyLinkNeighborIdentity(link *TopologyLink) *TopologyNeighborIdentity {
	if link == nil {
		return nil
	}

	identity := &TopologyNeighborIdentity{
		ManagementIP: normalizeNeighborField(link.NeighborMgmtAddr),
		DeviceID:     normalizeNeighborField(link.MetadataValue("neighbor_device_id")),
		ChassisID:    normalizeNeighborField(link.NeighborChassisID),
		PortID:       normalizeNeighborField(link.NeighborPortID),
		PortDescr:    normalizeNeighborField(link.NeighborPortDescr),
		SystemName:   normalizeNeighborField(link.NeighborSystemName),
	}

	if identity.ManagementIP == "" {
		identity.ManagementIP = normalizeNeighborField(
			firstNonEmptyMetadata(link, "neighbor_mgmt_addr", "neighbor_management_address", "neighbor_ip"),
		)
	}

	if identity.DeviceID == "" {
		identity.DeviceID = normalizeNeighborField(firstNonEmptyMetadata(link, "neighbor_id", "neighbor_uid"))
	}

	if identity.ManagementIP != "" {
		link.NeighborMgmtAddr = identity.ManagementIP
	}
	if identity.ChassisID != "" {
		link.NeighborChassisID = identity.ChassisID
	}
	if identity.PortID != "" {
		link.NeighborPortID = identity.PortID
	}
	if identity.PortDescr != "" {
		link.NeighborPortDescr = identity.PortDescr
	}
	if identity.SystemName != "" {
		link.NeighborSystemName = identity.SystemName
	}

	if !identity.hasEvidence() {
		return nil
	}

	link.NeighborIdentity = identity

	return identity
}

func (t *TopologyLink) MetadataValue(key string) string {
	if t == nil || t.Metadata == nil {
		return ""
	}

	return t.Metadata[key]
}

func firstNonEmptyMetadata(link *TopologyLink, keys ...string) string {
	if link == nil || link.Metadata == nil {
		return ""
	}

	for _, key := range keys {
		if value := normalizeNeighborField(link.Metadata[key]); value != "" {
			return value
		}
	}

	return ""
}

func normalizeNeighborField(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}

	switch strings.ToLower(trimmed) {
	case "null", "nil", "undefined":
		return ""
	default:
		return trimmed
	}
}

func (n *TopologyNeighborIdentity) hasEvidence() bool {
	if n == nil {
		return false
	}

	return n.ManagementIP != "" ||
		n.DeviceID != "" ||
		n.ChassisID != "" ||
		n.PortID != "" ||
		n.PortDescr != "" ||
		n.SystemName != ""
}
