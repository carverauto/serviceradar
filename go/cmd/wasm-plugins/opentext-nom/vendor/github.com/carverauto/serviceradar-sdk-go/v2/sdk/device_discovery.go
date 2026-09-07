package sdk

// DeviceDiscovery is a plugin-emitted inventory discovery/enrichment envelope.
type DeviceDiscovery struct {
	Schema        string             `json:"schema"`
	CollectionID  string             `json:"collection_id,omitempty"`
	Source        string             `json:"source,omitempty"`
	ObservedAt    string             `json:"observed_at,omitempty"`
	Devices       []DiscoveredDevice `json:"devices,omitempty"`
	ReferenceHash string             `json:"reference_hash,omitempty"`
	Metadata      map[string]any     `json:"metadata,omitempty"`
}

// DiscoveredDevice describes a device that core should reconcile into inventory.
type DiscoveredDevice struct {
	DeviceID    string            `json:"device_id,omitempty"`
	Hostname    string            `json:"hostname,omitempty"`
	IP          string            `json:"ip,omitempty"`
	MAC         string            `json:"mac,omitempty"`
	Serial      string            `json:"serial,omitempty"`
	VendorName  string            `json:"vendor_name,omitempty"`
	Model       string            `json:"model,omitempty"`
	Type        string            `json:"type,omitempty"`
	Role        string            `json:"role,omitempty"`
	Status      string            `json:"status,omitempty"`
	IsAvailable *bool             `json:"is_available,omitempty"`
	Location    *DeviceLocation   `json:"location,omitempty"`
	Labels      map[string]string `json:"labels,omitempty"`
	Metadata    map[string]any    `json:"metadata,omitempty"`
}

// DeviceLocation carries optional mappable location metadata for a device.
type DeviceLocation struct {
	SiteCode  string  `json:"site_code,omitempty"`
	SiteName  string  `json:"site_name,omitempty"`
	Latitude  float64 `json:"latitude,omitempty"`
	Longitude float64 `json:"longitude,omitempty"`
}

const DeviceDiscoverySchemaV1 = "serviceradar.device_discovery.v1"

func NewDeviceDiscovery(source string) *DeviceDiscovery {
	return &DeviceDiscovery{Schema: DeviceDiscoverySchemaV1, Source: source}
}

func (d *DeviceDiscovery) AddDevice(device DiscoveredDevice) {
	if d == nil {
		return
	}

	d.Devices = append(d.Devices, device)
}

func (d *DeviceDiscovery) WithDevice(device DiscoveredDevice) *DeviceDiscovery {
	d.AddDevice(device)
	return d
}

func (r *Result) AddDeviceDiscovery(discovery DeviceDiscovery) {
	if discovery.Schema == "" {
		discovery.Schema = DeviceDiscoverySchemaV1
	}

	r.DeviceDiscovery = append(r.DeviceDiscovery, discovery)
}

func (r *Result) WithDeviceDiscovery(discovery DeviceDiscovery) *Result {
	r.AddDeviceDiscovery(discovery)
	return r
}
