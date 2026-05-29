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
	"encoding/json"
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
	metadataDPIBase                = "dpi"
	metadataPassiveFingerprintBase = "passive_fingerprint"
)

var (
	ErrNilFingerprintEvent     = errors.New("netprobe fingerprint event is nil")
	ErrNilDPIEvent             = errors.New("netprobe DPI event is nil")
	ErrNilProcessSnapshot      = errors.New("netprobe process snapshot is nil")
	ErrFingerprintEventMissing = errors.New("netprobe fingerprint event is missing required fields")
	ErrDPIEventMissing         = errors.New("netprobe DPI event is missing required fields")
	ErrProcessSnapshotMissing  = errors.New("netprobe process snapshot is missing required fields")
	ErrProcessSnapshotMetadata = errors.New("netprobe process snapshot metadata marshal failed")
)

// TranslationOptions carries agent-local context that is not present on the IPC event.
type TranslationOptions struct {
	AgentID      string
	GatewayID    string
	CollectorIP  string
	ProfileNames map[string]string
}

type processSnapshotMetadata struct {
	Fingerprint        string                         `json:"fingerprint,omitempty"`
	ObservedAtUnixNano int64                          `json:"observed_at_unix_nano,omitempty"`
	ObservedAt         string                         `json:"observed_at,omitempty"`
	Entries            []processSnapshotEntryMetadata `json:"entries"`
}

type processSnapshotEntryMetadata struct {
	LocalIP           string   `json:"local_ip,omitempty"`
	LocalPort         uint32   `json:"local_port,omitempty"`
	TransportProtocol string   `json:"transport_protocol,omitempty"`
	PID               uint32   `json:"pid,omitempty"`
	TGID              uint32   `json:"tgid,omitempty"`
	UID               uint32   `json:"uid,omitempty"`
	GID               uint32   `json:"gid,omitempty"`
	Comm              string   `json:"comm,omitempty"`
	RedactedCmdline   []string `json:"redacted_cmdline,omitempty"`
	ContainerID       string   `json:"container_id,omitempty"`
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

// DpiEventToDiscoveredDevice converts a privacy-redacted DPI event into a discovery device record.
func DpiEventToDiscoveredDevice(event *netprobepb.DpiEvent, opts TranslationOptions) (*discoverypb.DiscoveredDevice, error) {
	if event == nil {
		return nil, ErrNilDPIEvent
	}
	protocol := strings.ToLower(strings.TrimSpace(event.GetProtocol()))
	if protocol == "" {
		return nil, fmt.Errorf("%w: protocol", ErrDPIEventMissing)
	}
	ip := dpiDeviceIP(event, opts)
	if ip == "" {
		return nil, fmt.Errorf("%w: ip", ErrDPIEventMissing)
	}

	metadata := dpiMetadata(event, opts, ip, protocol)

	return &discoverypb.DiscoveredDevice{
		Ip:       ip,
		Metadata: metadata,
	}, nil
}

// ProcessSnapshotToDiscoveredDevice converts a local process snapshot into a
// passive-netprobe metadata update for the agent-host device.
func ProcessSnapshotToDiscoveredDevice(snapshot *netprobepb.ProcessSnapshot, opts TranslationOptions) (*discoverypb.DiscoveredDevice, error) {
	if snapshot == nil {
		return nil, ErrNilProcessSnapshot
	}
	ip := strings.TrimSpace(opts.CollectorIP)
	if ip == "" {
		return nil, fmt.Errorf("%w: collector_ip", ErrProcessSnapshotMissing)
	}

	metadata, err := processSnapshotMetadataMap(snapshot, opts, ip)
	if err != nil {
		return nil, err
	}

	return &discoverypb.DiscoveredDevice{
		Ip:       ip,
		Metadata: metadata,
	}, nil
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

func dpiDeviceIP(event *netprobepb.DpiEvent, opts TranslationOptions) string {
	collectorIP := strings.TrimSpace(opts.CollectorIP)
	sourceIP := strings.TrimSpace(event.GetSourceIp())
	destinationIP := strings.TrimSpace(event.GetDestinationIp())

	if collectorIP != "" && (collectorIP == sourceIP || collectorIP == destinationIP) {
		return collectorIP
	}
	if sourceIP != "" {
		return sourceIP
	}

	return destinationIP
}

func dpiMetadata(event *netprobepb.DpiEvent, opts TranslationOptions, ip string, protocol string) map[string]string {
	source := string(models.DiscoverySourcePassiveNetprobe)
	metadata := map[string]string{
		metadataDiscoverySource:                          source,
		"source":                                         source,
		metadataDPIBase + ".source":                      source,
		metadataDPIBase + ".profile_id":                  strings.TrimSpace(event.GetProfileId()),
		metadataDPIBase + ".interface":                   strings.TrimSpace(event.GetInterfaceName()),
		metadataDPIBase + ".protocol":                    protocol,
		metadataDPIBase + "." + protocol + ".count":      "1",
		metadataDPIBase + "." + protocol + ".confidence": strconv.FormatFloat(float64(event.GetConfidence()), 'f', 3, 32),
		"_alias_last_seen_ip":                            ip,
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
	if profileName := strings.TrimSpace(opts.ProfileNames[strings.TrimSpace(event.GetProfileId())]); profileName != "" {
		metadata[metadataDPIBase+".profile_name"] = profileName
	}
	if observed := observedAtUnixNano(event.GetObservedAtUnixNano()); !observed.IsZero() {
		timestamp := observed.Format(time.RFC3339Nano)
		metadata[metadataDPIBase+"."+protocol+".last_observed_at"] = timestamp
		metadata[metadataDPIBase+".observed_at"] = timestamp
		metadata["_alias_last_seen_at"] = timestamp
		metadata["ip_alias:"+ip] = timestamp
	} else {
		metadata["ip_alias:"+ip] = ""
	}

	return metadata
}

func processSnapshotMetadataMap(snapshot *netprobepb.ProcessSnapshot, opts TranslationOptions, ip string) (map[string]string, error) {
	source := string(models.DiscoverySourcePassiveNetprobe)
	observed := observedAtUnixNano(snapshot.GetObservedAtUnixNano())
	observedText := ""
	if !observed.IsZero() {
		observedText = observed.Format(time.RFC3339Nano)
	}

	payload := processSnapshotMetadata{
		Fingerprint:        strings.TrimSpace(snapshot.GetFingerprint()),
		ObservedAtUnixNano: snapshot.GetObservedAtUnixNano(),
		ObservedAt:         observedText,
		Entries:            processSnapshotEntries(snapshot.GetEntries()),
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrProcessSnapshotMetadata, err)
	}

	metadata := map[string]string{
		metadataDiscoverySource:                 source,
		"source":                                source,
		"local_processes":                       string(payloadJSON),
		"local_processes.fingerprint":           payload.Fingerprint,
		"local_processes.entry_count":           strconv.Itoa(len(payload.Entries)),
		"local_processes.observed_at":           observedText,
		"local_processes.observed_at_unix_nano": strconv.FormatInt(snapshot.GetObservedAtUnixNano(), 10),
		"_alias_last_seen_ip":                   ip,
	}

	if agentID := strings.TrimSpace(opts.AgentID); agentID != "" {
		metadata["agent_id"] = agentID
	}
	if gatewayID := strings.TrimSpace(opts.GatewayID); gatewayID != "" {
		metadata["gateway_id"] = gatewayID
	}
	if observedText != "" {
		metadata["_alias_last_seen_at"] = observedText
		metadata["ip_alias:"+ip] = observedText
	} else {
		metadata["ip_alias:"+ip] = ""
	}

	return metadata, nil
}

func processSnapshotEntries(entries []*netprobepb.ProcessSnapshotEntry) []processSnapshotEntryMetadata {
	out := make([]processSnapshotEntryMetadata, 0, len(entries))
	for _, entry := range entries {
		if entry == nil {
			continue
		}
		out = append(out, processSnapshotEntryMetadata{
			LocalIP:           strings.TrimSpace(entry.GetLocalIp()),
			LocalPort:         entry.GetLocalPort(),
			TransportProtocol: strings.ToLower(strings.TrimSpace(entry.GetTransportProtocol())),
			PID:               entry.GetPid(),
			TGID:              entry.GetTgid(),
			UID:               entry.GetUid(),
			GID:               entry.GetGid(),
			Comm:              strings.TrimSpace(entry.GetComm()),
			RedactedCmdline:   append([]string(nil), entry.GetRedactedCmdline()...),
			ContainerID:       strings.TrimSpace(entry.GetContainerId()),
		})
	}

	return out
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
	case *netprobepb.FingerprintEvent_LicenseClean:
		addLicenseCleanMetadata(metadata, evidence.LicenseClean)
	default:
		return fmt.Errorf("%w: evidence", ErrFingerprintEventMissing)
	}

	return nil
}

func addLicenseCleanMetadata(metadata map[string]string, fingerprint *netprobepb.LicenseCleanFingerprint) {
	if fingerprint == nil {
		return
	}

	metadata[metadataPassiveFingerprintBase+".protocol"] = "license_clean"
	if osMatch := fingerprint.GetOsMatch(); osMatch != nil {
		metadata[metadataPassiveFingerprintBase+".os.name"] = strings.TrimSpace(osMatch.GetName())
		metadata[metadataPassiveFingerprintBase+".os.version_range"] = strings.TrimSpace(osMatch.GetVersionRange())
		metadata[metadataPassiveFingerprintBase+".os.family"] = strings.TrimSpace(osMatch.GetOsFamily())
		metadata[metadataPassiveFingerprintBase+".os.confidence"] = strconv.FormatFloat(float64(osMatch.GetConfidence()), 'f', 3, 32)
	}
	if recog := fingerprint.GetRecogHttp(); recog != nil {
		addRecogMetadata(metadata, "http", recog)
	}
	if recog := fingerprint.GetRecogSsh(); recog != nil {
		addRecogMetadata(metadata, "ssh", recog)
	}
	if recog := fingerprint.GetRecogSmb(); recog != nil {
		addRecogMetadata(metadata, "smb", recog)
	}
	if recog := fingerprint.GetRecogFtp(); recog != nil {
		addRecogMetadata(metadata, "ftp", recog)
	}
	if recog := fingerprint.GetRecogTelnet(); recog != nil {
		addRecogMetadata(metadata, "telnet", recog)
	}
	if recog := fingerprint.GetRecogRdp(); recog != nil {
		addRecogMetadata(metadata, "rdp", recog)
	}
	if recog := fingerprint.GetRecogDns(); recog != nil {
		addRecogMetadata(metadata, "dns", recog)
	}
}

func addRecogMetadata(metadata map[string]string, protocol string, match *netprobepb.RecogFingerprintMatch) {
	base := metadataPassiveFingerprintBase + ".recog." + protocol
	metadata[base+".product"] = strings.TrimSpace(match.GetProduct())
	metadata[base+".version"] = strings.TrimSpace(match.GetVersion())
	metadata[base+".os_family"] = strings.TrimSpace(match.GetOsFamily())
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
	return observedAtUnixNano(event.GetObservedAtUnixNano())
}

func observedAtUnixNano(nano int64) time.Time {
	if nano <= 0 {
		return time.Time{}
	}

	return time.Unix(0, nano).UTC()
}
