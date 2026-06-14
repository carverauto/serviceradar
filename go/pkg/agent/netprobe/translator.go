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
	"sort"
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
	metadataActiveFingerprintBase  = "active_fingerprint"
	metadataPassiveFingerprintBase = "passive_fingerprint"
)

var (
	ErrNilFingerprintEvent     = errors.New("netprobe fingerprint event is nil")
	ErrNilDPIEvent             = errors.New("netprobe DPI event is nil")
	ErrNilProcessSnapshot      = errors.New("netprobe process snapshot is nil")
	ErrFingerprintEventMissing = errors.New("netprobe fingerprint event is missing required fields")
	ErrDPIEventMissing         = errors.New("netprobe DPI event is missing required fields")
	ErrProcessSnapshotMissing  = errors.New("netprobe process snapshot is missing required fields")
)

// TranslationOptions carries agent-local context that is not present on the IPC event.
type TranslationOptions struct {
	AgentID      string
	GatewayID    string
	CollectorIP  string
	ProfileNames map[string]string
}

// FingerprintEventToDiscoveredDevice converts a netprobe fingerprint event into a discovery device record.
func FingerprintEventToDiscoveredDevice(event *netprobepb.FingerprintEvent, opts TranslationOptions) (*discoverypb.DiscoveredDevice, error) {
	if event == nil {
		return nil, ErrNilFingerprintEvent
	}
	ip := strings.TrimSpace(event.GetIp())
	if ip == "" {
		return nil, fmt.Errorf("%w: ip", ErrFingerprintEventMissing)
	}

	metadata := baseMetadata(event, opts, ip)
	if err := addEvidenceMetadata(metadata, event, fingerprintMetadataBase(event)); err != nil {
		return nil, err
	}

	return &discoverypb.DiscoveredDevice{
		Ip:       ip,
		Metadata: metadata,
	}, nil
}

// FingerprintEventsToResults converts multiple fingerprint events into a completed discovery result set.
func FingerprintEventsToResults(events []*netprobepb.FingerprintEvent, opts TranslationOptions) (*discoverypb.ResultsResponse, error) {
	result := &discoverypb.ResultsResponse{
		Status:   discoverypb.DiscoveryStatus_COMPLETED,
		Progress: 100,
		Metadata: map[string]string{
			metadataDiscoverySource: fingerprintResultSource(events),
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

	metadata := processSnapshotMetadataMap(snapshot, opts, ip)

	return &discoverypb.DiscoveredDevice{
		Ip:       ip,
		Metadata: metadata,
	}, nil
}

func baseMetadata(event *netprobepb.FingerprintEvent, opts TranslationOptions, ip string) map[string]string {
	source := fingerprintDiscoverySource(event)
	base := fingerprintMetadataBase(event)
	metadata := map[string]string{
		metadataDiscoverySource: source,
		"source":                source,
		base + ".source":        source,
		base + ".profile_id":    profileID(event),
		base + ".interface":     strings.TrimSpace(event.GetInterfaceName()),
		"_alias_last_seen_ip":   ip,
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
	if metadata[base+".profile_id"] == "" {
		delete(metadata, base+".profile_id")
	}
	if metadata[base+".interface"] == "" {
		delete(metadata, base+".interface")
	}
	if profileName := profileName(event, opts); profileName != "" {
		metadata[base+".profile_name"] = profileName
	}
	if observed := observedAt(event); !observed.IsZero() {
		timestamp := observed.Format(time.RFC3339Nano)
		metadata[base+".observed_at"] = timestamp
		metadata[base+".observed_at_unix_nano"] = strconv.FormatInt(event.GetObservedAtUnixNano(), 10)
		metadata["_alias_last_seen_at"] = timestamp
		metadata["ip_alias:"+ip] = timestamp
	} else {
		metadata["ip_alias:"+ip] = ""
	}

	return metadata
}

func fingerprintResultSource(events []*netprobepb.FingerprintEvent) string {
	for _, event := range events {
		source := fingerprintDiscoverySource(event)
		if source != "" {
			return source
		}
	}

	return string(models.DiscoverySourcePassiveNetprobe)
}

func fingerprintDiscoverySource(event *netprobepb.FingerprintEvent) string {
	if isSweepActiveFingerprint(event) {
		return string(models.DiscoverySourceSweepActive)
	}

	return string(models.DiscoverySourcePassiveNetprobe)
}

func fingerprintMetadataBase(event *netprobepb.FingerprintEvent) string {
	if isSweepActiveFingerprint(event) {
		return metadataActiveFingerprintBase
	}

	return metadataPassiveFingerprintBase
}

func isSweepActiveFingerprint(event *netprobepb.FingerprintEvent) bool {
	return strings.TrimSpace(event.GetProfileId()) == string(models.DiscoverySourceSweepActive)
}

func profileID(event *netprobepb.FingerprintEvent) string {
	value := strings.TrimSpace(event.GetProfileId())
	if value == string(models.DiscoverySourceSweepActive) {
		return ""
	}

	return value
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

func processSnapshotMetadataMap(snapshot *netprobepb.ProcessSnapshot, opts TranslationOptions, ip string) map[string]string {
	source := string(models.DiscoverySourcePassiveNetprobe)
	observed := observedAtUnixNano(snapshot.GetObservedAtUnixNano())
	observedText := ""
	if !observed.IsZero() {
		observedText = observed.Format(time.RFC3339Nano)
	}

	metadata := map[string]string{
		metadataDiscoverySource:                 source,
		"source":                                source,
		"local_processes.schema":                "summary_v1",
		"local_processes.fingerprint":           strings.TrimSpace(snapshot.GetFingerprint()),
		"local_processes.observed_at":           observedText,
		"local_processes.observed_at_unix_nano": strconv.FormatInt(snapshot.GetObservedAtUnixNano(), 10),
		"_alias_last_seen_ip":                   ip,
	}
	for key, value := range processSnapshotSummary(snapshot.GetEntries()) {
		metadata["local_processes."+key] = value
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

	return metadata
}

func processSnapshotSummary(entries []*netprobepb.ProcessSnapshotEntry) map[string]string {
	processes := make(map[string]struct{})
	ports := make(map[string]struct{})
	protocols := make(map[string]struct{})
	containers := make(map[string]struct{})
	perProtocolPorts := make(map[string]map[string]struct{})
	entryCount := 0

	for _, entry := range entries {
		if entry == nil {
			continue
		}
		entryCount++

		if key := processIdentityKey(entry); key != "" {
			processes[key] = struct{}{}
		}
		if containerID := strings.TrimSpace(entry.GetContainerId()); containerID != "" {
			containers[containerID] = struct{}{}
		}
		protocol := strings.ToLower(strings.TrimSpace(entry.GetTransportProtocol()))
		if protocol != "" {
			protocols[protocol] = struct{}{}
		}
		if port := entry.GetLocalPort(); port > 0 {
			portKey := strconv.FormatUint(uint64(port), 10)
			if protocol != "" {
				portKey = protocol + ":" + portKey
				if perProtocolPorts[protocol] == nil {
					perProtocolPorts[protocol] = make(map[string]struct{})
				}
				perProtocolPorts[protocol][strconv.FormatUint(uint64(port), 10)] = struct{}{}
			}
			ports[portKey] = struct{}{}
		}
	}

	summary := map[string]string{
		"entry_count":     strconv.Itoa(entryCount),
		"process_count":   strconv.Itoa(len(processes)),
		"port_count":      strconv.Itoa(len(ports)),
		"container_count": strconv.Itoa(len(containers)),
		"protocols":       strings.Join(sortedKeys(protocols), ","),
	}
	for protocol, protocolPorts := range perProtocolPorts {
		summary[protocol+"_port_count"] = strconv.Itoa(len(protocolPorts))
	}

	return summary
}

func processIdentityKey(entry *netprobepb.ProcessSnapshotEntry) string {
	if entry.GetTgid() > 0 {
		return "tgid:" + strconv.FormatUint(uint64(entry.GetTgid()), 10)
	}
	if entry.GetPid() > 0 {
		return "pid:" + strconv.FormatUint(uint64(entry.GetPid()), 10)
	}
	comm := strings.TrimSpace(entry.GetComm())
	if comm == "" {
		return ""
	}

	return "comm:" + comm
}

func sortedKeys(values map[string]struct{}) []string {
	keys := make([]string, 0, len(values))
	for value := range values {
		keys = append(keys, value)
	}
	sort.Strings(keys)

	return keys
}

func addEvidenceMetadata(metadata map[string]string, event *netprobepb.FingerprintEvent, base string) error {
	switch evidence := event.GetEvidence().(type) {
	case *netprobepb.FingerprintEvent_Tcp:
		//nolint:staticcheck // backwards-compatible deprecated-field path; remove with proto v2
		tcp := evidence.Tcp
		metadata[base+".protocol"] = "tcp"
		metadata[base+".tcp.signature"] = strings.TrimSpace(tcp.GetSignature())
		metadata[base+".tcp.os_family"] = strings.TrimSpace(tcp.GetOsFamily())
		metadata[base+".tcp.os_name"] = strings.TrimSpace(tcp.GetOsName())
		metadata[base+".tcp.confidence"] = strconv.FormatFloat(float64(tcp.GetConfidence()), 'f', 3, 32)
		metadata[base+".tcp.ttl"] = strconv.FormatUint(uint64(tcp.GetTtl()), 10)
		metadata[base+".tcp.window_size"] = strings.TrimSpace(tcp.GetWindowSize())
		metadata[base+".tcp.mss"] = strconv.FormatUint(uint64(tcp.GetMss()), 10)
		metadata[base+".tcp.options_layout"] = strings.Join(tcp.GetOptionsLayout(), ",")
		metadata[base+".tcp.quirks"] = strings.Join(tcp.GetQuirks(), ",")
		metadata[base+".tcp.ip_version"] = strings.TrimSpace(tcp.GetIpVersion())
		metadata[base+".tcp.window_scale"] = strconv.FormatUint(uint64(tcp.GetWindowScale()), 10)
		metadata[base+".tcp.payload_class"] = strings.TrimSpace(tcp.GetPayloadClass())
	case *netprobepb.FingerprintEvent_Tls:
		//nolint:staticcheck // backwards-compatible deprecated-field path; remove with proto v2
		tls := evidence.Tls
		metadata[base+".protocol"] = "tls"
		metadata[base+".tls.ja4"] = strings.TrimSpace(tls.GetJa4())
		metadata[base+".tls.ja4s"] = strings.TrimSpace(tls.GetJa4S())
		metadata[base+".tls.sni_redacted"] = sanitizeSniRedacted(tls.GetSniRedacted())
	case *netprobepb.FingerprintEvent_Http:
		//nolint:staticcheck // backwards-compatible deprecated-field path; remove with proto v2
		http := evidence.Http
		metadata[base+".protocol"] = "http"
		metadata[base+".http.user_agent"] = strings.TrimSpace(http.GetUserAgent())
		metadata[base+".http.server"] = strings.TrimSpace(http.GetServer())
		metadata[base+".http.accept_language"] = strings.TrimSpace(http.GetAcceptLanguage())
	case *netprobepb.FingerprintEvent_LicenseClean:
		addLicenseCleanMetadata(metadata, evidence.LicenseClean, base)
	default:
		return fmt.Errorf("%w: evidence", ErrFingerprintEventMissing)
	}

	return nil
}

func addLicenseCleanMetadata(metadata map[string]string, fingerprint *netprobepb.LicenseCleanFingerprint, base string) {
	if fingerprint == nil {
		return
	}

	metadata[base+".protocol"] = "license_clean"
	if osMatch := fingerprint.GetOsMatch(); osMatch != nil {
		metadata[base+".os.name"] = strings.TrimSpace(osMatch.GetName())
		metadata[base+".os.version_range"] = strings.TrimSpace(osMatch.GetVersionRange())
		metadata[base+".os.family"] = strings.TrimSpace(osMatch.GetOsFamily())
		metadata[base+".os.confidence"] = strconv.FormatFloat(float64(osMatch.GetConfidence()), 'f', 3, 32)
	}
	if recog := fingerprint.GetRecogHttp(); recog != nil {
		addRecogMetadata(metadata, base, "http", recog)
	}
	if recog := fingerprint.GetRecogSsh(); recog != nil {
		addRecogMetadata(metadata, base, "ssh", recog)
	}
	if recog := fingerprint.GetRecogSmb(); recog != nil {
		addRecogMetadata(metadata, base, "smb", recog)
	}
	if recog := fingerprint.GetRecogFtp(); recog != nil {
		addRecogMetadata(metadata, base, "ftp", recog)
	}
	if recog := fingerprint.GetRecogTelnet(); recog != nil {
		addRecogMetadata(metadata, base, "telnet", recog)
	}
	if recog := fingerprint.GetRecogSmtp(); recog != nil {
		addRecogMetadata(metadata, base, "smtp", recog)
	}
	if recog := fingerprint.GetRecogRdp(); recog != nil {
		addRecogMetadata(metadata, base, "rdp", recog)
	}
	if recog := fingerprint.GetRecogDns(); recog != nil {
		addRecogMetadata(metadata, base, "dns", recog)
	}
	if recog := fingerprint.GetRecogNtp(); recog != nil {
		addRecogMetadata(metadata, base, "ntp", recog)
	}
}

func addRecogMetadata(metadata map[string]string, base string, protocol string, match *netprobepb.RecogFingerprintMatch) {
	prefix := base + ".recog." + protocol
	metadata[prefix+".product"] = strings.TrimSpace(match.GetProduct())
	metadata[prefix+".version"] = strings.TrimSpace(match.GetVersion())
	metadata[prefix+".os_family"] = strings.TrimSpace(match.GetOsFamily())
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
