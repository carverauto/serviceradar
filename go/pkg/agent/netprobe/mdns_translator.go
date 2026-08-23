/*
 * Copyright 2026 Carver Automation Corporation.
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

package netprobe

import (
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

const (
	mdnsMetadataPrefix = "mdns."

	// The metadata key core's SourcePolicy reads to decide whether this MAC may
	// anchor a device. It must live INSIDE the metadata map, and for mDNS the
	// answer is always no -- see CensusSnapshotToDiscoveredDevices for why the
	// key's absence fails closed.
	mdnsMetadataMAC = "mac"

	mdnsIdentitySource = "netprobe_mdns"
)

// MdnsTranslationStats reports what the translator did with a snapshot.
//
// Skips are counted rather than silently dropped: a collector that quietly
// discards most of what it saw is indistinguishable from a quiet segment.
type MdnsTranslationStats struct {
	Devices           int
	Emitted           int
	SkippedNoMAC      int
	SkippedNoEvidence int
	// Emitted, but with no model asserted: the MAC spoke for more than one
	// product, so core is expected to leave the type alone.
	Ambiguous int
	Truncated int
}

// MdnsSnapshotToDiscoveredDevices converts one COMPLETE mDNS snapshot into
// per-device enrichment records.
//
// These records carry NO ip and are never expected to create a device. mDNS
// enriches what the census already found; a device that announces a service but
// has never been seen at layer 2 is not a device this can vouch for.
func MdnsSnapshotToDiscoveredDevices(
	snapshot *netprobepb.MdnsSnapshot,
	opts TranslationOptions,
) ([]*discoverypb.DiscoveredDevice, MdnsTranslationStats) {
	var stats MdnsTranslationStats
	if snapshot == nil || !snapshot.GetComplete() {
		return nil, stats
	}

	devices := snapshot.GetDevices()
	stats.Devices = len(devices)
	out := make([]*discoverypb.DiscoveredDevice, 0, len(devices))

	for _, device := range devices {
		mac := strings.TrimSpace(device.GetMac())
		if mac == "" {
			stats.SkippedNoMAC++
			continue
		}

		// A device that announced nothing identifying is not worth a round
		// trip. It is already in inventory via the census.
		if len(device.GetServiceTypes()) == 0 && len(device.GetTxt()) == 0 {
			stats.SkippedNoEvidence++
			continue
		}

		if device.GetAmbiguousModel() {
			stats.Ambiguous++
		}
		if device.GetTruncated() {
			stats.Truncated++
		}

		out = append(out, &discoverypb.DiscoveredDevice{
			// No Ip: mDNS identifies, it does not locate. Supplying one would
			// invite core to bind an address this never observed.
			Mac:      mac,
			Metadata: mdnsMetadata(snapshot, device, opts, mac),
		})
		stats.Emitted++
	}

	return out, stats
}

func mdnsMetadata(
	snapshot *netprobepb.MdnsSnapshot,
	device *netprobepb.MdnsDevice,
	opts TranslationOptions,
	mac string,
) map[string]string {
	source := string(models.DiscoverySourceNetprobeMdns)

	metadata := map[string]string{
		metadataDiscoverySource: source,
		"source":                source,
		"identity_source":       mdnsIdentitySource,
		mdnsMetadataMAC:         mac,

		mdnsMetadataPrefix + "interface":     strings.TrimSpace(snapshot.GetInterfaceName()),
		mdnsMetadataPrefix + "snapshot_id":   strings.TrimSpace(snapshot.GetSnapshotId()),
		mdnsMetadataPrefix + "service_types": strings.Join(device.GetServiceTypes(), ","),
		// Carried so an operator can see WHY a type was assigned, and so a
		// wrong assignment is traceable to the announcement that caused it.
		mdnsMetadataPrefix + "models":          strings.Join(device.GetModels(), ","),
		mdnsMetadataPrefix + "ambiguous_model": strconv.FormatBool(device.GetAmbiguousModel()),
		mdnsMetadataPrefix + "truncated":       strconv.FormatBool(device.GetTruncated()),
	}

	// The single model, only when there IS a single model.
	//
	// Deliberately absent when ambiguous: one MAC advertising both a HomePod
	// and an Apple TV has not told us which it is, and writing either would let
	// core type it from whichever sorted first. Absent is the honest answer.
	if models := device.GetModels(); len(models) == 1 {
		metadata[mdnsMetadataPrefix+"model"] = models[0]
	}

	for _, pair := range device.GetTxt() {
		key := strings.TrimSpace(pair.GetKey())
		if key == "" {
			continue
		}
		if pair.GetHasValue() {
			metadata[mdnsMetadataPrefix+"txt."+key] = pair.GetValue()
			continue
		}
		// Present with no value is a real state (RFC 6763 6.4). Recorded as a
		// marker rather than an empty string, which would claim the device sent
		// "key=".
		metadata[mdnsMetadataPrefix+"txt."+key] = "true"
	}

	if agentID := strings.TrimSpace(opts.AgentID); agentID != "" {
		metadata["agent_id"] = agentID
	}
	if gatewayID := strings.TrimSpace(opts.GatewayID); gatewayID != "" {
		metadata["gateway_id"] = gatewayID
	}

	if lastSeen := observedAtUnixNano(device.GetLastSeenUnixNano()); !lastSeen.IsZero() {
		metadata[mdnsMetadataPrefix+"last_seen"] = lastSeen.Format(time.RFC3339Nano)
	}

	return metadata
}
