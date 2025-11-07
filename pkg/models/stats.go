package models

import "time"

// PartitionStats captures per-partition device counts for dashboard consumption.
type PartitionStats struct {
	PartitionID    string `json:"partition_id"`
	DeviceCount    int    `json:"device_count"`
	ActiveCount    int    `json:"active_count"`
	AvailableCount int    `json:"available_count"`
}

// DeviceStatsSnapshot aggregates system-wide device metrics that are expensive to
// compute directly from Proton. The core Service publishes updates at a fixed cadence.
type DeviceStatsSnapshot struct {
	Timestamp             time.Time        `json:"timestamp"`
	TotalDevices          int              `json:"total_devices"`
	AvailableDevices      int              `json:"available_devices"`
	UnavailableDevices    int              `json:"unavailable_devices"`
	ActiveDevices         int              `json:"active_devices"`
	DevicesWithCollectors int              `json:"devices_with_collectors"`
	DevicesWithICMP       int              `json:"devices_with_icmp"`
	DevicesWithSNMP       int              `json:"devices_with_snmp"`
	DevicesWithSysmon     int              `json:"devices_with_sysmon"`
	Partitions            []PartitionStats `json:"partitions"`
}

// DeviceStatsMeta captures bookkeeping details for debugging the stats snapshot pipeline.
type DeviceStatsMeta struct {
	RawRecords                int `json:"raw_records"`
	ProcessedRecords          int `json:"processed_records"`
	SkippedNilRecords         int `json:"skipped_nil_records"`
	SkippedTombstonedRecords  int `json:"skipped_tombstoned_records"`
	SkippedServiceComponents  int `json:"skipped_service_components"`
	SkippedNonCanonical       int `json:"skipped_non_canonical_records"`
	InferredCanonicalFallback int `json:"inferred_canonical_records"`
}
