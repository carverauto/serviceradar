package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"
)

const (
	projectionVersion = 2
	// Keep one bounded frame per advisory while leaving explicit headroom for
	// normal publication growth.
	maxProjectionFrameBytes     = 64 << 20
	maxProductSetMembers        = 65_536
	maxProductSetCanonicalSize  = 16 << 20
	maxSeenProducts             = 2_000_000
	maxSeenProductSets          = 250_000
	maxPURLBytes                = 2_048
	maxEvidenceBytes            = 4_096
	maxAssertionObjectBytes     = 8 << 10
	maxDescriptionBytes         = 1 << 20
	maxReferences               = 8_192
	maxQualifiers               = 64
	maxProductDepth             = 64
	maxLogicalProductsPerRecord = 250_000
	maxAssertionsPerRecord      = 65_536

	productDomain             = "serviceradar.ubuntu.product.v2"
	productLookupDomain       = "serviceradar.ubuntu.product-lookup.v2"
	productSetDomain          = "serviceradar.ubuntu.product-set.v2"
	osvAssertionDomain        = "serviceradar.ubuntu.osv-assertion.v2"
	vexStatementDomain        = "serviceradar.ubuntu.vex-statement.v2"
	vexAssertionDomain        = "serviceradar.ubuntu.vex-assertion.v2"
	advisoryDigestDomain      = "serviceradar.ubuntu.advisory.v2"
	coordinateDigestDomain    = "serviceradar.ubuntu.coordinate.v2"
	coordinatesDigestDomain   = "serviceradar.ubuntu.coordinates.v2"
	assertionRefDigestDomain  = "serviceradar.ubuntu.projection-assertion-ref.v2"
	assertionRefsDigestDomain = "serviceradar.ubuntu.projection-assertions.v2"
	projectionDigestDomain    = "serviceradar.ubuntu.projection.v2"
	canonicalTombstoneContext = "https://openvex.dev/ns/v0.2.0"
	canonicalAuthor           = "Canonical Ltd."
	sourceArchitecture        = "source"
)

type projectedRecord struct {
	ProtocolVersion  int             `json:"protocol_version"`
	CVEID            string          `json:"cve_id"`
	ProjectionDigest string          `json:"projection_digest"`
	Advisory         advisorySummary `json:"advisory"`
	Coordinates      []coordinateDTO `json:"coordinates"`
	Products         []productDTO    `json:"products"`
	ProductSets      []productSetDTO `json:"product_sets"`
	Assertions       []assertionDTO  `json:"assertions"`
}

type advisorySummary struct {
	SourceObjectID string             `json:"source_object_id"`
	AdvisoryID     string             `json:"advisory_id"`
	CVEID          string             `json:"cve_id"`
	Title          string             `json:"title"`
	Description    string             `json:"description,omitempty"`
	Severity       string             `json:"severity,omitempty"`
	CVSSVector     string             `json:"cvss_vector,omitempty"`
	PublishedAt    string             `json:"published_at,omitempty"`
	ModifiedAt     string             `json:"modified_at,omitempty"`
	WithdrawnAt    string             `json:"withdrawn_at,omitempty"`
	References     []string           `json:"references"`
	Provenance     advisoryProvenance `json:"provenance"`
}

type advisoryProvenance struct {
	NormalizationVersion        int    `json:"normalization_version"`
	OSVPresent                  bool   `json:"osv_present"`
	VEXPresent                  bool   `json:"vex_present"`
	OSVArchiveSHA256            string `json:"osv_archive_sha256,omitempty"`
	VEXArchiveSHA256            string `json:"vex_archive_sha256,omitempty"`
	OSVDocumentSHA256           string `json:"osv_document_sha256,omitempty"`
	VEXDocumentSHA256           string `json:"vex_document_sha256,omitempty"`
	OSVWithdrawn                bool   `json:"osv_withdrawn"`
	VEXEmptyStatementsTombstone bool   `json:"vex_empty_statements_tombstone"`
	OSVAffectedCount            int    `json:"osv_affected_count"`
	VEXStatementCount           int    `json:"vex_statement_count"`
	RepairedSourcePURLCount     int    `json:"repaired_source_purl_count"`
}

type coordinateDTO struct {
	CoordinateType string            `json:"coordinate_type"`
	Value          string            `json:"value"`
	Metadata       map[string]string `json:"metadata"`
}

type productDTO struct {
	ID                   string            `json:"id"`
	Digest               string            `json:"digest"`
	LookupKey            string            `json:"lookup_key"`
	CanonicalSizeBytes   int               `json:"canonical_size_bytes"`
	NormalizationVersion int               `json:"normalization_version"`
	PackageType          string            `json:"package_type"`
	Namespace            string            `json:"namespace"`
	Name                 string            `json:"name"`
	Version              string            `json:"version"`
	Release              string            `json:"release,omitempty"`
	ReleaseChannel       string            `json:"release_channel,omitempty"`
	Distro               string            `json:"distro,omitempty"`
	Architecture         string            `json:"architecture,omitempty"`
	SourceName           string            `json:"source_name,omitempty"`
	SourceVersion        string            `json:"source_version,omitempty"`
	PURL                 string            `json:"purl"`
	Scope                string            `json:"scope"`
	ParentProductID      string            `json:"parent_product_id,omitempty"`
	Qualifiers           map[string]string `json:"qualifiers"`
	Metadata             productMetadata   `json:"metadata"`
}

type productMetadata struct {
	MissingRelease     bool   `json:"missing_release"`
	SourcePURLRepaired bool   `json:"source_purl_repaired,omitempty"`
	RawSourcePURL      string `json:"raw_source_purl,omitempty"`
}

type productSetDTO struct {
	ID                   string   `json:"id"`
	Digest               string   `json:"digest"`
	ProductIDs           []string `json:"product_ids"`
	Count                int      `json:"count"`
	CanonicalSizeBytes   int      `json:"canonical_size_bytes"`
	NormalizationVersion int      `json:"normalization_version"`
}

type assertionDTO struct {
	AssertionKey         string         `json:"assertion_key"`
	StatementFingerprint string         `json:"statement_fingerprint,omitempty"`
	FingerprintAliases   []string       `json:"fingerprint_aliases,omitempty"`
	CVEID                string         `json:"cve_id"`
	SourceKind           string         `json:"source_kind"`
	Authority            string         `json:"authority"`
	SourceTimestamp      string         `json:"source_timestamp"`
	Disposition          string         `json:"disposition"`
	ProductSetRef        string         `json:"product_set_ref,omitempty"`
	ProductSetDigest     string         `json:"product_set_digest,omitempty"`
	PackageType          string         `json:"package_type"`
	Namespace            string         `json:"namespace"`
	Release              string         `json:"release,omitempty"`
	ReleaseChannel       string         `json:"release_channel,omitempty"`
	VersionScheme        string         `json:"version_scheme"`
	ProductScope         string         `json:"product_scope"`
	SourcePackage        string         `json:"source_package,omitempty"`
	PackagePURL          string         `json:"package_purl,omitempty"`
	IntroducedVersion    string         `json:"introduced_version,omitempty"`
	FixedVersion         string         `json:"fixed_version,omitempty"`
	AffectedVersions     []string       `json:"affected_versions,omitempty"`
	Justification        string         `json:"justification,omitempty"`
	StatusText           string         `json:"status_text,omitempty"`
	ActionText           string         `json:"action_text,omitempty"`
	Validation           map[string]any `json:"validation"`
	Provenance           map[string]any `json:"provenance"`
	Metadata             map[string]any `json:"metadata"`
}

type projectionCounters struct {
	OSVDocuments              int64
	VEXDocuments              int64
	WithdrawnDocuments        int64
	VEXTombstones             int64
	OSVAffectedEntries        int64
	VEXStatements             int64
	LogicalProductOccurrences int64
	Assertions                int64
	UnscopedProducts          int64
	RepairedSourcePURLs       int64
}

type terminalDTO struct {
	ProtocolVersion               int   `json:"protocol_version"`
	CVECount                      int64 `json:"cve_count"`
	RecordCount                   int64 `json:"record_count"`
	OSVDocumentCount              int64 `json:"osv_document_count"`
	VEXDocumentCount              int64 `json:"vex_document_count"`
	OSVCount                      int64 `json:"osv_count"`
	VEXCount                      int64 `json:"vex_count"`
	WithdrawnDocumentCount        int64 `json:"withdrawn_document_count"`
	VEXTombstoneCount             int64 `json:"vex_tombstone_count"`
	OSVAffectedEntryCount         int64 `json:"osv_affected_entry_count"`
	VEXStatementCount             int64 `json:"vex_statement_count"`
	LogicalProductOccurrenceCount int64 `json:"logical_product_occurrence_count"`
	UniqueProductCount            int64 `json:"unique_product_count"`
	UniqueProductSetCount         int64 `json:"unique_product_set_count"`
	AssertionCount                int64 `json:"assertion_count"`
	UnscopedProductCount          int64 `json:"unscoped_product_count"`
	RepairedSourcePURLCount       int64 `json:"repaired_source_purl_count"`
	EmittedBytes                  int64 `json:"emitted_bytes"`
	EmittedFrameCount             int64 `json:"emitted_frame_count"`
	MaxFrameBytes                 int64 `json:"max_frame_bytes"`
	OSVMembers                    int64 `json:"osv_members"`
	VEXMembers                    int64 `json:"vex_members"`
	OSVSpoolBytes                 int64 `json:"osv_spool_bytes"`
	VEXSpoolBytes                 int64 `json:"vex_spool_bytes"`
	PeakWorkBytes                 int64 `json:"peak_work_bytes"`
}

type projectionState struct {
	seenProducts map[string]string
	seenSets     map[string]string
	counters     projectionCounters
}

func newProjectionState() *projectionState {
	return &projectionState{
		seenProducts: make(map[string]string),
		seenSets:     make(map[string]string),
	}
}

type rawOSV struct {
	ID         string         `json:"id"`
	Details    string         `json:"details"`
	Aliases    []string       `json:"aliases"`
	Upstream   []string       `json:"upstream"`
	Related    []string       `json:"related"`
	Severity   []osvSeverity  `json:"severity"`
	Published  string         `json:"published"`
	Modified   string         `json:"modified"`
	Withdrawn  string         `json:"withdrawn"`
	Affected   []osvAffected  `json:"affected"`
	References []osvReference `json:"references"`
}

type osvSeverity struct {
	Type  string `json:"type"`
	Score string `json:"score"`
}

type osvReference struct {
	Type string `json:"type"`
	URL  string `json:"url"`
}

type osvAffected struct {
	Package struct {
		Ecosystem string `json:"ecosystem"`
		Name      string `json:"name"`
		PURL      string `json:"purl"`
	} `json:"package"`
	Ranges            []osvRange `json:"ranges"`
	Versions          []string   `json:"versions"`
	EcosystemSpecific struct {
		Binaries []osvBinary `json:"binaries"`
	} `json:"ecosystem_specific"`
}

type osvRange struct {
	Type   string                       `json:"type"`
	Events []map[string]json.RawMessage `json:"events"`
}

type osvBinary struct {
	Name    string `json:"binary_name"`
	Version string `json:"binary_version"`
}

type rawVEX struct {
	Context     string         `json:"@context"`
	ID          string         `json:"@id"`
	Author      string         `json:"author"`
	Timestamp   string         `json:"timestamp"`
	LastUpdated string         `json:"last_updated"`
	Version     int64          `json:"version"`
	Statements  []vexStatement `json:"statements"`
}

type vexStatement struct {
	Vulnerability            vexVulnerability `json:"vulnerability"`
	Timestamp                string           `json:"timestamp"`
	LastUpdated              string           `json:"last_updated"`
	ActionStatementTimestamp string           `json:"action_statement_timestamp"`
	Version                  *int64           `json:"version"`
	Products                 []vexProduct     `json:"products"`
	Status                   string           `json:"status"`
	Justification            string           `json:"justification"`
	StatusNotes              string           `json:"status_notes"`
	ActionStatement          string           `json:"action_statement"`
	ImpactStatement          string           `json:"impact_statement"`
}

type vexVulnerability struct {
	ID          string   `json:"@id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Aliases     []string `json:"aliases"`
}

type vexProduct struct {
	ID          string `json:"@id"`
	Identifiers struct {
		PURL string `json:"purl"`
	} `json:"identifiers"`
	Subcomponents []vexProduct `json:"subcomponents"`
}

type parsedPURL struct {
	PackageType string
	Namespace   string
	Name        string
	Version     string
	Qualifiers  map[string]string
	Canonical   string
}

type productInput struct {
	PURL               parsedPURL
	Release            string
	ReleaseChannel     string
	Distro             string
	Architecture       string
	SourceName         string
	SourceVersion      string
	Scope              string
	ParentDigest       []byte
	ParentProductID    string
	SourcePURLRepaired bool
	RawSourcePURL      string
}

type normalizedProduct struct {
	DTO     productDTO
	Digest  [sha256.Size]byte
	IDBytes [16]byte
}

type projectionBuilder struct {
	cve        string
	products   map[string]normalizedProduct
	sets       map[string]productSetDTO
	limits     projectionLimits
	logical    int64
	assertions int64
	repaired   int64
}

type projectionLimits struct {
	logicalProducts int64
	assertions      int64
	jsonTokens      int64
	jsonNesting     int
}

func defaultProjectionLimits() projectionLimits {
	return projectionLimits{
		logicalProducts: maxLogicalProductsPerRecord,
		assertions:      maxAssertionsPerRecord,
		jsonTokens:      maxJSONTokensPerDocument,
		jsonNesting:     maxJSONNesting,
	}
}

func newProjectionBuilder(cve string) *projectionBuilder {
	return newProjectionBuilderWithLimits(cve, defaultProjectionLimits())
}

func newProjectionBuilderWithLimits(cve string, limits projectionLimits) *projectionBuilder {
	return &projectionBuilder{
		cve:      cve,
		products: make(map[string]normalizedProduct),
		sets:     make(map[string]productSetDTO),
		limits:   limits,
	}
}

//nolint:err113 // Product-cap validation is an internal projection invariant and is not matched.
func (builder *projectionBuilder) ensureLogicalProductCapacity(count int64) error {
	if count < 0 || builder.limits.logicalProducts <= 0 || builder.logical > builder.limits.logicalProducts || count > builder.limits.logicalProducts-builder.logical {
		return errors.New("logical product cap exceeded")
	}
	return nil
}

//nolint:err113 // Product-cap validation is an internal projection invariant and is not matched.
func (builder *projectionBuilder) accumulateLogicalProductCount(total *int64, count int) error {
	if total == nil || count < 0 || builder.limits.logicalProducts <= 0 || builder.logical > builder.limits.logicalProducts {
		return errors.New("logical product cap exceeded")
	}
	remaining := builder.limits.logicalProducts - builder.logical
	if *total < 0 || *total > remaining || int64(count) > remaining-*total {
		return errors.New("logical product cap exceeded")
	}
	*total += int64(count)
	return nil
}

func (builder *projectionBuilder) reservePreflightedLogicalProducts(count int64) error {
	if err := builder.ensureLogicalProductCapacity(count); err != nil {
		return err
	}
	builder.logical += count
	return nil
}

//nolint:err113 // Assertion-cap validation is an internal projection invariant and is not matched.
func (builder *projectionBuilder) ensureAssertionCapacity(count int) error {
	if count < 0 || builder.limits.assertions <= 0 || builder.assertions > builder.limits.assertions || int64(count) > builder.limits.assertions-builder.assertions {
		return errors.New("assertion cap exceeded")
	}
	return nil
}

func (builder *projectionBuilder) addAssertion(record *projectedRecord, assertion assertionDTO) error {
	if err := builder.ensureAssertionCapacity(1); err != nil {
		return err
	}
	record.Assertions = append(record.Assertions, assertion)
	builder.assertions++
	return nil
}

//nolint:err113 // Collection overflow is an internal projection invariant and is not matched.
func checkedCollectionSize(left, right int) (int, error) {
	if left < 0 || right < 0 || left > int(^uint(0)>>1)-right {
		return 0, errors.New("collection size overflow")
	}
	return left + right, nil
}

func projectRecord(cve string, osvRaw, vexRaw []byte, osvArchiveDigest, vexArchiveDigest string, state *projectionState) (projectedRecord, error) {
	return projectRecordWithLimits(cve, osvRaw, vexRaw, osvArchiveDigest, vexArchiveDigest, state, defaultProjectionLimits())
}

func parseProjectionDocuments(cve string, osvRaw, vexRaw []byte, osvArchiveDigest, vexArchiveDigest string, limits projectionLimits) (*rawOSV, *rawVEX, advisoryProvenance, error) {
	provenance := advisoryProvenance{NormalizationVersion: projectionVersion}
	var osv *rawOSV
	var vex *rawVEX
	var err error
	if len(osvRaw) > 0 {
		osv, err = parseOSVWithLimits(cve, osvRaw, limits)
		if err != nil {
			return nil, nil, advisoryProvenance{}, fmt.Errorf("parse OSV %s: %w", cve, err)
		}
		provenance.OSVPresent = true
		provenance.OSVArchiveSHA256 = osvArchiveDigest
		provenance.OSVDocumentSHA256 = digestHex(osvRaw)
		provenance.OSVWithdrawn = osv.Withdrawn != ""
		provenance.OSVAffectedCount = len(osv.Affected)
	}
	if len(vexRaw) > 0 {
		vex, err = parseVEXWithLimits(cve, vexRaw, limits)
		if err != nil {
			return nil, nil, advisoryProvenance{}, fmt.Errorf("parse VEX %s: %w", cve, err)
		}
		provenance.VEXPresent = true
		provenance.VEXArchiveSHA256 = vexArchiveDigest
		provenance.VEXDocumentSHA256 = digestHex(vexRaw)
		provenance.VEXEmptyStatementsTombstone = len(vex.Statements) == 0
		provenance.VEXStatementCount = len(vex.Statements)
	}
	return osv, vex, provenance, nil
}

func projectionDefinitions(builder *projectionBuilder) ([]productDTO, []productSetDTO) {
	products := make([]productDTO, 0, len(builder.products))
	for _, product := range builder.products {
		products = append(products, product.DTO)
	}
	sort.Slice(products, func(i, j int) bool { return products[i].ID < products[j].ID })
	sets := make([]productSetDTO, 0, len(builder.sets))
	for _, set := range builder.sets {
		sets = append(sets, set)
	}
	sort.Slice(sets, func(i, j int) bool { return sets[i].ID < sets[j].ID })
	return products, sets
}

//nolint:err113 // UUID collision and cap diagnostics are local projection invariants.
func unseenProjectionProducts(state *projectionState, products []productDTO) ([]productDTO, error) {
	unseen := make([]productDTO, 0, len(products))
	for _, product := range products {
		prior, exists := state.seenProducts[product.ID]
		if exists {
			if prior != product.Digest {
				return nil, errors.New("product UUID collision")
			}
			continue
		}
		if len(state.seenProducts) >= maxSeenProducts {
			return nil, errors.New("unique product cap exceeded")
		}
		state.seenProducts[product.ID] = product.Digest
		if product.Metadata.MissingRelease {
			state.counters.UnscopedProducts++
		}
		unseen = append(unseen, product)
	}
	return unseen, nil
}

//nolint:err113 // UUID collision and cap diagnostics are local projection invariants.
func unseenProjectionSets(state *projectionState, sets []productSetDTO) ([]productSetDTO, error) {
	unseen := make([]productSetDTO, 0, len(sets))
	for _, set := range sets {
		prior, exists := state.seenSets[set.ID]
		if exists {
			if prior != set.Digest {
				return nil, errors.New("product-set UUID collision")
			}
			continue
		}
		if len(state.seenSets) >= maxSeenProductSets {
			return nil, errors.New("unique product-set cap exceeded")
		}
		state.seenSets[set.ID] = set.Digest
		unseen = append(unseen, set)
	}
	return unseen, nil
}

func updateProjectionCounters(state *projectionState, builder *projectionBuilder, record *projectedRecord, osv *rawOSV, vex *rawVEX) {
	state.counters.LogicalProductOccurrences += builder.logical
	state.counters.RepairedSourcePURLs += builder.repaired
	state.counters.Assertions += int64(len(record.Assertions))
	if osv != nil {
		state.counters.OSVDocuments++
		state.counters.OSVAffectedEntries += int64(len(osv.Affected))
		if osv.Withdrawn != "" {
			state.counters.WithdrawnDocuments++
		}
	}
	if vex != nil {
		state.counters.VEXDocuments++
		state.counters.VEXStatements += int64(len(vex.Statements))
		if len(vex.Statements) == 0 {
			state.counters.VEXTombstones++
		}
	}
}

//nolint:err113 // Projection invariant diagnostics are consumed as text by this internal pipeline.
func projectRecordWithLimits(cve string, osvRaw, vexRaw []byte, osvArchiveDigest, vexArchiveDigest string, state *projectionState, limits projectionLimits) (projectedRecord, error) {
	if state == nil {
		return projectedRecord{}, errors.New("nil projection state")
	}
	builder := newProjectionBuilderWithLimits(cve, limits)
	record := projectedRecord{
		ProtocolVersion: projectionVersion,
		CVEID:           cve,
		Coordinates:     []coordinateDTO{},
		Products:        []productDTO{},
		ProductSets:     []productSetDTO{},
		Assertions:      []assertionDTO{},
	}
	osv, vex, provenance, err := parseProjectionDocuments(cve, osvRaw, vexRaw, osvArchiveDigest, vexArchiveDigest, limits)
	if err != nil {
		return projectedRecord{}, err
	}
	if osv == nil && vex == nil {
		return projectedRecord{}, errors.New("empty projection record")
	}
	if err := preflightAssertionCount(builder, osv, vex); err != nil {
		return projectedRecord{}, err
	}

	record.Advisory = buildAdvisory(cve, osv, vex, provenance)
	if osv != nil {
		if err := projectOSV(builder, &record, osv, provenance); err != nil {
			return projectedRecord{}, fmt.Errorf("project OSV %s: %w", cve, err)
		}
	}
	if vex != nil {
		if err := projectVEX(builder, &record, vex, provenance); err != nil {
			return projectedRecord{}, fmt.Errorf("project VEX %s: %w", cve, err)
		}
	}
	record.Advisory.Provenance.RepairedSourcePURLCount = int(builder.repaired)

	sort.Slice(record.Coordinates, func(i, j int) bool { return record.Coordinates[i].Value < record.Coordinates[j].Value })
	record.Coordinates = dedupeCoordinates(record.Coordinates)
	sort.Slice(record.Assertions, func(i, j int) bool { return record.Assertions[i].AssertionKey < record.Assertions[j].AssertionKey })
	for i := 1; i < len(record.Assertions); i++ {
		if record.Assertions[i-1].AssertionKey == record.Assertions[i].AssertionKey {
			return projectedRecord{}, errors.New("duplicate semantic assertion")
		}
	}

	allProducts, allSets := projectionDefinitions(builder)
	record.Products = allProducts
	record.ProductSets = allSets
	digest, err := projectionDigest(record)
	if err != nil {
		return projectedRecord{}, err
	}
	record.ProjectionDigest = digest

	newProducts, err := unseenProjectionProducts(state, allProducts)
	if err != nil {
		return projectedRecord{}, err
	}
	newSets, err := unseenProjectionSets(state, allSets)
	if err != nil {
		return projectedRecord{}, err
	}
	record.Products = newProducts
	record.ProductSets = newSets

	updateProjectionCounters(state, builder, &record, osv, vex)
	return record, nil
}

//nolint:err113 // Assertion-cap validation is an internal projection invariant and is not matched.
func preflightAssertionCount(builder *projectionBuilder, osv *rawOSV, vex *rawVEX) error {
	count := 0
	var err error
	if osv != nil && osv.Withdrawn == "" {
		count = len(osv.Affected)
	}
	if vex != nil {
		count, err = checkedCollectionSize(count, len(vex.Statements))
		if err != nil {
			return errors.New("assertion cap exceeded")
		}
	}
	return builder.ensureAssertionCapacity(count)
}

func parseOSV(cve string, raw []byte) (*rawOSV, error) {
	return parseOSVWithLimits(cve, raw, defaultProjectionLimits())
}

//nolint:err113 // OSV validation diagnostics are consumed as text by this internal parser.
func parseOSVWithLimits(cve string, raw []byte, limits projectionLimits) (*rawOSV, error) {
	if _, err := preflightDocumentStructure("osv", cve, raw, limits); err != nil {
		return nil, err
	}
	var doc rawOSV
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, errors.New("invalid OSV object")
	}
	if doc.ID != "UBUNTU-"+cve {
		return nil, errors.New("OSV identity mismatch")
	}
	if err := corroborateCVE(cve, append(append([]string{}, doc.Aliases...), doc.Upstream...)); err != nil {
		return nil, fmt.Errorf("OSV identity corroboration: %w", err)
	}
	if _, err := canonicalTimestamp(doc.Modified, false); err != nil {
		return nil, errors.New("invalid OSV modified timestamp")
	}
	if _, err := canonicalTimestamp(doc.Published, true); err != nil {
		return nil, errors.New("invalid OSV published timestamp")
	}
	if _, err := canonicalTimestamp(doc.Withdrawn, true); err != nil {
		return nil, errors.New("invalid OSV withdrawn timestamp")
	}
	if len(doc.Details) > maxDescriptionBytes {
		return nil, errors.New("OSV description cap exceeded")
	}
	if doc.Withdrawn == "" && len(doc.Affected) == 0 {
		return nil, errors.New("live OSV document has no affected entries")
	}
	for i := range doc.Affected {
		if _, err := validateOSVAffected(&doc.Affected[i]); err != nil {
			return nil, fmt.Errorf("invalid OSV affected entry %d: %w", i, err)
		}
	}
	for _, reference := range doc.References {
		if reference.URL == "" || len(reference.URL) > maxEvidenceBytes {
			return nil, errors.New("invalid OSV reference")
		}
	}
	if len(doc.References) > maxReferences {
		return nil, errors.New("OSV reference cap exceeded")
	}
	doc.Modified, _ = canonicalTimestamp(doc.Modified, false)
	doc.Published, _ = canonicalTimestamp(doc.Published, true)
	doc.Withdrawn, _ = canonicalTimestamp(doc.Withdrawn, true)
	return &doc, nil
}

type validatedOSVAffected struct {
	Source         parsedPURL
	ReleaseChannel string
	Introduced     string
	Fixed          string
	Repaired       bool
}

//nolint:err113 // OSV affected-entry diagnostics are consumed as text by this internal parser.
func validateOSVAffected(affected *osvAffected) (validatedOSVAffected, error) {
	var out validatedOSVAffected
	if affected.Package.Name == "" || !strings.HasPrefix(affected.Package.Ecosystem, "Ubuntu:") {
		return out, errors.New("invalid Ubuntu source package")
	}
	if err := validateOSVProductComponent(affected.Package.Name); err != nil {
		return out, err
	}
	out.ReleaseChannel = strings.TrimPrefix(affected.Package.Ecosystem, "Ubuntu:")
	if out.ReleaseChannel == "" {
		return out, errors.New("empty Ubuntu release channel")
	}
	if err := validateOSVProductComponent(out.ReleaseChannel); err != nil {
		return out, err
	}
	var parsed parsedPURL
	var repaired bool
	if affected.Package.PURL == "" {
		if !validPURLComponent(affected.Package.Name) || strings.Contains(affected.Package.Name, "/") {
			return out, errors.New("invalid Ubuntu source package name")
		}
		parsed = parsedPURL{
			PackageType: "deb",
			Namespace:   "ubuntu",
			Name:        affected.Package.Name,
			Qualifiers:  map[string]string{"arch": sourceArchitecture},
		}
	} else {
		var err error
		parsed, repaired, err = parseUbuntuPURL(affected.Package.PURL, true)
		if err != nil || parsed.Name != affected.Package.Name || (parsed.Qualifiers["arch"] != sourceArchitecture && parsed.Qualifiers["arch"] != "src") || parsed.Qualifiers["distro"] == "" {
			return out, errors.New("invalid Ubuntu source PURL")
		}
	}
	out.Source, out.Repaired = parsed, repaired
	if len(affected.Ranges) != 1 || affected.Ranges[0].Type != "ECOSYSTEM" {
		return out, errors.New("exactly one ECOSYSTEM range is required")
	}
	events := affected.Ranges[0].Events
	if len(events) < 1 || len(events) > 2 {
		return out, errors.New("exactly one introduced/fixed cycle is required")
	}
	introduced, err := singleEventValue(events[0], "introduced")
	if err != nil {
		return out, err
	}
	out.Introduced = introduced
	if len(events) == 2 {
		fixed, err := singleEventValue(events[1], "fixed")
		if err != nil {
			return out, err
		}
		out.Fixed = fixed
	}
	for _, version := range affected.Versions {
		if version == "" {
			return out, errors.New("empty affected version")
		}
		if err := validateOSVProductComponent(version); err != nil {
			return out, err
		}
	}
	for _, binaryPackage := range affected.EcosystemSpecific.Binaries {
		if binaryPackage.Name == "" || binaryPackage.Version == "" {
			return out, errors.New("invalid binary package correlation")
		}
		if err := validateOSVProductComponent(binaryPackage.Name); err != nil {
			return out, err
		}
		if err := validateOSVProductComponent(binaryPackage.Version); err != nil {
			return out, err
		}
	}
	return out, nil
}

//nolint:err113 // OSV component diagnostics are consumed as text by this internal parser.
func validateOSVProductComponent(value string) error {
	if len(value) > maxPURLBytes {
		return errors.New("OSV product component cap exceeded")
	}
	if !validPURLComponent(value) {
		return errors.New("invalid OSV product component")
	}
	return nil
}

//nolint:err113 // OSV range diagnostics are consumed as text by this internal parser.
func singleEventValue(event map[string]json.RawMessage, name string) (string, error) {
	if len(event) != 1 {
		return "", errors.New("range event must contain one field")
	}
	raw, ok := event[name]
	if !ok {
		return "", fmt.Errorf("expected %s range event", name)
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil || value == "" {
		return "", fmt.Errorf("invalid %s range event", name)
	}
	if err := validateOSVProductComponent(value); err != nil {
		return "", err
	}
	return value, nil
}

func parseVEX(cve string, raw []byte) (*rawVEX, error) {
	return parseVEXWithLimits(cve, raw, defaultProjectionLimits())
}

//nolint:err113 // VEX validation diagnostics are consumed as text by this internal parser.
func parseVEXWithLimits(cve string, raw []byte, limits projectionLimits) (*rawVEX, error) {
	structure, err := preflightDocumentStructure("vex", cve, raw, limits)
	if err != nil {
		return nil, err
	}
	var doc rawVEX
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, errors.New("invalid VEX object")
	}
	if err := applyVEXDocumentMetadata(structure.vex, &doc); err != nil {
		return nil, err
	}
	if doc.Context != canonicalTombstoneContext || doc.ID == "" || doc.Author != canonicalAuthor || doc.Version <= 0 {
		return nil, errors.New("invalid VEX document metadata")
	}
	if err := corroborateCVE(cve, []string{doc.ID}); err != nil {
		return nil, fmt.Errorf("VEX document identity: %w", err)
	}
	doc.Timestamp, err = canonicalTimestamp(doc.Timestamp, false)
	if err != nil {
		return nil, errors.New("invalid VEX document timestamp")
	}
	doc.LastUpdated, err = canonicalTimestamp(doc.LastUpdated, true)
	if err != nil {
		return nil, errors.New("invalid VEX document last_updated")
	}
	for i := range doc.Statements {
		if err := validateVEXStatement(cve, &doc.Statements[i]); err != nil {
			return nil, fmt.Errorf("invalid VEX statement %d: %w", i, err)
		}
	}
	return &doc, nil
}

func applyVEXDocumentMetadata(structure vexStructure, doc *rawVEX) error {
	metadata, err := mergedVEXMetadata(structure)
	if err != nil {
		return err
	}
	doc.Context = metadata.context
	doc.ID = metadata.id
	doc.Author = metadata.author
	doc.Timestamp = metadata.timestamp
	doc.LastUpdated = metadata.lastUpdated
	doc.Version = metadata.version
	return nil
}

//nolint:err113 // Statement validation diagnostics are consumed as text by the internal parser.
func validateVEXStatement(cve string, statement *vexStatement) error {
	if statement.Vulnerability.Name != cve {
		return errors.New("vulnerability identity mismatch")
	}
	// Alias URLs are references, not identity assertions; a publisher may link
	// a closely related vulnerability from this list. The archive path,
	// vulnerability name, and vulnerability @id establish identity, while
	// related aliases remain evidence.
	if err := corroborateCVE(cve, []string{statement.Vulnerability.ID}); err != nil {
		return err
	}
	if len(statement.Vulnerability.Description) > maxDescriptionBytes {
		return errors.New("vulnerability description cap exceeded")
	}
	var err error
	statement.Timestamp, err = canonicalTimestamp(statement.Timestamp, true)
	if err != nil {
		return errors.New("invalid statement timestamp")
	}
	statement.LastUpdated, err = canonicalTimestamp(statement.LastUpdated, true)
	if err != nil {
		return errors.New("invalid statement last_updated")
	}
	statement.ActionStatementTimestamp, err = canonicalTimestamp(statement.ActionStatementTimestamp, true)
	if err != nil {
		return errors.New("invalid action_statement_timestamp")
	}
	if statement.Version != nil && *statement.Version <= 0 {
		return errors.New("statement version must be positive")
	}
	for _, text := range []string{statement.Vulnerability.ID, statement.StatusNotes, statement.ActionStatement, statement.ImpactStatement, statement.Justification} {
		if len(text) > maxEvidenceBytes {
			return errors.New("statement evidence cap exceeded")
		}
	}
	if len(statement.Vulnerability.Aliases) > maxReferences {
		return errors.New("too many vulnerability aliases")
	}
	for _, alias := range statement.Vulnerability.Aliases {
		if alias == "" || len(alias) > maxEvidenceBytes {
			return errors.New("invalid vulnerability alias")
		}
	}
	switch statement.Status {
	case "affected":
		if statement.ActionStatement == "" {
			return errors.New("affected statement requires action_statement")
		}
	case "not_affected":
		if !validNotAffectedEvidence(statement) {
			return errors.New("not_affected statement lacks trusted evidence")
		}
	case "fixed", "under_investigation":
	default:
		return errors.New("invalid VEX status")
	}
	if len(statement.Products) == 0 {
		return errors.New("VEX statement has no products")
	}
	return nil
}

func validNotAffectedEvidence(statement *vexStatement) bool {
	switch statement.Justification {
	case "component_not_present", "vulnerable_code_not_present", "vulnerable_code_not_in_execute_path", "vulnerable_code_cannot_be_controlled_by_adversary", "inline_mitigations_already_exist":
		return true
	case "":
		return statement.ImpactStatement != ""
	default:
		return false
	}
}

//nolint:err113 // Identity conflicts are exact internal validation diagnostics and are not matched.
func corroborateCVE(expected string, values []string) error {
	for _, value := range values {
		for _, found := range cveInID.FindAllString(value, -1) {
			if found != expected {
				return fmt.Errorf("found conflicting %s", found)
			}
		}
	}
	return nil
}

//nolint:err113 // Timestamp validation diagnostics are consumed as text by this internal parser.
func canonicalTimestamp(value string, optional bool) (string, error) {
	if value == "" {
		if optional {
			return "", nil
		}
		return "", errors.New("timestamp missing")
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		switch {
		case strings.HasSuffix(value, " UTC"):
			parsed, err = time.ParseInLocation("2006-01-02 15:04:05.999999999", strings.TrimSuffix(value, " UTC"), time.UTC)
		case !strings.ContainsAny(value, "Zz+") && len(value) >= len("2006-01-02T15:04:05") && value[10] == 'T':
			parsed, err = time.ParseInLocation("2006-01-02T15:04:05.999999999", value, time.UTC)
		}
		if err != nil {
			return "", err
		}
	}
	return parsed.UTC().Format(time.RFC3339Nano), nil
}

func buildAdvisory(cve string, osv *rawOSV, vex *rawVEX, provenance advisoryProvenance) advisorySummary {
	advisory := advisorySummary{
		SourceObjectID: "UBUNTU-" + cve,
		AdvisoryID:     "UBUNTU-" + cve,
		CVEID:          cve,
		Title:          cve,
		References:     []string{},
		Provenance:     provenance,
	}
	var timestamps []string
	if osv != nil {
		advisory.Description = osv.Details
		advisory.PublishedAt = osv.Published
		advisory.WithdrawnAt = osv.Withdrawn
		timestamps = append(timestamps, osv.Modified, osv.Withdrawn)
		for _, severity := range osv.Severity {
			switch severity.Type {
			case "Ubuntu":
				advisory.Severity = strings.ToLower(severity.Score)
			case "CVSS_V3":
				advisory.CVSSVector = severity.Score
			}
		}
		for _, reference := range osv.References {
			advisory.References = append(advisory.References, reference.URL)
		}
	}
	if vex != nil {
		timestamps = append(timestamps, vex.Timestamp, vex.LastUpdated)
		for _, statement := range vex.Statements {
			if advisory.Description == "" && statement.Vulnerability.Description != "" {
				advisory.Description = statement.Vulnerability.Description
			}
			if advisory.PublishedAt == "" && statement.Timestamp != "" {
				advisory.PublishedAt = statement.Timestamp
			}
			timestamps = append(timestamps, statement.Timestamp, statement.LastUpdated, statement.ActionStatementTimestamp)
			advisory.References = append(advisory.References, statement.Vulnerability.Aliases...)
		}
	}
	advisory.ModifiedAt = latestTimestamp(timestamps)
	advisory.References = sortedUniqueStrings(advisory.References)
	return advisory
}

func projectOSV(builder *projectionBuilder, record *projectedRecord, doc *rawOSV, provenance advisoryProvenance) error {
	if doc.Withdrawn != "" {
		return nil
	}
	if err := builder.ensureAssertionCapacity(len(doc.Affected)); err != nil {
		return err
	}
	if err := preflightOSVProducts(builder, doc); err != nil {
		return err
	}
	for _, affected := range doc.Affected {
		validated, err := validateOSVAffected(&affected)
		if err != nil {
			return err
		}
		if validated.Repaired {
			builder.repaired++
		}
		if validated.Source.Canonical != "" {
			record.Coordinates = append(record.Coordinates, coordinateDTO{
				CoordinateType: "purl",
				Value:          validated.Source.Canonical,
				Metadata:       map[string]string{"namespace": "ubuntu"},
			})
		}
		memberCount, err := checkedCollectionSize(len(affected.Versions), len(affected.EcosystemSpecific.Binaries))
		if err != nil {
			return err
		}
		members := make([]normalizedProduct, 0, memberCount)
		for _, version := range affected.Versions {
			productPURL := validated.Source
			productPURL.Version = version
			if err := canonicalizePURL(&productPURL); err != nil {
				return err
			}
			product, err := builder.addProduct(productInput{
				PURL:               productPURL,
				Release:            productPURL.Qualifiers["distro"],
				ReleaseChannel:     validated.ReleaseChannel,
				Distro:             productPURL.Qualifiers["distro"],
				Architecture:       productPURL.Qualifiers["arch"],
				SourceName:         productPURL.Name,
				SourceVersion:      productPURL.Version,
				Scope:              sourceArchitecture,
				SourcePURLRepaired: validated.Repaired,
				RawSourcePURL:      firstIf(validated.Repaired, affected.Package.PURL),
			})
			if err != nil {
				return err
			}
			members = append(members, product)
		}
		for _, binaryPackage := range affected.EcosystemSpecific.Binaries {
			qualifiers := cloneQualifiers(validated.Source.Qualifiers)
			delete(qualifiers, "arch")
			binaryPURL := parsedPURL{
				PackageType: "deb",
				Namespace:   "ubuntu",
				Name:        binaryPackage.Name,
				Version:     binaryPackage.Version,
				Qualifiers:  qualifiers,
			}
			if err := canonicalizePURL(&binaryPURL); err != nil {
				return err
			}
			product, err := builder.addProduct(productInput{
				PURL:           binaryPURL,
				Release:        qualifiers["distro"],
				ReleaseChannel: validated.ReleaseChannel,
				Distro:         qualifiers["distro"],
				SourceName:     validated.Source.Name,
				SourceVersion:  validated.Source.Version,
				Scope:          "binary",
			})
			if err != nil {
				return err
			}
			members = append(members, product)
		}
		set, err := builder.addSet(members)
		if err != nil {
			return err
		}
		setDigest := []byte(nil)
		setRef := ""
		if set != nil {
			decoded, _ := hex.DecodeString(set.Digest)
			setDigest = decoded
			setRef = set.ID
		}
		assertionProvenance := map[string]any{
			"archive_sha256":           provenance.OSVArchiveSHA256,
			"source_document_sha256":   provenance.OSVDocumentSHA256,
			"explicit_source_versions": len(affected.Versions),
			"binary_correlations":      len(affected.EcosystemSpecific.Binaries),
			"source_purl_repaired":     validated.Repaired,
		}
		if validated.Repaired {
			assertionProvenance["raw_source_purl"] = affected.Package.PURL
		}
		assertion := assertionDTO{
			CVEID:             record.CVEID,
			SourceKind:        "ubuntu_osv",
			Authority:         canonicalAuthor,
			SourceTimestamp:   doc.Modified,
			Disposition:       "affected",
			ProductSetRef:     setRef,
			ProductSetDigest:  hex.EncodeToString(setDigest),
			PackageType:       "deb",
			Namespace:         "ubuntu",
			Release:           validated.Source.Qualifiers["distro"],
			ReleaseChannel:    validated.ReleaseChannel,
			VersionScheme:     "deb",
			ProductScope:      "source_to_binary",
			SourcePackage:     validated.Source.Name,
			PackagePURL:       validated.Source.Canonical,
			IntroducedVersion: validated.Introduced,
			FixedVersion:      validated.Fixed,
			Validation: map[string]any{
				"ecosystem":         affected.Package.Ecosystem,
				"range_type":        "ECOSYSTEM",
				"event_cycle_count": 1,
			},
			Provenance: assertionProvenance,
			Metadata:   map[string]any{},
		}
		assertion.AssertionKey = digestTupleHex(osvAssertionDomain,
			u32Field(projectionVersion), []byte(assertion.SourceKind), []byte(record.CVEID), []byte(assertion.ProductScope),
			[]byte(assertion.Authority), []byte(assertion.SourceTimestamp), []byte(assertion.Disposition), []byte(assertion.PackageType),
			[]byte(assertion.Namespace), optionalField(assertion.Release), optionalField(assertion.ReleaseChannel), []byte(assertion.VersionScheme),
			[]byte(assertion.SourcePackage), optionalField(assertion.PackagePURL), []byte(assertion.IntroducedVersion), optionalField(assertion.FixedVersion), setDigest,
		)
		if err := validateAssertionObjects(assertion); err != nil {
			return err
		}
		if err := builder.addAssertion(record, assertion); err != nil {
			return err
		}
	}
	return nil
}

func preflightOSVProducts(builder *projectionBuilder, doc *rawOSV) error {
	var total int64
	for i := range doc.Affected {
		if err := builder.accumulateLogicalProductCount(&total, len(doc.Affected[i].Versions)); err != nil {
			return err
		}
		if err := builder.accumulateLogicalProductCount(&total, len(doc.Affected[i].EcosystemSpecific.Binaries)); err != nil {
			return err
		}
	}
	return builder.reservePreflightedLogicalProducts(total)
}

//nolint:err113 // Empty-set validation is an internal projection invariant and is not matched.
func projectVEX(builder *projectionBuilder, record *projectedRecord, doc *rawVEX, provenance advisoryProvenance) error {
	if err := builder.ensureAssertionCapacity(len(doc.Statements)); err != nil {
		return err
	}
	if err := preflightVEXProducts(builder, doc); err != nil {
		return err
	}
	for _, statement := range doc.Statements {
		members := make([]normalizedProduct, 0, len(statement.Products))
		for _, product := range statement.Products {
			if err := projectVEXProduct(builder, product, 0, nil, &members); err != nil {
				return err
			}
		}
		set, err := builder.addSet(members)
		if err != nil {
			return err
		}
		if set == nil {
			return errors.New("VEX statement has an empty product set")
		}
		fingerprint := vexStatementFingerprint(doc, &statement)
		setDigest, _ := hex.DecodeString(set.Digest)
		fingerprintBytes, _ := hex.DecodeString(fingerprint)
		effectiveTimestamp := statement.Timestamp
		if effectiveTimestamp == "" {
			effectiveTimestamp = doc.Timestamp
		}
		fingerprintBasis := map[string]any{
			"normalization_version":      projectionVersion,
			"document_context":           doc.Context,
			"document_id":                doc.ID,
			"document_author":            doc.Author,
			"document_version":           doc.Version,
			"document_timestamp":         doc.Timestamp,
			"document_last_updated":      nilIfEmpty(doc.LastUpdated),
			"vulnerability_name":         statement.Vulnerability.Name,
			"vulnerability_id":           nilIfEmpty(statement.Vulnerability.ID),
			"vulnerability_description":  nilIfEmpty(statement.Vulnerability.Description),
			"statement_version":          optionalInt64(statement.Version),
			"statement_timestamp":        nilIfEmpty(statement.Timestamp),
			"statement_last_updated":     nilIfEmpty(statement.LastUpdated),
			"action_statement_timestamp": nilIfEmpty(statement.ActionStatementTimestamp),
			"effective_timestamp":        effectiveTimestamp,
			"status":                     statement.Status,
			"justification":              nilIfEmpty(statement.Justification),
			"status_notes":               nilIfEmpty(statement.StatusNotes),
			"action_statement":           nilIfEmpty(statement.ActionStatement),
			"impact_statement":           nilIfEmpty(statement.ImpactStatement),
		}
		validation := map[string]any{"fingerprint_basis": fingerprintBasis}
		assertion := assertionDTO{
			StatementFingerprint: fingerprint,
			FingerprintAliases:   sortedUniqueStrings(statement.Vulnerability.Aliases),
			CVEID:                record.CVEID,
			SourceKind:           "ubuntu_openvex",
			Authority:            doc.Author,
			SourceTimestamp:      effectiveTimestamp,
			Disposition:          statement.Status,
			ProductSetRef:        set.ID,
			ProductSetDigest:     set.Digest,
			PackageType:          "deb",
			Namespace:            "ubuntu",
			VersionScheme:        "deb",
			ProductScope:         "exact_product_set",
			Justification:        statement.Justification,
			StatusText:           statement.StatusNotes,
			ActionText:           firstNonempty(statement.ActionStatement, statement.ImpactStatement),
			Validation:           validation,
			Provenance: map[string]any{
				"archive_sha256":         provenance.VEXArchiveSHA256,
				"source_document_sha256": provenance.VEXDocumentSHA256,
				"logical_product_count":  len(members),
				"unique_product_count":   set.Count,
			},
			Metadata: map[string]any{},
		}
		assertion.AssertionKey = digestTupleHex(vexAssertionDomain,
			u32Field(projectionVersion), []byte(assertion.SourceKind), []byte(record.CVEID), []byte(assertion.ProductScope), fingerprintBytes, setDigest,
		)
		if err := validateAssertionObjects(assertion); err != nil {
			return err
		}
		if err := builder.addAssertion(record, assertion); err != nil {
			return err
		}
	}
	return nil
}

func preflightVEXProducts(builder *projectionBuilder, doc *rawVEX) error {
	var total int64
	for i := range doc.Statements {
		if err := preflightVEXProductSlice(builder, doc.Statements[i].Products, 0, &total); err != nil {
			return err
		}
	}
	if err := builder.reservePreflightedLogicalProducts(total); err != nil {
		return fmt.Errorf("VEX %w", err)
	}
	return nil
}

//nolint:err113 // Product-depth validation is an internal projection invariant and is not matched.
func preflightVEXProductSlice(builder *projectionBuilder, products []vexProduct, depth int, total *int64) error {
	for i := range products {
		if depth > maxProductDepth {
			return errors.New("VEX product nesting cap exceeded")
		}
		if err := builder.accumulateLogicalProductCount(total, 1); err != nil {
			return fmt.Errorf("VEX %w", err)
		}
		if err := preflightVEXProductSlice(builder, products[i].Subcomponents, depth+1, total); err != nil {
			return err
		}
	}
	return nil
}

//nolint:err113 // Product validation diagnostics are consumed as text by this internal projector.
func projectVEXProduct(builder *projectionBuilder, raw vexProduct, depth int, parent *normalizedProduct, members *[]normalizedProduct) error {
	if depth > maxProductDepth {
		return errors.New("VEX product nesting cap exceeded")
	}
	parsed, err := selectVEXProductPURL(raw)
	if err != nil {
		return err
	}
	architecture := parsed.Qualifiers["arch"]
	if architecture == "" {
		return errors.New("VEX product lacks architecture")
	}
	release := parsed.Qualifiers["distro"]
	scope := "exact_product"
	var parentDigest []byte
	var parentID string
	if parent != nil {
		scope = "subcomponent"
		parentDigest = parent.Digest[:]
		parentID = parent.DTO.ID
	}
	sourceName, sourceVersion := "", ""
	if architecture == sourceArchitecture || architecture == "src" {
		sourceName, sourceVersion = parsed.Name, parsed.Version
	}
	product, err := builder.addProduct(productInput{
		PURL:            parsed,
		Release:         release,
		Distro:          release,
		Architecture:    architecture,
		SourceName:      sourceName,
		SourceVersion:   sourceVersion,
		Scope:           scope,
		ParentDigest:    parentDigest,
		ParentProductID: parentID,
	})
	if err != nil {
		return err
	}
	*members = append(*members, product)
	for _, child := range raw.Subcomponents {
		parentCopy := product
		if err := projectVEXProduct(builder, child, depth+1, &parentCopy, members); err != nil {
			return err
		}
	}
	return nil
}

//nolint:err113 // Product PURL conflicts are exact internal validation diagnostics and are not matched.
func selectVEXProductPURL(product vexProduct) (parsedPURL, error) {
	identified := product.Identifiers.PURL
	direct := product.ID
	selected := identified
	if selected == "" {
		selected = direct
	}
	if selected == "" || !strings.HasPrefix(selected, "pkg:") {
		return parsedPURL{}, errors.New("VEX product lacks a PURL")
	}
	parsed, _, err := parseUbuntuPURL(selected, false)
	if err != nil {
		return parsedPURL{}, err
	}
	if identified != "" && strings.HasPrefix(direct, "pkg:") {
		directParsed, _, err := parseUbuntuPURL(direct, false)
		if err != nil || directParsed.Canonical != parsed.Canonical {
			return parsedPURL{}, errors.New("conflicting VEX product PURLs")
		}
	}
	return parsed, nil
}

//nolint:err113 // Product collision and version diagnostics are internal projection invariants.
func (builder *projectionBuilder) addProduct(input productInput) (normalizedProduct, error) {
	if input.PURL.Version == "" {
		return normalizedProduct{}, errors.New("normalized product requires exact version")
	}
	qualifierBlob, err := encodeStringMap(input.PURL.Qualifiers)
	if err != nil {
		return normalizedProduct{}, err
	}
	fields := [][]byte{
		u32Field(projectionVersion),
		[]byte(input.PURL.PackageType),
		[]byte(input.PURL.Namespace),
		[]byte(input.PURL.Name),
		[]byte(input.PURL.Version),
		optionalField(input.Release),
		optionalField(input.ReleaseChannel),
		optionalField(input.Distro),
		optionalField(input.Architecture),
		optionalField(input.SourceName),
		optionalField(input.SourceVersion),
		[]byte(input.Scope),
		input.ParentDigest,
		qualifierBlob,
	}
	digest, canonical := digestTuple(productDomain, fields...)
	idBytes := uuidBytes(digest)
	id := formatUUID(idBytes)
	lookupDigest, _ := digestTuple(productLookupDomain,
		[]byte(input.PURL.PackageType), []byte(input.PURL.Namespace), []byte(input.PURL.Name), []byte(input.PURL.Version),
	)
	lookupID := formatUUID(uuidBytes(lookupDigest))
	dto := productDTO{
		ID:                   id,
		Digest:               hex.EncodeToString(digest[:]),
		LookupKey:            lookupID,
		CanonicalSizeBytes:   len(canonical),
		NormalizationVersion: projectionVersion,
		PackageType:          input.PURL.PackageType,
		Namespace:            input.PURL.Namespace,
		Name:                 input.PURL.Name,
		Version:              input.PURL.Version,
		Release:              input.Release,
		ReleaseChannel:       input.ReleaseChannel,
		Distro:               input.Distro,
		Architecture:         input.Architecture,
		SourceName:           input.SourceName,
		SourceVersion:        input.SourceVersion,
		PURL:                 input.PURL.Canonical,
		Scope:                input.Scope,
		ParentProductID:      input.ParentProductID,
		Qualifiers:           cloneQualifiers(input.PURL.Qualifiers),
		Metadata: productMetadata{
			MissingRelease:     input.Release == "",
			SourcePURLRepaired: input.SourcePURLRepaired,
			RawSourcePURL:      input.RawSourcePURL,
		},
	}
	product := normalizedProduct{DTO: dto, Digest: digest, IDBytes: idBytes}
	if prior, exists := builder.products[id]; exists {
		if prior.DTO.Digest != dto.Digest {
			return normalizedProduct{}, errors.New("local product UUID collision")
		}
		return prior, nil
	}
	builder.products[id] = product
	return product, nil
}

//nolint:err113 // Product-set collision and cap diagnostics are internal projection invariants.
func (builder *projectionBuilder) addSet(products []normalizedProduct) (*productSetDTO, error) {
	if len(products) == 0 {
		return nil, nil
	}
	mapCapacity := len(products)
	if mapCapacity > maxProductSetMembers {
		mapCapacity = maxProductSetMembers
	}
	byID := make(map[string]normalizedProduct, mapCapacity)
	for _, product := range products {
		if prior, exists := byID[product.DTO.ID]; exists {
			if prior.DTO.Digest != product.DTO.Digest {
				return nil, errors.New("product UUID collision in set")
			}
			continue
		}
		if len(byID) >= maxProductSetMembers {
			return nil, errors.New("product-set member cap exceeded")
		}
		byID[product.DTO.ID] = product
	}
	unique := make([]normalizedProduct, 0, len(byID))
	for _, product := range byID {
		unique = append(unique, product)
	}
	sort.Slice(unique, func(i, j int) bool { return bytes.Compare(unique[i].IDBytes[:], unique[j].IDBytes[:]) < 0 })
	fields := make([][]byte, 0, len(unique)+2)
	fields = append(fields, u32Field(projectionVersion), u32Field(len(unique)))
	ids := make([]string, 0, len(unique))
	for _, product := range unique {
		idCopy := append([]byte(nil), product.IDBytes[:]...)
		fields = append(fields, idCopy)
		ids = append(ids, product.DTO.ID)
	}
	digest, canonical := digestTuple(productSetDomain, fields...)
	if len(canonical) > maxProductSetCanonicalSize {
		return nil, errors.New("product-set canonical size cap exceeded")
	}
	dto := productSetDTO{
		ID:                   formatUUID(uuidBytes(digest)),
		Digest:               hex.EncodeToString(digest[:]),
		ProductIDs:           ids,
		Count:                len(ids),
		CanonicalSizeBytes:   len(canonical),
		NormalizationVersion: projectionVersion,
	}
	if prior, exists := builder.sets[dto.ID]; exists {
		if prior.Digest != dto.Digest {
			return nil, errors.New("local product-set UUID collision")
		}
		return &prior, nil
	}
	builder.sets[dto.ID] = dto
	return &dto, nil
}

//nolint:err113 // Repair validation diagnostics are consumed as text by the internal parser.
func repairUbuntuPURL(raw string, allowRepair bool) (string, bool, error) {
	if raw == "" || len(raw) > maxPURLBytes {
		return "", false, errors.New("invalid PURL length")
	}
	if !strings.Contains(raw, "?arch=src?distro=") {
		return raw, false, nil
	}
	pathPart := strings.SplitN(raw, "?", 2)[0]
	if !allowRepair || strings.Contains(pathPart, "@") || strings.Count(raw, "?") != 2 || strings.Count(raw, "?arch=src?distro=") != 1 {
		return "", false, errors.New("ambiguous malformed PURL")
	}
	return strings.Replace(raw, "?arch=src?distro=", "?arch=src&distro=", 1), true, nil
}

//nolint:err113 // PURL shape diagnostics are consumed as text by the internal parser.
func splitUbuntuPURL(raw string, repaired bool) (string, string, string, error) {
	if strings.Contains(raw, "#") || !strings.HasPrefix(raw, "pkg:") {
		return "", "", "", errors.New("unsupported PURL form")
	}
	parts := strings.SplitN(strings.TrimPrefix(raw, "pkg:"), "?", 2)
	pathPart := parts[0]
	queryPart := ""
	if len(parts) == 2 {
		queryPart = parts[1]
	}
	at := strings.LastIndex(pathPart, "@")
	identity := pathPart
	rawVersion := ""
	if at >= 0 {
		if at == 0 || at == len(pathPart)-1 {
			return "", "", "", errors.New("PURL requires exact version")
		}
		identity, rawVersion = pathPart[:at], pathPart[at+1:]
	} else if !repaired {
		return "", "", "", errors.New("PURL requires exact version")
	}
	return identity, rawVersion, queryPart, nil
}

//nolint:err113 // PURL identity diagnostics are consumed as text by the internal parser.
func parseUbuntuPURLIdentity(identity, rawVersion string) (string, string, string, error) {
	segments := strings.Split(identity, "/")
	if len(segments) != 3 || segments[0] != "deb" {
		return "", "", "", errors.New("PURL is not deb/ubuntu")
	}
	namespace, err := url.PathUnescape(segments[1])
	if err != nil || namespace != "ubuntu" {
		return "", "", "", errors.New("PURL namespace is not ubuntu")
	}
	name, err := url.PathUnescape(segments[2])
	if err != nil || !validPURLComponent(name) || len(name) > maxPURLBytes || strings.Contains(name, "/") {
		return "", "", "", errors.New("invalid PURL name")
	}
	version := ""
	if rawVersion != "" {
		version, err = url.PathUnescape(rawVersion)
		if err != nil || !validPURLComponent(version) || len(version) > maxPURLBytes {
			return "", "", "", errors.New("invalid PURL version")
		}
	}
	return namespace, name, version, nil
}

//nolint:err113 // PURL qualifier diagnostics are consumed as text by the internal parser.
func parseUbuntuPURLQualifiers(queryPart string) (map[string]string, error) {
	qualifiers := make(map[string]string)
	if queryPart != "" {
		for _, pair := range strings.Split(queryPart, "&") {
			pieces := strings.SplitN(pair, "=", 2)
			if len(pieces) != 2 {
				return nil, errors.New("invalid PURL qualifier")
			}
			key, err := url.PathUnescape(pieces[0])
			if err != nil || key == "" || strings.ToLower(key) != key || !validPURLComponent(key) || len(key) > maxPURLBytes {
				return nil, errors.New("invalid PURL qualifier key")
			}
			value, err := url.PathUnescape(pieces[1])
			if err != nil || !validPURLComponent(value) || len(value) > maxPURLBytes {
				return nil, errors.New("invalid PURL qualifier value")
			}
			if _, exists := qualifiers[key]; exists {
				return nil, errors.New("duplicate PURL qualifier")
			}
			qualifiers[key] = value
		}
	}
	if len(qualifiers) > maxQualifiers {
		return nil, errors.New("PURL qualifier cap exceeded")
	}
	return qualifiers, nil
}

func parseUbuntuPURL(raw string, allowRepair bool) (parsedPURL, bool, error) {
	var out parsedPURL
	raw, repaired, err := repairUbuntuPURL(raw, allowRepair)
	if err != nil {
		return out, false, err
	}
	identity, rawVersion, queryPart, err := splitUbuntuPURL(raw, repaired)
	if err != nil {
		return out, false, err
	}
	namespace, name, version, err := parseUbuntuPURLIdentity(identity, rawVersion)
	if err != nil {
		return out, false, err
	}
	qualifiers, err := parseUbuntuPURLQualifiers(queryPart)
	if err != nil {
		return out, false, err
	}
	out = parsedPURL{
		PackageType: "deb",
		Namespace:   namespace,
		Name:        name,
		Version:     version,
		Qualifiers:  qualifiers,
	}
	if err := canonicalizePURL(&out); err != nil {
		return parsedPURL{}, false, err
	}
	return out, repaired, nil
}

//nolint:err113 // Nil PURL validation is an internal parser diagnostic and is not matched.
func canonicalizePURL(purl *parsedPURL) error {
	if purl == nil {
		return errors.New("nil PURL")
	}
	if err := ensureCanonicalPURLSize(*purl); err != nil {
		return err
	}
	purl.Canonical = canonicalPURL(*purl)
	return nil
}

//nolint:err113 // Canonical-size validation is an internal parser diagnostic and is not matched.
func ensureCanonicalPURLSize(purl parsedPURL) error {
	size := len("pkg:")
	add := func(value string, delimiterBytes int) error {
		if delimiterBytes < 0 || size > maxPURLBytes-delimiterBytes {
			return errors.New("PURL canonical size cap exceeded")
		}
		size += delimiterBytes
		for i := 0; i < len(value); i++ {
			componentBytes := 3
			c := value[i]
			if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' || c == ':' {
				componentBytes = 1
			}
			if size > maxPURLBytes-componentBytes {
				return errors.New("PURL canonical size cap exceeded")
			}
			size += componentBytes
		}
		return nil
	}
	if err := add(purl.PackageType, 0); err != nil {
		return err
	}
	if err := add(purl.Namespace, 1); err != nil {
		return err
	}
	if err := add(purl.Name, 1); err != nil {
		return err
	}
	if purl.Version != "" {
		if err := add(purl.Version, 1); err != nil {
			return err
		}
	}
	for key, value := range purl.Qualifiers {
		if err := add(key, 1); err != nil {
			return err
		}
		if err := add(value, 1); err != nil {
			return err
		}
	}
	return nil
}

func validPURLComponent(value string) bool {
	return value != "" && !strings.ContainsRune(value, '\x00')
}

func canonicalPURL(purl parsedPURL) string {
	var b strings.Builder
	b.WriteString("pkg:")
	b.WriteString(purl.PackageType)
	b.WriteByte('/')
	b.WriteString(escapePURLComponent(purl.Namespace))
	b.WriteByte('/')
	b.WriteString(escapePURLComponent(purl.Name))
	if purl.Version != "" {
		b.WriteByte('@')
		b.WriteString(escapePURLComponent(purl.Version))
	}
	keys := make([]string, 0, len(purl.Qualifiers))
	for key := range purl.Qualifiers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for i, key := range keys {
		if i == 0 {
			b.WriteByte('?')
		} else {
			b.WriteByte('&')
		}
		b.WriteString(escapePURLComponent(key))
		b.WriteByte('=')
		b.WriteString(escapePURLComponent(purl.Qualifiers[key]))
	}
	return b.String()
}

func escapePURLComponent(value string) string {
	const upperHex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(value); i++ {
		c := value[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' || c == ':' {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(upperHex[c>>4])
		b.WriteByte(upperHex[c&0x0f])
	}
	return b.String()
}

//nolint:err113 // Empty canonical-map entries are internal projection invariants and are not matched.
func encodeStringMap(values map[string]string) ([]byte, error) {
	keys := make([]string, 0, len(values))
	for key, value := range values {
		if key == "" || value == "" {
			return nil, errors.New("canonical map contains empty key or value")
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	writeU32(&b, uint32(len(keys)))
	for _, key := range keys {
		writeCanonicalField(&b, []byte(key))
		writeCanonicalField(&b, []byte(values[key]))
	}
	return b.Bytes(), nil
}

func encodeStringList(values []string) []byte {
	var b bytes.Buffer
	writeU32(&b, uint32(len(values)))
	for _, value := range values {
		writeCanonicalField(&b, []byte(value))
	}
	return b.Bytes()
}

func digestTuple(domain string, fields ...[]byte) ([sha256.Size]byte, []byte) {
	var b bytes.Buffer
	writeCanonicalField(&b, []byte(domain))
	writeU32(&b, uint32(len(fields)))
	for _, field := range fields {
		writeCanonicalField(&b, field)
	}
	canonical := b.Bytes()
	return sha256.Sum256(canonical), canonical
}

func digestTupleHex(domain string, fields ...[]byte) string {
	digest, _ := digestTuple(domain, fields...)
	return hex.EncodeToString(digest[:])
}

func writeCanonicalField(b *bytes.Buffer, field []byte) {
	if field == nil {
		writeU32(b, ^uint32(0))
		return
	}
	writeU32(b, uint32(len(field)))
	_, _ = b.Write(field)
}

func writeU32(b *bytes.Buffer, value uint32) {
	var encoded [4]byte
	binary.BigEndian.PutUint32(encoded[:], value)
	_, _ = b.Write(encoded[:])
}

func u32Field(value int) []byte {
	var encoded [4]byte
	binary.BigEndian.PutUint32(encoded[:], uint32(value))
	return encoded[:]
}

func u64Field(value int64) []byte {
	if value <= 0 {
		return nil
	}
	var encoded [8]byte
	binary.BigEndian.PutUint64(encoded[:], uint64(value))
	return encoded[:]
}

func u64ZeroField(value uint64) []byte {
	var encoded [8]byte
	binary.BigEndian.PutUint64(encoded[:], value)
	return encoded[:]
}

func boolField(value bool) []byte {
	if value {
		return []byte{1}
	}
	return []byte{0}
}

func optionalField(value string) []byte {
	if value == "" {
		return nil
	}
	return []byte(value)
}

func uuidBytes(digest [sha256.Size]byte) [16]byte {
	var id [16]byte
	copy(id[:], digest[:16])
	id[6] = (id[6] & 0x0f) | 0x80
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

func formatUUID(id [16]byte) string {
	encoded := hex.EncodeToString(id[:])
	return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32]
}

func vexStatementFingerprint(doc *rawVEX, statement *vexStatement) string {
	aliases := sortedUniqueStrings(statement.Vulnerability.Aliases)
	statementVersion := []byte(nil)
	if statement.Version != nil {
		statementVersion = u64Field(*statement.Version)
	}
	effectiveTimestamp := statement.Timestamp
	if effectiveTimestamp == "" {
		effectiveTimestamp = doc.Timestamp
	}
	return digestTupleHex(vexStatementDomain,
		u32Field(projectionVersion), []byte(doc.Context), []byte(doc.ID), []byte(doc.Author), u64Field(doc.Version), []byte(doc.Timestamp), optionalField(doc.LastUpdated),
		[]byte(statement.Vulnerability.Name), optionalField(statement.Vulnerability.ID), encodeStringList(aliases), optionalField(statement.Vulnerability.Description), statementVersion,
		optionalField(statement.Timestamp), optionalField(statement.LastUpdated), optionalField(statement.ActionStatementTimestamp), []byte(effectiveTimestamp), []byte(statement.Status),
		optionalField(statement.Justification), optionalField(statement.StatusNotes), optionalField(statement.ActionStatement), optionalField(statement.ImpactStatement),
	)
}

func projectionDigest(record projectedRecord) (string, error) {
	advisory, err := advisoryDigestBasis(record.Advisory)
	if err != nil {
		return "", err
	}
	coordinates, err := coordinatesDigestBasis(record.Coordinates)
	if err != nil {
		return "", err
	}
	refs, err := assertionRefsDigestBasis(record.Assertions)
	if err != nil {
		return "", err
	}
	return digestTupleHex(projectionDigestDomain,
		u32Field(projectionVersion), []byte(record.CVEID), advisory, coordinates, refs,
	), nil
}

//nolint:err113 // Negative counters are internal projection invariants and are not matched.
func advisoryDigestBasis(advisory advisorySummary) ([]byte, error) {
	provenance := advisory.Provenance
	for name, count := range map[string]int{
		"OSV affected":         provenance.OSVAffectedCount,
		"VEX statement":        provenance.VEXStatementCount,
		"repaired source PURL": provenance.RepairedSourcePURLCount,
	} {
		if count < 0 {
			return nil, fmt.Errorf("negative %s count", name)
		}
	}
	references := sortedUniqueStrings(advisory.References)
	_, canonical := digestTuple(advisoryDigestDomain,
		u32Field(projectionVersion),
		[]byte(advisory.SourceObjectID),
		[]byte(advisory.AdvisoryID),
		[]byte(advisory.CVEID),
		[]byte(advisory.Title),
		optionalField(advisory.Description),
		optionalField(advisory.Severity),
		optionalField(advisory.CVSSVector),
		optionalField(advisory.PublishedAt),
		optionalField(advisory.ModifiedAt),
		optionalField(advisory.WithdrawnAt),
		encodeStringList(references),
		boolField(provenance.OSVPresent),
		boolField(provenance.VEXPresent),
		boolField(provenance.OSVWithdrawn),
		boolField(provenance.VEXEmptyStatementsTombstone),
		u64ZeroField(uint64(provenance.OSVAffectedCount)),
		u64ZeroField(uint64(provenance.VEXStatementCount)),
		u64ZeroField(uint64(provenance.RepairedSourcePURLCount)),
	)
	return canonical, nil
}

func coordinatesDigestBasis(coordinates []coordinateDTO) ([]byte, error) {
	entries := make([][]byte, 0, len(coordinates))
	for _, coordinate := range coordinates {
		metadata, err := encodeStringMap(coordinate.Metadata)
		if err != nil {
			return nil, fmt.Errorf("coordinate metadata: %w", err)
		}
		_, canonical := digestTuple(coordinateDigestDomain,
			u32Field(projectionVersion),
			[]byte(coordinate.CoordinateType),
			[]byte(coordinate.Value),
			metadata,
		)
		entries = append(entries, canonical)
	}
	sort.Slice(entries, func(i, j int) bool { return bytes.Compare(entries[i], entries[j]) < 0 })
	fields := make([][]byte, 0, len(entries)+2)
	fields = append(fields, u32Field(projectionVersion), u32Field(len(entries)))
	fields = append(fields, entries...)
	_, canonical := digestTuple(coordinatesDigestDomain, fields...)
	return canonical, nil
}

func assertionRefsDigestBasis(assertions []assertionDTO) ([]byte, error) {
	entries := make([][]byte, 0, len(assertions))
	for _, assertion := range assertions {
		key, err := decodeHexDigest(assertion.AssertionKey, false)
		if err != nil {
			return nil, err
		}
		fingerprint, err := decodeHexDigest(assertion.StatementFingerprint, true)
		if err != nil {
			return nil, err
		}
		setID, err := decodeUUID(assertion.ProductSetRef, true)
		if err != nil {
			return nil, err
		}
		setDigest, err := decodeHexDigest(assertion.ProductSetDigest, true)
		if err != nil {
			return nil, err
		}
		_, canonical := digestTuple(assertionRefDigestDomain,
			u32Field(projectionVersion), key, fingerprint, setID, setDigest,
		)
		entries = append(entries, canonical)
	}
	sort.Slice(entries, func(i, j int) bool { return bytes.Compare(entries[i], entries[j]) < 0 })
	fields := make([][]byte, 0, len(entries)+2)
	fields = append(fields, u32Field(projectionVersion), u32Field(len(entries)))
	fields = append(fields, entries...)
	_, canonical := digestTuple(assertionRefsDigestDomain, fields...)
	return canonical, nil
}

//nolint:err113 // Digest validation diagnostics are local to canonical projection encoding.
func decodeHexDigest(value string, optional bool) ([]byte, error) {
	if value == "" && optional {
		return nil, nil
	}
	if len(value) != sha256.Size*2 {
		return nil, errors.New("invalid SHA256 digest")
	}
	decoded, err := hex.DecodeString(value)
	if err != nil {
		return nil, errors.New("invalid SHA256 digest")
	}
	return decoded, nil
}

//nolint:err113 // UUID validation diagnostics are local to canonical projection encoding.
func decodeUUID(value string, optional bool) ([]byte, error) {
	if value == "" && optional {
		return nil, nil
	}
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return nil, errors.New("invalid UUID")
	}
	compact := strings.ReplaceAll(value, "-", "")
	decoded, err := hex.DecodeString(compact)
	if err != nil || len(decoded) != 16 {
		return nil, errors.New("invalid UUID")
	}
	return decoded, nil
}

func digestHex(value []byte) string {
	digest := sha256.Sum256(value)
	return hex.EncodeToString(digest[:])
}

func latestTimestamp(values []string) string {
	var latest time.Time
	var selected string
	for _, value := range values {
		if value == "" {
			continue
		}
		parsed, err := time.Parse(time.RFC3339Nano, value)
		if err == nil && (selected == "" || parsed.After(latest)) {
			latest, selected = parsed, value
		}
	}
	return selected
}

func sortedUniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value != "" {
			seen[value] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for value := range seen {
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}

func dedupeCoordinates(values []coordinateDTO) []coordinateDTO {
	if len(values) < 2 {
		return values
	}
	out := values[:1]
	for _, value := range values[1:] {
		if value.Value != out[len(out)-1].Value {
			out = append(out, value)
		}
	}
	return out
}

func cloneQualifiers(values map[string]string) map[string]string {
	out := make(map[string]string, len(values))
	for key, value := range values {
		out[key] = value
	}
	return out
}

func firstNonempty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func firstIf(condition bool, value string) string {
	if condition {
		return value
	}
	return ""
}

func nilIfEmpty(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func optionalInt64(value *int64) any {
	if value == nil {
		return nil
	}
	return *value
}

//nolint:err113 // Assertion-size diagnostics are internal projection invariants and are not matched.
func validateAssertionObjects(assertion assertionDTO) error {
	for name, object := range map[string]map[string]any{
		"validation": assertion.Validation,
		"provenance": assertion.Provenance,
		"metadata":   assertion.Metadata,
	} {
		encoded, err := json.Marshal(object)
		if err != nil {
			return fmt.Errorf("encode assertion %s: %w", name, err)
		}
		if len(encoded) > maxAssertionObjectBytes {
			return fmt.Errorf("assertion %s exceeds 8 KiB projection cap", name)
		}
	}
	return nil
}
