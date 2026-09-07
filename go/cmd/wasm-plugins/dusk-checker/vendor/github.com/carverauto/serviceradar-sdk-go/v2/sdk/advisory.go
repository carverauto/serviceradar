package sdk

import "time"

const (
	// CapabilityAdvisoryFeedV1 marks plugins that emit normalized advisory feed
	// batches. Provider-specific download and parsing stay inside the plugin.
	CapabilityAdvisoryFeedV1 = "advisory-feed:v1"

	AdvisoryFeedContractVersion = "serviceradar.advisory_feed.contract.v1"

	CoordinateTypePURL          = "purl"
	CoordinateTypeCPE           = "cpe"
	CoordinateTypeVendorProduct = "vendor_product"
)

// AdvisoryFeedBatch is the top-level normalized vulnerability intelligence
// payload emitted by a Wasm plugin or native add-on.
type AdvisoryFeedBatch struct {
	SchemaVersion string           `json:"schema_version"`
	ProducerID    string           `json:"producer_id"`
	Source        AdvisorySource   `json:"source"`
	Snapshot      AdvisorySnapshot `json:"snapshot"`
	Advisories    []AdvisoryRecord `json:"advisories"`
	Metadata      map[string]any   `json:"metadata,omitempty"`
}

// AdvisorySource identifies the logical feed source for matching and operator
// status. It does not imply that core knows how to fetch or parse that provider.
type AdvisorySource struct {
	Provider               string         `json:"provider"`
	FeedKey                string         `json:"feed_key"`
	DisplayName            string         `json:"display_name,omitempty"`
	FeedType               string         `json:"feed_type,omitempty"`
	Enabled                bool           `json:"enabled"`
	URL                    string         `json:"url,omitempty"`
	SchemaURL              string         `json:"schema_url,omitempty"`
	RefreshIntervalSeconds int            `json:"refresh_interval_seconds,omitempty"`
	RetentionDays          int            `json:"retention_days,omitempty"`
	CredentialRef          string         `json:"credential_ref,omitempty"`
	Options                map[string]any `json:"options,omitempty"`
	LastMessage            string         `json:"last_message,omitempty"`
	Metadata               map[string]any `json:"metadata,omitempty"`
}

// AdvisorySnapshot identifies a raw or normalized snapshot artifact staged
// through gateway-mediated artifact APIs.
type AdvisorySnapshot struct {
	ObjectKey      string         `json:"object_key"`
	SHA256         string         `json:"sha256"`
	SourceURL      string         `json:"source_url,omitempty"`
	ContentType    string         `json:"content_type,omitempty"`
	Format         string         `json:"format,omitempty"`
	SizeBytes      int64          `json:"size_bytes,omitempty"`
	StorageBackend string         `json:"storage_backend,omitempty"`
	Accepted       bool           `json:"accepted"`
	Status         string         `json:"status,omitempty"`
	Error          string         `json:"error,omitempty"`
	Validation     map[string]any `json:"validation,omitempty"`
	FetchedAt      time.Time      `json:"fetched_at,omitempty"`
	AcceptedAt     time.Time      `json:"accepted_at,omitempty"`
	Metadata       map[string]any `json:"metadata,omitempty"`
}

// AdvisoryRecord is a provider-neutral vulnerability advisory row.
type AdvisoryRecord struct {
	SourceObjectID      string               `json:"source_object_id"`
	AdvisoryID          string               `json:"advisory_id"`
	CVEID               string               `json:"cve_id,omitempty"`
	Title               string               `json:"title,omitempty"`
	Description         string               `json:"description,omitempty"`
	Severity            string               `json:"severity,omitempty"`
	CVSSScore           float64              `json:"cvss_score,omitempty"`
	CVSSVector          string               `json:"cvss_vector,omitempty"`
	PublishedAt         time.Time            `json:"published_at,omitempty"`
	ModifiedAt          time.Time            `json:"modified_at,omitempty"`
	KEV                 bool                 `json:"kev,omitempty"`
	ExploitAvailable    bool                 `json:"exploit_available,omitempty"`
	AffectedCoordinates []AffectedCoordinate `json:"affected_coordinates"`
	References          []string             `json:"references,omitempty"`
	Metadata            map[string]any       `json:"metadata,omitempty"`
}

// AffectedCoordinate is an already-normalized package coordinate that core can
// match against endpoint package or SBOM rows.
type AffectedCoordinate struct {
	Type           string           `json:"type"`
	Value          string           `json:"value,omitempty"`
	Vendor         string           `json:"vendor,omitempty"`
	Product        string           `json:"product,omitempty"`
	MatchSemantics string           `json:"match_semantics,omitempty"`
	VersionRange   map[string]any   `json:"version_range,omitempty"`
	VersionRanges  []map[string]any `json:"version_ranges,omitempty"`
	Metadata       map[string]any   `json:"metadata,omitempty"`
}

func NewAdvisoryFeedBatch(producerID string, source AdvisorySource, snapshot AdvisorySnapshot) AdvisoryFeedBatch {
	return AdvisoryFeedBatch{
		SchemaVersion: AdvisoryFeedContractVersion,
		ProducerID:    producerID,
		Source:        source,
		Snapshot:      snapshot,
	}
}

func (b *AdvisoryFeedBatch) AddAdvisory(advisory AdvisoryRecord) {
	b.Advisories = append(b.Advisories, advisory)
}

func (b AdvisoryFeedBatch) WithAdvisory(advisory AdvisoryRecord) AdvisoryFeedBatch {
	b.AddAdvisory(advisory)
	return b
}

func (b AdvisoryFeedBatch) WithMetadata(key string, value any) AdvisoryFeedBatch {
	if key == "" {
		return b
	}
	if b.Metadata == nil {
		b.Metadata = make(map[string]any)
	}
	b.Metadata[key] = value
	return b
}

func NewAdvisorySource(provider, feedKey string) AdvisorySource {
	return AdvisorySource{Provider: provider, FeedKey: feedKey, Enabled: true}
}

func (s AdvisorySource) WithDisplayName(displayName string) AdvisorySource {
	s.DisplayName = displayName
	return s
}

func (s AdvisorySource) WithCredentialRef(credentialRef string) AdvisorySource {
	s.CredentialRef = credentialRef
	return s
}

func NewAdvisorySnapshot(objectKey, sha256 string) AdvisorySnapshot {
	return AdvisorySnapshot{ObjectKey: objectKey, SHA256: sha256, Accepted: true, Status: "accepted"}
}

func (s AdvisorySnapshot) WithContentType(contentType string) AdvisorySnapshot {
	s.ContentType = contentType
	return s
}

func (s AdvisorySnapshot) WithSizeBytes(sizeBytes int64) AdvisorySnapshot {
	s.SizeBytes = sizeBytes
	return s
}

func NewAdvisoryRecord(advisoryID string) AdvisoryRecord {
	return AdvisoryRecord{SourceObjectID: advisoryID, AdvisoryID: advisoryID}
}

func (a AdvisoryRecord) WithCVE(cveID string) AdvisoryRecord {
	a.CVEID = cveID
	if a.AdvisoryID == "" {
		a.AdvisoryID = cveID
	}
	if a.SourceObjectID == "" {
		a.SourceObjectID = cveID
	}
	return a
}

func (a AdvisoryRecord) WithSeverity(severity string) AdvisoryRecord {
	a.Severity = severity
	return a
}

func (a AdvisoryRecord) WithCoordinate(coordinate AffectedCoordinate) AdvisoryRecord {
	a.AffectedCoordinates = append(a.AffectedCoordinates, coordinate)
	return a
}

func (a AdvisoryRecord) WithReference(ref string) AdvisoryRecord {
	if ref != "" {
		a.References = append(a.References, ref)
	}
	return a
}

func NewPURLCoordinate(value string) AffectedCoordinate {
	return AffectedCoordinate{Type: CoordinateTypePURL, Value: value}
}

func NewCPECoordinate(value string) AffectedCoordinate {
	return AffectedCoordinate{Type: CoordinateTypeCPE, Value: value}
}

func NewVendorProductCoordinate(vendor, product string) AffectedCoordinate {
	return AffectedCoordinate{Type: CoordinateTypeVendorProduct, Vendor: vendor, Product: product}
}

func (c AffectedCoordinate) WithMatchSemantics(matchSemantics string) AffectedCoordinate {
	c.MatchSemantics = matchSemantics
	return c
}

func (c AffectedCoordinate) WithVersionRange(versionRange map[string]any) AffectedCoordinate {
	c.VersionRanges = append(c.VersionRanges, versionRange)
	return c
}
