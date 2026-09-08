package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Identity emission for AWX-discovered hosts.
//
// Two separate concerns live here, and conflating them is the mistake this file
// exists to avoid:
//
//   - awxIntegrationID is a SOURCE KEY. It makes an AWX host addressable and
//     stable across renames. It is deliberately scoped to the controller, and it
//     will never cross-link an AWX host to the same machine discovered by an
//     agent or by Proxmox. That is correct: a database primary key is not
//     evidence about hardware.
//   - awxHostMACs is HARDWARE EVIDENCE. A MAC that AWX already knows is the same
//     NIC the in-guest agent reports, so it merges the two rows behaviorally.
//
// What must never be added here is a lookup that finds a device with a matching
// hostname and borrows its MAC. That would mint a `:mac` identifier
// indistinguishable from a real observation and defeat the distinct-MAC veto
// that exists to keep separate hardware separate.

// awxIntegrationID builds the canonical source key for an AWX host.
//
// Without this the ingestor mints its own key: `prefixed_identifier/2` walks
// serial -> stable hardware id -> hostname -> MAC, and since this plugin emits
// none of the others it lands on the hostname, producing `awx:host:<name>`.
// That key is scoped by source and kind only, so two different machines named
// `pve01` on two different controllers mint the SAME identifier and collapse
// into one device.
//
// (controller_id, host_id) is AWX's own primary key: immutable across renames
// and re-IPs, and already the tuple AwxMembershipReconciler resolves against.
func awxIntegrationID(controllerID string, hostID int) string {
	controllerID = strings.TrimSpace(controllerID)
	if controllerID == "" || hostID <= 0 {
		return ""
	}

	return fmt.Sprintf("awx:v2:%s:host:%s", controllerID, strconv.Itoa(hostID))
}

// awxLegacyIDs lists the hostname-derived keys this host may already be
// registered under, so the canonical key above adopts the existing row instead
// of creating a second one.
//
// These are looked up, never registered. The set must mirror what the ingestor
// would have minted, which is `awx:host:<hostname>` using the Hostname field as
// emitted -- and buildDiscoveredHost substitutes ansible_host when the AWX name
// is empty, so both spellings are emitted when they differ.
func awxLegacyIDs(emittedHostname, awxHostName, integrationID string) []string {
	var out []string

	seen := make(map[string]bool)
	for _, name := range []string{emittedHostname, awxHostName} {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}

		legacy := "awx:host:" + name
		if legacy == integrationID || seen[legacy] {
			continue
		}

		seen[legacy] = true
		out = append(out, legacy)
	}

	return out
}

// awxHostMACs extracts NIC MACs that AWX already holds in a host's variables.
//
// No extra API call is possible here even if we wanted one: the agent pins
// scheduled inventory_sync HTTP to /api/v2/inventories/ and denies everything
// else before origin resolution, so /api/v2/hosts/<id>/ansible_facts/ is
// unreachable. Host variables are already fetched and already parsed on every
// run, which is why this is the only route to a real anchor.
//
// Only CONFIGURED NIC entries (proxmox_net0, proxmox_net1, ...) are read. The
// per-interface fact lists that some inventories also write include loopback,
// CNI/overlay and docker bridges, whose ephemeral or locally-administered
// addresses would risk collapsing distinct hosts. This mirrors the filter the
// proxmox plugin applies via ConfigKey.
func awxHostMACs(variables string) []string {
	trimmed := strings.TrimSpace(variables)
	if trimmed == "" || !strings.HasPrefix(trimmed, "{") {
		return nil
	}

	var decoded map[string]any
	if err := json.Unmarshal([]byte(trimmed), &decoded); err != nil {
		return nil
	}

	seen := make(map[string]bool)

	var out []string
	for index := 0; ; index++ {
		value, ok := decoded["proxmox_net"+strconv.Itoa(index)]
		if !ok {
			// Config keys are contiguous from net0; stop at the first gap so a
			// stray unrelated key cannot extend the scan indefinitely.
			break
		}

		mac := macFromNICValue(value)
		if mac == "" || seen[mac] {
			continue
		}

		seen[mac] = true
		out = append(out, mac)
	}

	return out
}

// macFromNICValue reads a MAC out of one NIC entry, which inventories write
// either as a mapping or as Proxmox's own comma-separated config string
// ("virtio=BC:24:11:53:84:67,bridge=vmbr0,tag=10").
func macFromNICValue(value any) string {
	switch typed := value.(type) {
	case map[string]any:
		for _, key := range nicMACKeys {
			if raw, ok := typed[key].(string); ok {
				if mac := normalizeMACForOutput(raw); mac != "" {
					return mac
				}
			}
		}

		return ""
	case string:
		return macFromNICConfigString(typed)
	default:
		return ""
	}
}

func macFromNICConfigString(config string) string {
	values := make(map[string]string)

	for _, part := range strings.Split(config, ",") {
		key, rest, found := strings.Cut(part, "=")
		if !found {
			continue
		}

		values[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(rest)
	}

	for _, key := range nicMACKeys {
		if mac := normalizeMACForOutput(values[key]); mac != "" {
			return mac
		}
	}

	// Proxmox writes the address against the NIC model when no explicit hwaddr
	// key is present, e.g. "virtio=BC:24:11:53:84:67".
	for _, model := range nicModelKeys {
		if mac := normalizeMACForOutput(values[model]); mac != "" {
			return mac
		}
	}

	return ""
}

var (
	nicMACKeys   = []string{"hwaddr", "macaddr", "mac"}
	nicModelKeys = []string{
		"virtio", "e1000", "e1000e", "rtl8139", "vmxnet3",
		"ne2k_pci", "i82551", "i82557b", "i82559er",
	}
)

// normalizeMACForOutput renders a MAC as canonical colon-uppercase, or "" when
// the value is not a 48-bit address.
func normalizeMACForOutput(value string) string {
	key := normalizeMACKey(value)
	if key == "" {
		return ""
	}

	parts := make([]string, 0, 6)
	for i := 0; i < len(key); i += 2 {
		parts = append(parts, key[i:i+2])
	}

	return strings.Join(parts, ":")
}

func normalizeMACKey(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	value = strings.NewReplacer(":", "", "-", "", ".", "").Replace(value)

	if len(value) != 12 {
		return ""
	}

	for _, r := range value {
		if !((r >= '0' && r <= '9') || (r >= 'A' && r <= 'F')) {
			return ""
		}
	}

	return value
}
