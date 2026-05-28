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
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

const (
	metadataDiscoverySource        = "discovery_source"
	metadataPassiveFingerprintBase = "passive_fingerprint"
)

var (
	ErrNilFingerprintEvent     = errors.New("netprobe fingerprint event is nil")
	ErrFingerprintEventMissing = errors.New("netprobe fingerprint event is missing required fields")
)

// TranslationOptions carries agent-local context that is not present on the IPC event.
type TranslationOptions struct {
	AgentID      string
	GatewayID    string
	CollectorIP  string
	ProfileNames map[string]string
}

// FingerprintEventToDiscoveredDevice converts a passive netprobe event into a discovery device record.
func FingerprintEventToDiscoveredDevice(event *netprobepb.FingerprintEvent, opts TranslationOptions) (*discoverypb.DiscoveredDevice, error) {
	if event == nil {
		return nil, ErrNilFingerprintEvent
	}
	ip := strings.TrimSpace(event.GetIp())
	if ip == "" {
		return nil, fmt.Errorf("%w: ip", ErrFingerprintEventMissing)
	}

	metadata := baseMetadata(event, opts, ip)
	if err := addEvidenceMetadata(metadata, event); err != nil {
		return nil, err
	}

	return &discoverypb.DiscoveredDevice{
		Ip:       ip,
		Metadata: metadata,
	}, nil
}

// FingerprintEventsToResults converts multiple passive events into a completed discovery result set.
func FingerprintEventsToResults(events []*netprobepb.FingerprintEvent, opts TranslationOptions) (*discoverypb.ResultsResponse, error) {
	result := &discoverypb.ResultsResponse{
		Status:   discoverypb.DiscoveryStatus_COMPLETED,
		Progress: 100,
		Metadata: map[string]string{
			metadataDiscoverySource: string(models.DiscoverySourcePassiveNetprobe),
		},
	}
	if strings.TrimSpace(opts.AgentID) != "" {
		result.Metadata["agent_id"] = strings.TrimSpace(opts.AgentID)
	}
	if strings.TrimSpace(opts.GatewayID) != "" {
		result.Metadata["gateway_id"] = strings.TrimSpace(opts.GatewayID)
	}

	for _, event := range events {
		device, err := FingerprintEventToDiscoveredDevice(event, opts)
		if err != nil {
			return nil, err
		}
		result.Devices = append(result.Devices, device)
	}

	return result, nil
}

func baseMetadata(event *netprobepb.FingerprintEvent, opts TranslationOptions, ip string) map[string]string {
	source := string(models.DiscoverySourcePassiveNetprobe)
	metadata := map[string]string{
		metadataDiscoverySource: source,
		"source":                source,
		metadataPassiveFingerprintBase + ".source":     source,
		metadataPassiveFingerprintBase + ".profile_id": strings.TrimSpace(event.GetProfileId()),
		metadataPassiveFingerprintBase + ".interface":  strings.TrimSpace(event.GetInterfaceName()),
		"_alias_last_seen_ip":                          ip,
	}

	if agentID := strings.TrimSpace(opts.AgentID); agentID != "" {
		metadata["agent_id"] = agentID
	}
	if gatewayID := strings.TrimSpace(opts.GatewayID); gatewayID != "" {
		metadata["gateway_id"] = gatewayID
	}
	if collectorIP := strings.TrimSpace(opts.CollectorIP); collectorIP != "" {
		metadata["_alias_collector_ip"] = collectorIP
	}
	if profileName := profileName(event, opts); profileName != "" {
		metadata[metadataPassiveFingerprintBase+".profile_name"] = profileName
	}
	if observed := observedAt(event); !observed.IsZero() {
		timestamp := observed.Format(time.RFC3339Nano)
		metadata[metadataPassiveFingerprintBase+".observed_at"] = timestamp
		metadata[metadataPassiveFingerprintBase+".observed_at_unix_nano"] = strconv.FormatInt(event.GetObservedAtUnixNano(), 10)
		metadata["_alias_last_seen_at"] = timestamp
		metadata["ip_alias:"+ip] = timestamp
	} else {
		metadata["ip_alias:"+ip] = ""
	}

	return metadata
}

func addEvidenceMetadata(metadata map[string]string, event *netprobepb.FingerprintEvent) error {
	switch evidence := event.GetEvidence().(type) {
	case *netprobepb.FingerprintEvent_Tcp:
		tcp := evidence.Tcp
		metadata[metadataPassiveFingerprintBase+".protocol"] = "tcp"
		metadata[metadataPassiveFingerprintBase+".tcp.signature"] = strings.TrimSpace(tcp.GetSignature())
		metadata[metadataPassiveFingerprintBase+".tcp.os_family"] = strings.TrimSpace(tcp.GetOsFamily())
		metadata[metadataPassiveFingerprintBase+".tcp.os_name"] = strings.TrimSpace(tcp.GetOsName())
		metadata[metadataPassiveFingerprintBase+".tcp.confidence"] = strconv.FormatFloat(float64(tcp.GetConfidence()), 'f', 3, 32)
		metadata[metadataPassiveFingerprintBase+".tcp.ttl"] = strconv.FormatUint(uint64(tcp.GetTtl()), 10)
		metadata[metadataPassiveFingerprintBase+".tcp.window_size"] = strings.TrimSpace(tcp.GetWindowSize())
		metadata[metadataPassiveFingerprintBase+".tcp.mss"] = strconv.FormatUint(uint64(tcp.GetMss()), 10)
		metadata[metadataPassiveFingerprintBase+".tcp.options_layout"] = strings.Join(tcp.GetOptionsLayout(), ",")
		metadata[metadataPassiveFingerprintBase+".tcp.quirks"] = strings.Join(tcp.GetQuirks(), ",")
		metadata[metadataPassiveFingerprintBase+".tcp.ip_version"] = strings.TrimSpace(tcp.GetIpVersion())
		metadata[metadataPassiveFingerprintBase+".tcp.window_scale"] = strconv.FormatUint(uint64(tcp.GetWindowScale()), 10)
		metadata[metadataPassiveFingerprintBase+".tcp.payload_class"] = strings.TrimSpace(tcp.GetPayloadClass())
	case *netprobepb.FingerprintEvent_Tls:
		tls := evidence.Tls
		metadata[metadataPassiveFingerprintBase+".protocol"] = "tls"
		metadata[metadataPassiveFingerprintBase+".tls.ja4"] = strings.TrimSpace(tls.GetJa4())
		metadata[metadataPassiveFingerprintBase+".tls.ja4s"] = strings.TrimSpace(tls.GetJa4S())
		metadata[metadataPassiveFingerprintBase+".tls.sni_redacted"] = sanitizeSniRedacted(tls.GetSniRedacted())
	case *netprobepb.FingerprintEvent_Http:
		http := evidence.Http
		metadata[metadataPassiveFingerprintBase+".protocol"] = "http"
		metadata[metadataPassiveFingerprintBase+".http.user_agent"] = strings.TrimSpace(http.GetUserAgent())
		metadata[metadataPassiveFingerprintBase+".http.server"] = strings.TrimSpace(http.GetServer())
		metadata[metadataPassiveFingerprintBase+".http.accept_language"] = strings.TrimSpace(http.GetAcceptLanguage())
	default:
		return fmt.Errorf("%w: evidence", ErrFingerprintEventMissing)
	}

	return nil
}

func sanitizeSniRedacted(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || value == "<present>" {
		return value
	}

	return "<present>"
}

func profileName(event *netprobepb.FingerprintEvent, opts TranslationOptions) string {
	profileID := strings.TrimSpace(event.GetProfileId())
	if profileID == "" || opts.ProfileNames == nil {
		return ""
	}

	return strings.TrimSpace(opts.ProfileNames[profileID])
}

func observedAt(event *netprobepb.FingerprintEvent) time.Time {
	nano := event.GetObservedAtUnixNano()
	if nano <= 0 {
		return time.Time{}
	}

	return time.Unix(0, nano).UTC()
}
