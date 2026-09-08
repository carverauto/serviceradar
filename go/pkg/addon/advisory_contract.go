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

package addon

import "time"

const (
	// CapabilityAdvisoryFeedV1 marks add-ons or plugins that emit normalized
	// advisory feed batches. Download, validation, and feed-specific parsing stay
	// inside the producer; core only consumes this contract.
	CapabilityAdvisoryFeedV1 = "advisory-feed:v1"

	AdvisoryFeedContractVersion = "serviceradar.advisory_feed.contract.v1"

	CoordinateTypePURL          = "purl"
	CoordinateTypeCPE           = "cpe"
	CoordinateTypeVendorProduct = "vendor_product"
)

// AdvisoryFeedBatch is the top-level normalized vulnerability intelligence
// payload emitted by a producer. The producer may be a native add-on or a Wasm
// plugin; core should treat both the same way.
type AdvisoryFeedBatch struct {
	SchemaVersion string           `json:"schema_version"`
	ProducerID    string           `json:"producer_id"`
	Source        AdvisorySource   `json:"source"`
	Snapshot      AdvisorySnapshot `json:"snapshot"`
	Advisories    []AdvisoryRecord `json:"advisories"`
	Metadata      map[string]any   `json:"metadata,omitempty"`
}

// AdvisorySource describes the normalized source registration for matching and
// operator status. Provider and FeedKey identify the logical source; they do not
// imply that core knows how to download or parse the provider's native format.
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

// AdvisorySnapshot identifies the raw or normalized snapshot artifact already
// staged through the normal ServiceRadar artifact path.
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

// AdvisoryRecord is a provider-neutral vulnerability advisory row. Producers
// must normalize native records into this shape before submitting them to core.
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
// match against endpoint package/SBOM rows.
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
