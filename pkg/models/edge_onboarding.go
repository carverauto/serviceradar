package models

import "time"

// EdgeOnboardingStatus represents the lifecycle state of an onboarding package.
type EdgeOnboardingStatus string

const (
	EdgeOnboardingStatusIssued    EdgeOnboardingStatus = "issued"
	EdgeOnboardingStatusDelivered EdgeOnboardingStatus = "delivered"
	EdgeOnboardingStatusActivated EdgeOnboardingStatus = "activated"
	EdgeOnboardingStatusRevoked   EdgeOnboardingStatus = "revoked"
	EdgeOnboardingStatusExpired   EdgeOnboardingStatus = "expired"
)

// EdgeOnboardingPackage models the material tracked for an edge poller bootstrap.
type EdgeOnboardingPackage struct {
	PackageID              string               `json:"package_id"`
	Label                  string               `json:"label"`
	PollerID               string               `json:"poller_id"`
	Site                   string               `json:"site,omitempty"`
	Status                 EdgeOnboardingStatus `json:"status"`
	DownstreamSPIFFEID     string               `json:"downstream_spiffe_id"`
	Selectors              []string             `json:"selectors,omitempty"`
	JoinTokenCiphertext    string               `json:"join_token_ciphertext"`
	JoinTokenExpiresAt     time.Time            `json:"join_token_expires_at"`
	BundleCiphertext       string               `json:"bundle_ciphertext"`
	DownloadTokenHash      string               `json:"download_token_hash"`
	DownloadTokenExpiresAt time.Time            `json:"download_token_expires_at"`
	CreatedBy              string               `json:"created_by"`
	CreatedAt              time.Time            `json:"created_at"`
	UpdatedAt              time.Time            `json:"updated_at"`
	DeliveredAt            *time.Time           `json:"delivered_at,omitempty"`
	ActivatedAt            *time.Time           `json:"activated_at,omitempty"`
	ActivatedFromIP        *string              `json:"activated_from_ip,omitempty"`
	LastSeenSPIFFEID       *string              `json:"last_seen_spiffe_id,omitempty"`
	RevokedAt              *time.Time           `json:"revoked_at,omitempty"`
	MetadataJSON           string               `json:"metadata_json,omitempty"`
	Notes                  string               `json:"notes,omitempty"`
}

// EdgeOnboardingEvent captures audit trail entries for onboarding packages.
type EdgeOnboardingEvent struct {
	PackageID   string    `json:"package_id"`
	EventTime   time.Time `json:"event_time"`
	EventType   string    `json:"event_type"`
	Actor       string    `json:"actor"`
	SourceIP    string    `json:"source_ip,omitempty"`
	DetailsJSON string    `json:"details_json,omitempty"`
}

// EdgeOnboardingListFilter allows filtering onboarding packages.
type EdgeOnboardingListFilter struct {
	PollerID string
	Statuses []EdgeOnboardingStatus
	Limit    int
}
