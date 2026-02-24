package models

import "time"

// NetworkSightingStatus represents the lifecycle state for a sighting.
type NetworkSightingStatus string

const (
	SightingStatusActive    NetworkSightingStatus = "active"
	SightingStatusPromoted  NetworkSightingStatus = "promoted"
	SightingStatusExpired   NetworkSightingStatus = "expired"
	SightingStatusDismissed NetworkSightingStatus = "dismissed"
)

// NetworkSighting captures a low-confidence observation prior to promotion.
type NetworkSighting struct {
	SightingID    string                   `json:"sighting_id,omitempty"`
	Partition     string                   `json:"partition"`
	IP            string                   `json:"ip"`
	SubnetID      *string                  `json:"subnet_id,omitempty"`
	Source        DiscoverySource          `json:"source"`
	Status        NetworkSightingStatus    `json:"status"`
	FirstSeen     time.Time                `json:"first_seen"`
	LastSeen      time.Time                `json:"last_seen"`
	TTLExpiresAt  *time.Time               `json:"ttl_expires_at,omitempty"`
	FingerprintID *string                  `json:"fingerprint_id,omitempty"`
	Metadata      map[string]string        `json:"metadata,omitempty"`
	Promotion     *SightingPromotionStatus `json:"promotion,omitempty"`
}

// DeviceIdentifier captures a normalized identifier tied to a device.
type DeviceIdentifier struct {
	DeviceID   string            `json:"device_id"`
	IDType     string            `json:"id_type"`
	IDValue    string            `json:"id_value"`
	Partition  string            `json:"partition,omitempty"`
	Confidence string            `json:"confidence"`
	Source     string            `json:"source,omitempty"`
	FirstSeen  time.Time         `json:"first_seen"`
	LastSeen   time.Time         `json:"last_seen"`
	Verified   bool              `json:"verified,omitempty"`
	Metadata   map[string]string `json:"metadata,omitempty"`
}

// SightingEvent tracks lifecycle events for sightings.
type SightingEvent struct {
	EventID    string            `json:"event_id,omitempty"`
	SightingID string            `json:"sighting_id"`
	DeviceID   string            `json:"device_id,omitempty"`
	EventType  string            `json:"event_type"`
	Actor      string            `json:"actor"`
	Details    map[string]string `json:"details,omitempty"`
	CreatedAt  time.Time         `json:"created_at"`
}

// SubnetPolicy captures promotion/reaper behavior for a subnet.
type SubnetPolicy struct {
	SubnetID       string                 `json:"subnet_id"`
	CIDR           string                 `json:"cidr"`
	Classification string                 `json:"classification"`
	PromotionRules map[string]interface{} `json:"promotion_rules,omitempty"`
	ReaperProfile  string                 `json:"reaper_profile"`
	AllowIPAsID    bool                   `json:"allow_ip_as_id"`
	CreatedAt      time.Time              `json:"created_at"`
	UpdatedAt      time.Time              `json:"updated_at"`
}

// MergeAuditEvent records merges between devices for auditability.
type MergeAuditEvent struct {
	EventID         string            `json:"event_id"`
	FromDeviceID    string            `json:"from_device_id"`
	ToDeviceID      string            `json:"to_device_id"`
	Reason          string            `json:"reason,omitempty"`
	ConfidenceScore *float64          `json:"confidence_score,omitempty"`
	Source          string            `json:"source,omitempty"`
	Details         map[string]string `json:"details,omitempty"`
	CreatedAt       time.Time         `json:"created_at"`
}

// SightingPromotionStatus captures promotion eligibility and blockers for a sighting.
type SightingPromotionStatus struct {
	MeetsPolicy    bool       `json:"meets_policy"`
	Eligible       bool       `json:"eligible"`
	ShadowMode     bool       `json:"shadow_mode,omitempty"`
	Blockers       []string   `json:"blockers,omitempty"`
	Satisfied      []string   `json:"satisfied,omitempty"`
	NextEligibleAt *time.Time `json:"next_eligible_at,omitempty"`
}
