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

// Census observations get their OWN translator rather than reusing
// ProcessSnapshotToDiscoveredDevice, which hardcodes the collector's own IP and
// never sets a MAC. Reusing it would attribute every device on the segment to
// the machine that observed them.
const (
	// The metadata key core reads to decide whether this MAC may anchor a
	// canonical device (SourcePolicy.census_anchorable_mac?/1). It must live
	// INSIDE the metadata map, not only as a top-level field: the policy looks
	// it up there, and an absent key fails safe to "cannot anchor".
	censusMetadataMAC = "mac"

	// Matches SourcePolicy.passive_census_source?/1, which accepts either the
	// source string or this identity_source. Both are set so the guardrail
	// still recognises the update if a downstream hop rewrites `source`.
	censusIdentitySource = "netprobe_census"

	censusMetadataPrefix = "device_census."
)

// CensusTranslationStats reports what the translator did with a snapshot.
//
// Skips are counted rather than silently dropped: a census that quietly
// discards most of what it saw looks identical to a quiet segment.
type CensusTranslationStats struct {
	Observations int
	Devices      int
	SkippedNoMAC int
	// Off-segment sightings carry a ROUTER's MAC, not the address owner's.
	SkippedOffSegment int
	// Emitted, not skipped: real presence evidence that core refuses to anchor.
	RandomizedMAC int
	// Emitted with a MAC but no address, e.g. an RFC 5227 ARP probe.
	Addressless int
}

// CensusSnapshotToDiscoveredDevices converts one COMPLETE census snapshot into
// per-device discovery records.
//
// One record per observation, not one per snapshot: each observation is a
// distinct device on the segment. Incomplete snapshots are refused outright --
// applying a fragment would read as "every device in the missing chunks has
// left".
func CensusSnapshotToDiscoveredDevices(
	snapshot *netprobepb.DeviceCensusSnapshot,
	opts TranslationOptions,
) ([]*discoverypb.DiscoveredDevice, CensusTranslationStats) {
	var stats CensusTranslationStats
	if snapshot == nil || !snapshot.GetComplete() {
		return nil, stats
	}

	observations := snapshot.GetObservations()
	stats.Observations = len(observations)
	devices := make([]*discoverypb.DiscoveredDevice, 0, len(observations))

	for _, observation := range observations {
		mac := strings.TrimSpace(observation.GetMac())
		if mac == "" {
			// Nothing to identify. The census keys on MAC; an observation
			// without one carries no device.
			stats.SkippedNoMAC++
			continue
		}

		if observation.GetOffSegment() {
			// Traffic routed from another subnet arrives with the ROUTER's
			// source MAC. Emitting it would bind a remote address to the
			// gateway's hardware -- the over-merge failure that collapses
			// distinct hosts onto one device.
			stats.SkippedOffSegment++
			continue
		}

		if observation.GetRandomizedMac() {
			stats.RandomizedMAC++
		}

		ip := strings.TrimSpace(observation.GetIp())
		if ip == "" {
			stats.Addressless++
		}

		devices = append(devices, &discoverypb.DiscoveredDevice{
			Ip:       ip,
			Mac:      mac,
			Metadata: censusMetadata(snapshot, observation, opts, mac, ip),
		})
		stats.Devices++
	}

	return devices, stats
}

func censusMetadata(
	snapshot *netprobepb.DeviceCensusSnapshot,
	observation *netprobepb.DeviceCensusObservation,
	opts TranslationOptions,
	mac, ip string,
) map[string]string {
	source := string(models.DiscoverySourceNetprobeCensus)
	lastSeen := observedAtUnixNano(observation.GetLastSeenUnixNano())
	lastSeenText := ""
	if !lastSeen.IsZero() {
		lastSeenText = lastSeen.Format(time.RFC3339Nano)
	}

	metadata := map[string]string{
		metadataDiscoverySource: source,
		"source":                source,
		"identity_source":       censusIdentitySource,
		censusMetadataMAC:       mac,

		censusMetadataPrefix + "interface":            strings.TrimSpace(snapshot.GetInterfaceName()),
		censusMetadataPrefix + "interface_index":      strconv.FormatUint(uint64(observation.GetInterfaceIndex()), 10),
		censusMetadataPrefix + "kind":                 censusKindName(observation.GetKind()),
		censusMetadataPrefix + "snapshot_id":          strings.TrimSpace(snapshot.GetSnapshotId()),
		censusMetadataPrefix + "first_seen_unix_nano": strconv.FormatInt(observation.GetFirstSeenUnixNano(), 10),
		censusMetadataPrefix + "last_seen_unix_nano":  strconv.FormatInt(observation.GetLastSeenUnixNano(), 10),
		// Carried explicitly even though core re-derives it from the address
		// itself. Two independent determinations that must agree is the point:
		// core's is authoritative, this one says what the observer believed.
		censusMetadataPrefix + "randomized_mac": strconv.FormatBool(observation.GetRandomizedMac()),
	}

	if agentID := strings.TrimSpace(opts.AgentID); agentID != "" {
		metadata["agent_id"] = agentID
	}
	if gatewayID := strings.TrimSpace(opts.GatewayID); gatewayID != "" {
		metadata["gateway_id"] = gatewayID
	}

	// Alias keys only make sense for an observation that actually bound an
	// address. An RFC 5227 probe has a MAC and no address yet, and inventing
	// an empty alias for it would create a binding the device never claimed.
	if ip != "" {
		metadata["_alias_last_seen_ip"] = ip
		metadata["ip_alias:"+ip] = lastSeenText
	}
	if lastSeenText != "" {
		metadata["_alias_last_seen_at"] = lastSeenText
	}

	return metadata
}

func censusKindName(kind netprobepb.DeviceCensusKind) string {
	switch kind {
	case netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REQUEST:
		return "arp_request"
	case netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY:
		return "arp_reply"
	case netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_IPV6_NDP:
		return "ipv6_ndp"
	case netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_UNSPECIFIED:
		return "unspecified"
	default:
		return "unspecified"
	}
}
