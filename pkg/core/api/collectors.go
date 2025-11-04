package api

import (
	"strings"

	"github.com/carverauto/serviceradar/pkg/devicealias"
	"github.com/carverauto/serviceradar/pkg/models"
)

type collectorCapabilities struct {
	hasCollector   bool
	supportsICMP   bool
	supportsSNMP   bool
	supportsSysmon bool
}

// CollectorCapabilityResponse represents collector capability hints exposed via the API.
type CollectorCapabilityResponse struct {
	HasCollector   bool `json:"has_collector"`
	SupportsICMP   bool `json:"supports_icmp"`
	SupportsSNMP   bool `json:"supports_snmp"`
	SupportsSysmon bool `json:"supports_sysmon"`
}

type collectorSignals struct {
	serviceID       string
	collectorIP     string
	collectorAgent  string
	collectorPoller string
}

// deriveCollectorCapabilities inspects unified device metadata and alias history to infer
// which collectors are active for the device. It returns the inferred capabilities along with
// a boolean indicating whether the metadata contained any alias/collector hints.
func deriveCollectorCapabilities(device *models.UnifiedDevice) (collectorCapabilities, bool) {
	if device == nil || device.Metadata == nil || device.Metadata.Value == nil {
		return collectorCapabilities{}, false
	}

	metadata := device.Metadata.Value
	if len(metadata) == 0 {
		return collectorCapabilities{}, false
	}

	record := devicealias.FromMetadata(metadata)
	signals := extractCollectorSignals(metadata, record)
	serviceTypes := extractServiceTypes(metadata, record, device.DiscoverySources, signals.serviceID, device.DeviceID)

	hasCollector := false

	if len(serviceTypes) > 0 {
		hasCollector = true
	}

	if serviceIDIndicatesCollector(signals.serviceID) {
		hasCollector = true
	}

	if signals.collectorAgent != "" || signals.collectorPoller != "" {
		hasCollector = true
	}

	caps := collectorCapabilities{
		hasCollector: hasCollector,
	}

	if containsServiceType(serviceTypes, "icmp") {
		caps.supportsICMP = true
	}
	if containsServiceType(serviceTypes, "snmp") {
		caps.supportsSNMP = true
	}
	if containsServiceType(serviceTypes, "sysmon") {
		caps.supportsSysmon = true
	}

	return caps, true
}

func toCollectorCapabilityResponse(caps collectorCapabilities) *CollectorCapabilityResponse {
	return &CollectorCapabilityResponse{
		HasCollector:   caps.hasCollector,
		SupportsICMP:   caps.supportsICMP,
		SupportsSNMP:   caps.supportsSNMP,
		SupportsSysmon: caps.supportsSysmon,
	}
}

func extractCollectorSignals(metadata map[string]string, record *devicealias.Record) collectorSignals {
	signals := collectorSignals{
		collectorAgent:  strings.TrimSpace(metadata["collector_agent_id"]),
		collectorPoller: strings.TrimSpace(metadata["collector_poller_id"]),
	}

	if record != nil {
		signals.serviceID = strings.TrimSpace(record.CurrentServiceID)
		signals.collectorIP = strings.TrimSpace(record.CollectorIP)
	}

	if signals.serviceID == "" {
		signals.serviceID = strings.TrimSpace(metadata["_alias_last_seen_service_id"])
	}
	if signals.collectorIP == "" {
		signals.collectorIP = strings.TrimSpace(metadata["_alias_collector_ip"])
	}

	return signals
}

func extractServiceTypes(
	metadata map[string]string,
	record *devicealias.Record,
	sources []models.DiscoverySourceInfo,
	primaryServiceID string,
	deviceID string,
) map[string]struct{} {
	serviceTypes := make(map[string]struct{})

	if serviceIDMatchesDevice(primaryServiceID, deviceID) || serviceIDIndicatesCollector(primaryServiceID) {
		registerServiceType(primaryServiceID, serviceTypes)
	}

	if value := strings.TrimSpace(metadata["checker_service_type"]); value != "" {
		registerServiceType(value, serviceTypes)
	}
	if value := strings.TrimSpace(metadata["checker_service"]); value != "" {
		registerServiceType(value, serviceTypes)
	}
	if value := strings.TrimSpace(metadata["icmp_service_name"]); value != "" {
		serviceTypes["icmp"] = struct{}{}
	}
	if value := strings.TrimSpace(metadata["icmp_target"]); value != "" {
		serviceTypes["icmp"] = struct{}{}
	}
	if value := strings.TrimSpace(metadata["_last_icmp_update_at"]); value != "" {
		serviceTypes["icmp"] = struct{}{}
	}

	if value, ok := metadata["snmp_monitoring"]; ok && strings.TrimSpace(value) != "" {
		serviceTypes["snmp"] = struct{}{}
	}

	for key := range metadata {
		if strings.HasPrefix(key, "service_alias:") {
			id := strings.TrimSpace(strings.TrimPrefix(key, "service_alias:"))
			if serviceIDMatchesDevice(id, deviceID) || serviceIDIndicatesCollector(id) {
				registerServiceType(id, serviceTypes)
			}
		}
	}

	if record != nil {
		for id := range record.Services {
			if serviceIDMatchesDevice(id, deviceID) || serviceIDIndicatesCollector(id) {
				registerServiceType(id, serviceTypes)
			}
		}
	}

	for _, source := range sources {
		registerServiceType(string(source.Source), serviceTypes)
	}

	return serviceTypes
}

func registerServiceType(value string, into map[string]struct{}) {
	cv := strings.ToLower(strings.TrimSpace(value))
	if cv == "" {
		return
	}
	if strings.Contains(cv, "icmp") || strings.Contains(cv, "ping") {
		into["icmp"] = struct{}{}
	}
	if strings.Contains(cv, "sysmon") {
		into["sysmon"] = struct{}{}
	}
	if strings.Contains(cv, "snmp") {
		into["snmp"] = struct{}{}
	}
}

func containsServiceType(values map[string]struct{}, key string) bool {
	_, ok := values[key]
	return ok
}

func serviceIDMatchesDevice(serviceID, deviceID string) bool {
	return strings.EqualFold(strings.TrimSpace(serviceID), strings.TrimSpace(deviceID))
}

func serviceIDIndicatesCollector(serviceID string) bool {
	id := strings.ToLower(strings.TrimSpace(serviceID))
	if id == "" {
		return false
	}
	return strings.Contains(id, ":collector:") || strings.Contains(id, ":checker:")
}
