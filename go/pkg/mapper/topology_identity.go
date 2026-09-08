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
		ChassisID:    canonicalMACLabel(normalizeNeighborField(link.NeighborChassisID)),
		PortID:       canonicalMACLabel(normalizeNeighborField(link.NeighborPortID)),
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

// macHexDigits is the number of hex digits in a 48-bit MAC address.
const macHexDigits = 12

// canonicalMACLabel canonicalizes a value that is a MAC address in any common
// encoding (colon/hyphen/dot separators, mixed case, or none) to the single
// lowercase colon-separated form. LLDP/CDP neighbor port-ids and chassis-ids are
// frequently MACs in varying formats; emitting one canonical form here (at the
// source) keeps the topology graph from minting duplicate Interface vertices for
// the same physical port. Values that are not MAC-shaped (named ports such as
// "Gi1/0/24") are returned unchanged. This mirrors the core-side
// Utils.normalize_interface_label/1 defense-in-depth normalization.
func canonicalMACLabel(value string) string {
	stripped := strings.ToLower(strings.Map(func(r rune) rune {
		switch r {
		case ':', '-', '.', ' ':
			return -1
		default:
			return r
		}
	}, value))

	if len(stripped) != macHexDigits {
		return value
	}

	for _, r := range stripped {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return value
		}
	}

	var b strings.Builder
	b.Grow(macHexDigits + macHexDigits/2 - 1)

	for i := 0; i < macHexDigits; i += 2 {
		if i > 0 {
			b.WriteByte(':')
		}

		b.WriteString(stripped[i : i+2])
	}

	return b.String()
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
