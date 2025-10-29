package models

import (
	"errors"
	"time"
)

// EdgeOnboardingStatus represents the lifecycle state of an onboarding package.
type EdgeOnboardingStatus string

const (
	EdgeOnboardingStatusIssued    EdgeOnboardingStatus = "issued"
	EdgeOnboardingStatusDelivered EdgeOnboardingStatus = "delivered"
	EdgeOnboardingStatusActivated EdgeOnboardingStatus = "activated"
	EdgeOnboardingStatusRevoked   EdgeOnboardingStatus = "revoked"
	EdgeOnboardingStatusExpired   EdgeOnboardingStatus = "expired"
)

// EdgeOnboardingComponentType identifies the resource represented by a package.
type EdgeOnboardingComponentType string

const (
	EdgeOnboardingComponentTypePoller  EdgeOnboardingComponentType = "poller"
	EdgeOnboardingComponentTypeAgent   EdgeOnboardingComponentType = "agent"
	EdgeOnboardingComponentTypeChecker EdgeOnboardingComponentType = "checker"
	EdgeOnboardingComponentTypeNone    EdgeOnboardingComponentType = ""
)

var (
	ErrEdgeOnboardingDisabled          = errors.New("edge onboarding: service disabled")
	ErrEdgeOnboardingInvalidRequest    = errors.New("edge onboarding: invalid request")
	ErrEdgeOnboardingPollerConflict    = errors.New("edge onboarding: poller already provisioned")
	ErrEdgeOnboardingComponentConflict = errors.New("edge onboarding: component already provisioned")
	ErrEdgeOnboardingSpireUnavailable  = errors.New("edge onboarding: spire admin unavailable")
	ErrEdgeOnboardingDownloadRequired  = errors.New("edge onboarding: download token required")
	ErrEdgeOnboardingDownloadInvalid   = errors.New("edge onboarding: download token invalid")
	ErrEdgeOnboardingDownloadExpired   = errors.New("edge onboarding: download token expired")
	ErrEdgeOnboardingPackageDelivered  = errors.New("edge onboarding: package already delivered")
	ErrEdgeOnboardingPackageRevoked    = errors.New("edge onboarding: package revoked")
)

// EdgeOnboardingPackage models the material tracked for an edge poller bootstrap.
type EdgeOnboardingPackage struct {
	PackageID              string                      `json:"package_id"`
	Label                  string                      `json:"label"`
	ComponentID            string                      `json:"component_id"`
	ComponentType          EdgeOnboardingComponentType `json:"component_type"`
	ParentType             EdgeOnboardingComponentType `json:"parent_type,omitempty"`
	ParentID               string                      `json:"parent_id,omitempty"`
	PollerID               string                      `json:"poller_id"`
	Site                   string                      `json:"site,omitempty"`
	Status                 EdgeOnboardingStatus        `json:"status"`
	DownstreamEntryID      string                      `json:"downstream_entry_id,omitempty"`
	DownstreamSPIFFEID     string                      `json:"downstream_spiffe_id"`
	Selectors              []string                    `json:"selectors,omitempty"`
	JoinTokenCiphertext    string                      `json:"join_token_ciphertext"`
	JoinTokenExpiresAt     time.Time                   `json:"join_token_expires_at"`
	BundleCiphertext       string                      `json:"bundle_ciphertext"`
	DownloadTokenHash      string                      `json:"download_token_hash"`
	DownloadTokenExpiresAt time.Time                   `json:"download_token_expires_at"`
	CreatedBy              string                      `json:"created_by"`
	CreatedAt              time.Time                   `json:"created_at"`
	UpdatedAt              time.Time                   `json:"updated_at"`
	DeliveredAt            *time.Time                  `json:"delivered_at,omitempty"`
	ActivatedAt            *time.Time                  `json:"activated_at,omitempty"`
	ActivatedFromIP        *string                     `json:"activated_from_ip,omitempty"`
	LastSeenSPIFFEID       *string                     `json:"last_seen_spiffe_id,omitempty"`
	RevokedAt              *time.Time                  `json:"revoked_at,omitempty"`
	MetadataJSON           string                      `json:"metadata_json,omitempty"`
	CheckerKind            string                      `json:"checker_kind,omitempty"`
	CheckerConfigJSON      string                      `json:"checker_config_json,omitempty"`
	KVRevision             uint64                      `json:"kv_revision,omitempty"`
	Notes                  string                      `json:"notes,omitempty"`
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
	PollerID    string
	ComponentID string
	ParentID    string
	Statuses    []EdgeOnboardingStatus
	Limit       int
	Types       []EdgeOnboardingComponentType
}

// EdgeOnboardingCreateRequest drives package provisioning.
type EdgeOnboardingCreateRequest struct {
	Label              string
	ComponentID        string
	ComponentType      EdgeOnboardingComponentType
	ParentType         EdgeOnboardingComponentType
	ParentID           string
	PollerID           string
	Site               string
	Selectors          []string
	MetadataJSON       string
	CheckerKind        string
	CheckerConfigJSON  string
	Notes              string
	CreatedBy          string
	JoinTokenTTL       time.Duration
	DownloadTokenTTL   time.Duration
	DownstreamSPIFFEID string
}

// EdgeOnboardingCreateResult bundles the stored package and sensitive artifacts.
type EdgeOnboardingCreateResult struct {
	Package           *EdgeOnboardingPackage
	JoinToken         string
	DownloadToken     string
	BundlePEM         []byte
	DownstreamEntryID string
}

// EdgeOnboardingDeliverRequest captures download token verification.
type EdgeOnboardingDeliverRequest struct {
	PackageID     string
	DownloadToken string
	Actor         string
	SourceIP      string
}

// EdgeOnboardingDeliverResult contains decrypted artifacts for installers.
type EdgeOnboardingDeliverResult struct {
	Package   *EdgeOnboardingPackage
	JoinToken string
	BundlePEM []byte
}

// EdgeOnboardingRevokeRequest describes a package revocation.
type EdgeOnboardingRevokeRequest struct {
	PackageID string
	Actor     string
	Reason    string
	SourceIP  string
}

// EdgeOnboardingRevokeResult returns the updated package after revocation.
type EdgeOnboardingRevokeResult struct {
	Package *EdgeOnboardingPackage
}
