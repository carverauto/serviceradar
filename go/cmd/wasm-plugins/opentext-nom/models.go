package main

import "time"

type InventoryDevice struct {
	IntegrationID    string         `json:"integration_id"`
	SourceObjectID   string         `json:"source_object_id"`
	Hostname         string         `json:"hostname,omitempty"`
	IP               string         `json:"ip,omitempty"`
	MAC              string         `json:"mac,omitempty"`
	Serial           string         `json:"serial,omitempty"`
	Vendor           string         `json:"vendor,omitempty"`
	Model            string         `json:"model,omitempty"`
	DeviceType       string         `json:"device_type,omitempty"`
	Partition        string         `json:"partition,omitempty"`
	ManagementStatus string         `json:"management_status,omitempty"`
	ExcludeFromPoll  *bool          `json:"exclude_from_poll,omitempty"`
	Metadata         map[string]any `json:"metadata,omitempty"`
}

type Snapshot struct {
	InstanceID        string
	CollectionID      string
	ObservedAt        time.Time
	QueryHash         string
	ContentHash       string
	Devices           []InventoryDevice
	Pages             int
	ReceivedRows      int
	InvalidRows       int
	DuplicateRows     int
	SnapshotComplete  bool
	AttachmentDevices []InventoryDevice
}

type networkAutomationDeviceRow struct {
	DeviceID         string
	Hostname         string
	IP               string
	MAC              string
	Serial           string
	ChassisSerials   []string
	Vendor           string
	Model            string
	DeviceType       string
	Partition        string
	ManagementStatus string
	ExcludeFromPoll  *bool
	SoftwareVersion  string
	FirmwareVersion  string
	DriverName       string
	ROMVersion       string
	Processor        string
	MemoryBytes      *int64
	TotalPorts       *int64
	FreePorts        *int64
	Contact          string
	GeoLocation      string
}
