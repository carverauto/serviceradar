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
	EdgeOnboardingStatusDeleted   EdgeOnboardingStatus = "deleted"
)

// EdgeOnboardingComponentType identifies the resource represented by a package.
type EdgeOnboardingComponentType string

const (
	EdgeOnboardingComponentTypeGateway  EdgeOnboardingComponentType = "gateway"
	EdgeOnboardingComponentTypeAgent   EdgeOnboardingComponentType = "agent"
	EdgeOnboardingComponentTypeChecker EdgeOnboardingComponentType = "checker"
	EdgeOnboardingComponentTypeSync    EdgeOnboardingComponentType = "sync"
	EdgeOnboardingComponentTypeNone    EdgeOnboardingComponentType = ""
)

// CollectorType identifies the type of data collector.
type CollectorType string

const (
	CollectorTypeFlowgger CollectorType = "flowgger" // Syslog collector (RFC 5424, RFC 3164)
	CollectorTypeTrapd    CollectorType = "trapd"    // SNMP trap collector (v1, v2c, v3)
	CollectorTypeNetflow  CollectorType = "netflow"  // NetFlow/sFlow/IPFIX collector
	CollectorTypeOtel     CollectorType = "otel"     // OpenTelemetry collector
)

// CollectorPackageStatus represents the lifecycle state of a collector package.
type CollectorPackageStatus string

const (
	CollectorPackageStatusPending      CollectorPackageStatus = "pending"
	CollectorPackageStatusProvisioning CollectorPackageStatus = "provisioning"
	CollectorPackageStatusReady        CollectorPackageStatus = "ready"
	CollectorPackageStatusDownloaded   CollectorPackageStatus = "downloaded"
	CollectorPackageStatusInstalled    CollectorPackageStatus = "installed"
	CollectorPackageStatusRevoked      CollectorPackageStatus = "revoked"
	CollectorPackageStatusFailed       CollectorPackageStatus = "failed"
)

var (
	ErrEdgeOnboardingDisabled          = errors.New("edge onboarding: service disabled")
	ErrEdgeOnboardingInvalidRequest    = errors.New("edge onboarding: invalid request")
	ErrEdgeOnboardingGatewayConflict    = errors.New("edge onboarding: gateway already provisioned")
	ErrEdgeOnboardingComponentConflict = errors.New("edge onboarding: component already provisioned")
	ErrEdgeOnboardingSpireUnavailable  = errors.New("edge onboarding: spire admin unavailable")
	ErrEdgeOnboardingDownloadRequired  = errors.New("edge onboarding: download token required")
	ErrEdgeOnboardingDownloadInvalid   = errors.New("edge onboarding: download token invalid")
	ErrEdgeOnboardingDownloadExpired   = errors.New("edge onboarding: download token expired")
	ErrEdgeOnboardingPackageDelivered  = errors.New("edge onboarding: package already delivered")
	ErrEdgeOnboardingPackageRevoked    = errors.New("edge onboarding: package revoked")
	ErrEdgeOnboardingDecryptFailed     = errors.New("edge onboarding: decrypt failed")
)

// EdgeOnboardingPackage models the material tracked for an edge gateway bootstrap.
type EdgeOnboardingPackage struct {
	PackageID              string                      `json:"package_id"`
	Label                  string                      `json:"label"`
	ComponentID            string                      `json:"component_id"`
	ComponentType          EdgeOnboardingComponentType `json:"component_type"`
	ParentType             EdgeOnboardingComponentType `json:"parent_type,omitempty"`
	ParentID               string                      `json:"parent_id,omitempty"`
	GatewayID               string                      `json:"gateway_id"`
	Site                   string                      `json:"site,omitempty"`
	Status                 EdgeOnboardingStatus        `json:"status"`
	SecurityMode           string                      `json:"security_mode,omitempty"`
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
	DeletedAt              *time.Time                  `json:"deleted_at,omitempty"`
	DeletedBy              string                      `json:"deleted_by,omitempty"`
	DeletedReason          string                      `json:"deleted_reason,omitempty"`
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
	GatewayID    string
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
	SecurityMode       string
	ParentID           string
	GatewayID           string
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
	DataSvcEndpoint    string // DataSvc gRPC endpoint (e.g., "23.138.124.23:50057")
}

// EdgeOnboardingCreateResult bundles the stored package and sensitive artifacts.
type EdgeOnboardingCreateResult struct {
	Package           *EdgeOnboardingPackage
	JoinToken         string
	DownloadToken     string
	BundlePEM         []byte
	MTLSBundle        []byte
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
	Package    *EdgeOnboardingPackage
	JoinToken  string
	BundlePEM  []byte
	MTLSBundle []byte
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

// EdgeTemplate represents an available component template in KV.
type EdgeTemplate struct {
	ComponentType EdgeOnboardingComponentType `json:"component_type"` // Component type (e.g., "checker")
	Kind          string                      `json:"kind"`           // Component kind (e.g., "sysmon", "snmp", "rperf")
	SecurityMode  string                      `json:"security_mode"`  // Security mode for the template (e.g., "mtls", "spire")
	TemplateKey   string                      `json:"template_key"`   // Full KV key path (e.g., "templates/checkers/mtls/sysmon.json")
}

// CollectorPackage represents a collector deployment package with NATS credentials.
type CollectorPackage struct {
	PackageID              string                 `json:"package_id"`
	TenantID               string                 `json:"tenant_id"`
	CollectorType          CollectorType          `json:"collector_type"`
	UserName               string                 `json:"user_name"`
	Site                   string                 `json:"site,omitempty"`
	Hostname               string                 `json:"hostname,omitempty"`
	Status                 CollectorPackageStatus `json:"status"`
	NatsCredentialID       string                 `json:"nats_credential_id,omitempty"`
	DownloadTokenHash      string                 `json:"download_token_hash,omitempty"`
	DownloadTokenExpiresAt time.Time              `json:"download_token_expires_at,omitempty"`
	DownloadedAt           *time.Time             `json:"downloaded_at,omitempty"`
	DownloadedByIP         string                 `json:"downloaded_by_ip,omitempty"`
	InstalledAt            *time.Time             `json:"installed_at,omitempty"`
	RevokedAt              *time.Time             `json:"revoked_at,omitempty"`
	RevokeReason           string                 `json:"revoke_reason,omitempty"`
	ErrorMessage           string                 `json:"error_message,omitempty"`
	ConfigOverrides        map[string]interface{} `json:"config_overrides,omitempty"`
	CreatedAt              time.Time              `json:"created_at"`
	UpdatedAt              time.Time              `json:"updated_at"`
}

// NatsCredential represents a NATS user credential issued to a collector.
type NatsCredential struct {
	CredentialID   string        `json:"credential_id"`
	TenantID       string        `json:"tenant_id"`
	UserName       string        `json:"user_name"`
	UserPublicKey  string        `json:"user_public_key"`
	CredentialType string        `json:"credential_type"` // collector, service, admin
	CollectorType  CollectorType `json:"collector_type,omitempty"`
	Status         string        `json:"status"` // active, revoked, expired
	IssuedAt       time.Time     `json:"issued_at"`
	ExpiresAt      *time.Time    `json:"expires_at,omitempty"`
	RevokedAt      *time.Time    `json:"revoked_at,omitempty"`
	RevokeReason   string        `json:"revoke_reason,omitempty"`
	Metadata       map[string]interface{} `json:"metadata,omitempty"`
}

// CollectorDownloadResult contains the package contents for a collector download.
type CollectorDownloadResult struct {
	Package         *CollectorPackage `json:"package"`
	NatsCredsFile   string            `json:"nats_creds_file"`   // .creds file content
	CollectorConfig string            `json:"collector_config"`  // Collector-specific config
	MTLSBundle      []byte            `json:"mtls_bundle"`       // mTLS certificates from tenant CA
	InstallScript   string            `json:"install_script"`    // Installation instructions
}
