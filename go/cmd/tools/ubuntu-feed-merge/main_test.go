package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/ulikunitz/xz"
)

const syntheticPrimaryCVE = "CVE-2099-1001"

func TestStreamProjectsCanonicalDocumentsIntoCompactV2DTO(t *testing.T) {
	dir := t.TempDir()
	osvRaw := validOSV(syntheticPrimaryCVE)
	vexRaw := validVEX(syntheticPrimaryCVE)
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(syntheticPrimaryCVE), osvRaw}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(syntheticPrimaryCVE), vexRaw}})

	var out bytes.Buffer
	if err := merge(osv, vex, &out, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(out.Bytes(), []byte("SYNTHETIC_RAW_SENTINEL")) || bytes.Contains(out.Bytes(), []byte(`"schema_version":"synthetic-v1"`)) {
		t.Fatal("raw Canonical document content crossed the stream boundary")
	}
	frames := readFrames(t, out.Bytes())
	if len(frames) != 2 || frames[0][0] != recordFrame || frames[1][0] != controlFrame {
		t.Fatalf("frame types/count = %v/%d", frameTypes(frames), len(frames))
	}

	assertProjectedRecord(t, frames[0])
	assertProjectedTerminal(t, frames[1], frames, out.Len())
}

func assertProjectedRecord(t *testing.T, frame []byte) {
	t.Helper()
	var record testProjectedRecord
	if err := json.Unmarshal(frame[1:], &record); err != nil {
		t.Fatalf("record is not compact JSON: %v", err)
	}
	if record.ProtocolVersion != 2 || record.CVEID != syntheticPrimaryCVE || !isSHA256(record.ProjectionDigest) {
		t.Fatalf("record identity/version/digest = %#v", record)
	}
	if record.Advisory.SourceObjectID != "UBUNTU-"+syntheticPrimaryCVE || record.Advisory.Description != "fictional projected advisory" {
		t.Fatalf("advisory summary = %#v", record.Advisory)
	}
	if !isSHA256(record.Advisory.Provenance.OSVDocumentSHA256) || !isSHA256(record.Advisory.Provenance.VEXDocumentSHA256) {
		t.Fatalf("document provenance = %#v", record.Advisory.Provenance)
	}
	if len(record.Coordinates) != 1 || record.Coordinates[0].Value != "pkg:deb/ubuntu/asterism-src@8.0-test1?arch=source&distro=aurora" {
		t.Fatalf("coordinates = %#v", record.Coordinates)
	}
	if len(record.Assertions) != 2 {
		t.Fatalf("assertions = %d, want one OSV affected plus one VEX statement", len(record.Assertions))
	}
	if len(record.ProductSets) != 2 {
		t.Fatalf("product sets = %d, want one per semantic assertion", len(record.ProductSets))
	}
	if len(record.Products) != 6 {
		t.Fatalf("new product definitions = %d, want exact OSV and VEX products", len(record.Products))
	}
	for _, product := range record.Products {
		if !isUUID(product.ID) || !isUUID(product.LookupKey) || !isSHA256(product.Digest) || product.Version == "" || product.PURL == "" {
			t.Fatalf("invalid product DTO: %#v", product)
		}
	}
	for _, set := range record.ProductSets {
		if !isUUID(set.ID) || !isSHA256(set.Digest) || set.Count != len(set.ProductIDs) || set.CanonicalSizeBytes <= 0 {
			t.Fatalf("invalid product-set DTO: %#v", set)
		}
	}
	if got := record.Assertions[0].AffectedVersions; len(got) != 0 {
		t.Fatalf("OSV exact versions duplicated outside product set: %#v", got)
	}
	if record.Assertions[1].StatementFingerprint == "" || !isSHA256(record.Assertions[1].StatementFingerprint) {
		t.Fatalf("VEX statement fingerprint = %q", record.Assertions[1].StatementFingerprint)
	}
}

func assertProjectedTerminal(t *testing.T, frame []byte, frames [][]byte, outputBytes int) {
	t.Helper()
	var terminal testTerminal
	if err := json.Unmarshal(frame[1:], &terminal); err != nil {
		t.Fatalf("terminal is not JSON: %v", err)
	}
	if terminal.ProtocolVersion != 2 || terminal.CVECount != 1 || terminal.OSVDocumentCount != 1 || terminal.VEXDocumentCount != 1 || terminal.OSVAffectedEntryCount != 1 || terminal.VEXStatementCount != 1 || terminal.AssertionCount != 2 || terminal.LogicalProductOccurrenceCount != 6 || terminal.UniqueProductCount != 6 || terminal.UniqueProductSetCount != 2 {
		t.Fatalf("terminal counters = %#v", terminal)
	}
	if terminal.EmittedFrameCount != int64(len(frames)) || terminal.EmittedBytes != int64(outputBytes) || terminal.MaxFrameBytes != int64(maxPayloadLen(frames)) {
		t.Fatalf("terminal wire counters = %#v, bytes=%d frames=%d max=%d", terminal, outputBytes, len(frames), maxPayloadLen(frames))
	}
}

func TestProjectionSuppressesGlobalDefinitionsWithoutChangingDigest(t *testing.T) {
	cve := syntheticPrimaryCVE
	osvRaw, vexRaw := []byte(validOSV(cve)), []byte(validVEX(cve))
	fresh, err := projectRecord(cve, osvRaw, vexRaw, strings.Repeat("a", 64), strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	state := newProjectionState()
	first, err := projectRecord(cve, osvRaw, vexRaw, strings.Repeat("a", 64), strings.Repeat("b", 64), state)
	if err != nil {
		t.Fatal(err)
	}
	reused, err := projectRecord(cve, osvRaw, vexRaw, strings.Repeat("a", 64), strings.Repeat("b", 64), state)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Products) == 0 || len(first.ProductSets) == 0 || len(reused.Products) != 0 || len(reused.ProductSets) != 0 {
		t.Fatalf("definition suppression = first %d/%d reused %d/%d", len(first.Products), len(first.ProductSets), len(reused.Products), len(reused.ProductSets))
	}
	if reused.ProjectionDigest != fresh.ProjectionDigest || reused.ProjectionDigest != first.ProjectionDigest {
		t.Fatalf("projection digest depends on definition emission: fresh=%s first=%s reused=%s", fresh.ProjectionDigest, first.ProjectionDigest, reused.ProjectionDigest)
	}
	for _, assertion := range reused.Assertions {
		if assertion.ProductSetRef != "" && !isSHA256(assertion.ProductSetDigest) {
			t.Fatalf("reused assertion cannot validate prior set: %#v", assertion)
		}
	}
}

func TestCanonicalHashGoldenVectors(t *testing.T) {
	cve := syntheticPrimaryCVE
	record, err := projectRecord(cve, []byte(validOSV(cve)), []byte(validVEX(cve)), strings.Repeat("a", 64), strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	var source productDTO
	for _, product := range record.Products {
		if product.Name == "asterism-src" && product.Version == "6.5+test2" && product.Scope == sourceArchitecture {
			source = product
		}
	}
	if source.ID != "9745b665-5c38-809a-9e66-aaea58f46f91" ||
		source.Digest != "9745b6655c38209a5e66aaea58f46f91baa078bd3383d2772d5e69db95ab563a" ||
		source.LookupKey != "6436da1f-3a70-8f18-8217-2f6d1c939608" ||
		source.CanonicalSizeBytes != 224 {
		t.Fatalf("source product golden vector = %#v", source)
	}
	var osvSet productSetDTO
	for _, set := range record.ProductSets {
		if set.Count == 4 {
			osvSet = set
		}
	}
	wantIDs := []string{
		"1cf6a98d-3dea-899d-80bb-b5aa5d5dbb48",
		"9745b665-5c38-809a-9e66-aaea58f46f91",
		"d238e80c-3c6f-8559-abd2-1e50f1b73c06",
		"d42371bb-07de-83cc-ad06-f9774deb9d7c",
	}
	if osvSet.ID != "35c5ed12-4fc1-8682-9da7-27c58636fcd4" ||
		osvSet.Digest != "35c5ed124fc106821da727c58636fcd45e2782149e143715e9195ad8fb6f04a3" ||
		osvSet.CanonicalSizeBytes != 138 || !equalStrings(osvSet.ProductIDs, wantIDs) {
		t.Fatalf("OSV product-set golden vector = %#v", osvSet)
	}
	var osvAssertion, vexAssertion assertionDTO
	for _, assertion := range record.Assertions {
		switch assertion.SourceKind {
		case "ubuntu_osv":
			osvAssertion = assertion
		case "ubuntu_openvex":
			vexAssertion = assertion
		}
	}
	if osvAssertion.AssertionKey != "51977436a498d8d5b63a480cc9854eafe9cedc53cefdf34337487429f61bc8ef" {
		t.Fatalf("OSV assertion-key golden vector = %s", osvAssertion.AssertionKey)
	}
	if vexAssertion.StatementFingerprint != "7476e3a0a1bd79d2b23fc28eb6d53d036ac7f87c6f03a6d8b8df535fc64137cc" ||
		vexAssertion.AssertionKey != "5ab9ea18e22539f94f6c5b15c4716a30c1a2502e8facfff068912631ea76b382" {
		t.Fatalf("VEX fingerprint/key golden vectors = %s/%s", vexAssertion.StatementFingerprint, vexAssertion.AssertionKey)
	}
}

func TestProductDTOCarriesNormalizationVersion(t *testing.T) {
	record, err := projectRecord(syntheticPrimaryCVE, []byte(validOSV(syntheticPrimaryCVE)), nil, strings.Repeat("a", 64), "", newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	for _, product := range record.Products {
		if product.NormalizationVersion != projectionVersion {
			t.Fatalf("product normalization_version = %d", product.NormalizationVersion)
		}
	}
}

func TestPURLCanonicalEncodingMatchesElixirBoundary(t *testing.T) {
	inputs := []string{
		"pkg:deb/ubuntu/fictional%40component@99:1.0~test+build%231?source=asterism-src%40testing&note=a%3Fb%23c",
		"pkg:deb/ubuntu/fictional%40component@99:1.0~test%2Bbuild%231?note=a%3Fb%23c&source=asterism-src%40testing",
	}
	want := "pkg:deb/ubuntu/fictional%40component@99:1.0~test%2Bbuild%231?note=a%3Fb%23c&source=asterism-src%40testing"
	for _, input := range inputs {
		parsed, repaired, err := parseUbuntuPURL(input, false)
		if err != nil {
			t.Fatalf("parse %q: %v", input, err)
		}
		if repaired || parsed.Canonical != want {
			t.Fatalf("canonicalize %q = %q repaired=%v, want %q", input, parsed.Canonical, repaired, want)
		}
	}
}

func TestWithdrawnOSVEmitsTombstoneWithoutCoordinatesOrAssertions(t *testing.T) {
	cve := syntheticPrimaryCVE
	osv := strings.Replace(validOSV(cve), `"modified":"2099-01-03T04:05:06Z",`, `"modified":"2099-01-03T04:05:06Z","withdrawn":"2099-01-04T05:06:07Z",`, 1)
	state := newProjectionState()
	record, err := projectRecord(cve, []byte(osv), []byte(validVEX(cve)), strings.Repeat("a", 64), strings.Repeat("b", 64), state)
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Coordinates) != 0 {
		t.Fatalf("withdrawn OSV emitted coordinates: %#v", record.Coordinates)
	}
	if len(record.Assertions) != 1 || record.Assertions[0].SourceKind != "ubuntu_openvex" {
		t.Fatalf("withdrawn OSV assertions = %#v", record.Assertions)
	}
	if !record.Advisory.Provenance.OSVWithdrawn || record.Advisory.WithdrawnAt != "2099-01-04T05:06:07Z" || state.counters.WithdrawnDocuments != 1 {
		t.Fatalf("withdrawal provenance/counters = %#v/%#v", record.Advisory, state.counters)
	}
}

func TestOSVExactMalformedSourcePURLRepairIsAuditable(t *testing.T) {
	cve := syntheticPrimaryCVE
	rawPURL := "pkg:deb/ubuntu/asterism-src?arch=src?distro=aurora"
	osv := strings.Replace(validOSV(cve), "pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source", rawPURL, 1)
	record, err := projectRecord(cve, []byte(osv), nil, strings.Repeat("a", 64), "", newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	if record.Advisory.Provenance.RepairedSourcePURLCount != 1 || len(record.Assertions) != 1 || record.Assertions[0].PackagePURL != "pkg:deb/ubuntu/asterism-src?arch=src&distro=aurora" || record.Assertions[0].Provenance["raw_source_purl"] != rawPURL {
		t.Fatalf("repair provenance = %#v/%#v", record.Advisory.Provenance, record.Assertions)
	}
	found := false
	for _, product := range record.Products {
		if product.Scope == sourceArchitecture {
			found = true
			if !product.Metadata.SourcePURLRepaired || product.Metadata.RawSourcePURL != rawPURL || !strings.Contains(product.PURL, "?arch=src&distro=aurora") {
				t.Fatalf("repaired source product = %#v", product)
			}
		}
	}
	if !found {
		t.Fatal("repaired OSV emitted no exact source product")
	}
	otherMalformed := strings.Replace(validOSV(cve), "pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source", "pkg:deb/ubuntu/asterism-src@8.0-test1?arch=source?distro=aurora", 1)
	if _, err := projectRecord(cve, []byte(otherMalformed), nil, strings.Repeat("a", 64), "", newProjectionState()); err == nil {
		t.Fatal("unapproved malformed PURL repair was accepted")
	}
	versionedRepairFamily := strings.Replace(validOSV(cve), "pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source", "pkg:deb/ubuntu/asterism-src@8.0-test1?arch=src?distro=aurora", 1)
	if _, err := projectRecord(cve, []byte(versionedRepairFamily), nil, strings.Repeat("a", 64), "", newProjectionState()); err == nil {
		t.Fatal("versioned PURL outside the audited repair family was accepted")
	}
}

func TestOSVRangeOnlyAffectedEntryKeepsNilProductSet(t *testing.T) {
	cve := syntheticPrimaryCVE
	osv := strings.Replace(validOSV(cve), `"versions":["7:6.0~test1","6.5+test2"],`, `"versions":[],`, 1)
	osv = strings.Replace(osv, `"binaries":[{"binary_name":"asterism-cli","binary_version":"8.0-test1"},{"binary_name":"libasterism","binary_version":"8.0-test1"}]`, `"binaries":[]`, 1)
	record, err := projectRecord(cve, []byte(osv), nil, strings.Repeat("a", 64), "", newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Assertions) != 1 || record.Assertions[0].ProductSetRef != "" || record.Assertions[0].ProductSetDigest != "" || len(record.Products) != 0 || len(record.ProductSets) != 0 {
		t.Fatalf("range-only OSV projection = %#v", record)
	}
}

func TestProjectOSVRejectsLogicalProductWhenRecordBudgetIsExhausted(t *testing.T) {
	cve := "CVE-2099-4101"
	doc, err := parseOSV(cve, []byte(syntheticBudgetOSV(cve)))
	if err != nil {
		t.Fatal(err)
	}
	doc.Affected[0].Versions = []string{"7.0-test1"}
	doc.Affected[0].EcosystemSpecific.Binaries = nil

	builder := newProjectionBuilder(cve)
	builder.logical = maxLogicalProductsPerRecord
	record := projectedRecord{CVEID: cve, Assertions: []assertionDTO{}}
	err = projectOSV(builder, &record, doc, advisoryProvenance{})
	if err == nil || !strings.Contains(err.Error(), "logical product cap") {
		t.Fatalf("exhausted logical-product budget error = %v", err)
	}
	if len(builder.products) != 0 || len(builder.sets) != 0 || len(record.Assertions) != 0 {
		t.Fatalf("OSV projection mutated state after exhausted budget: products=%d sets=%d assertions=%d", len(builder.products), len(builder.sets), len(record.Assertions))
	}
}

func TestProjectOSVRejectsAffectedEntriesBeyondAssertionBudgetBeforeProjection(t *testing.T) {
	cve := "CVE-2099-4102"
	doc, err := parseOSV(cve, []byte(syntheticBudgetOSV(cve)))
	if err != nil {
		t.Fatal(err)
	}
	first := doc.Affected[0]
	first.Versions = nil
	first.EcosystemSpecific.Binaries = nil
	second := first
	second.Package.Ecosystem = "Ubuntu:98.98:LTS"
	second.Package.Name = "nebula-engine-src"
	second.Package.PURL = "pkg:deb/ubuntu/nebula-engine-src@6.0-test1?arch=source&distro=zenith"
	doc.Affected = []osvAffected{first, second}

	limits := defaultProjectionLimits()
	limits.assertions = 1
	builder := newProjectionBuilderWithLimits(cve, limits)
	record := projectedRecord{CVEID: cve, Assertions: []assertionDTO{}}
	err = projectOSV(builder, &record, doc, advisoryProvenance{})
	if err == nil || !strings.Contains(err.Error(), "assertion cap") {
		t.Fatalf("exhausted assertion budget error = %v", err)
	}
	if len(builder.products) != 0 || len(builder.sets) != 0 || len(record.Assertions) != 0 {
		t.Fatalf("OSV projection mutated state after oversized assertion count: products=%d sets=%d assertions=%d", len(builder.products), len(builder.sets), len(record.Assertions))
	}
}

func TestProjectVEXRejectsRootProductsBeyondLogicalBudgetBeforeProjection(t *testing.T) {
	cve := "CVE-2099-4103"
	doc, err := parseVEX(cve, []byte(validVEX(cve)))
	if err != nil {
		t.Fatal(err)
	}
	product := doc.Statements[0].Products[0]
	product.Subcomponents = nil
	doc.Statements[0].Products = []vexProduct{product, product}

	limits := defaultProjectionLimits()
	limits.logicalProducts = 1
	builder := newProjectionBuilderWithLimits(cve, limits)
	record := projectedRecord{CVEID: cve, Assertions: []assertionDTO{}}
	err = projectVEX(builder, &record, doc, advisoryProvenance{})
	if err == nil || !strings.Contains(err.Error(), "logical product cap") {
		t.Fatalf("oversized VEX root-product count error = %v", err)
	}
	if len(builder.products) != 0 || len(builder.sets) != 0 || len(record.Assertions) != 0 {
		t.Fatalf("VEX projection mutated state after oversized root-product count: products=%d sets=%d assertions=%d", len(builder.products), len(builder.sets), len(record.Assertions))
	}
}

func TestProjectOSVPreflightsLogicalProductsAcrossAllAffectedEntries(t *testing.T) {
	cve := "CVE-2099-4104"
	doc, err := parseOSV(cve, []byte(syntheticOSVDocument(cve, []map[string]any{
		syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{"7.0-test1"}),
		syntheticOSVAffected("nebula-engine-src", "zenith", "98.98:LTS", []string{"6.0-test1"}),
	})))
	if err != nil {
		t.Fatal(err)
	}

	limits := defaultProjectionLimits()
	limits.logicalProducts = 1
	builder := newProjectionBuilderWithLimits(cve, limits)
	record := projectedRecord{CVEID: cve, Assertions: []assertionDTO{}}
	err = projectOSV(builder, &record, doc, advisoryProvenance{})
	if err == nil || !strings.Contains(err.Error(), "logical product cap") {
		t.Fatalf("aggregate OSV product-count error = %v", err)
	}
	if builder.logical != 0 || len(builder.products) != 0 || len(builder.sets) != 0 || len(record.Coordinates) != 0 || len(record.Assertions) != 0 {
		t.Fatalf("OSV projection mutated state before aggregate rejection: logical=%d products=%d sets=%d coordinates=%d assertions=%d", builder.logical, len(builder.products), len(builder.sets), len(record.Coordinates), len(record.Assertions))
	}
}

func TestProjectVEXPreflightsDescendantProductsBeforeProjection(t *testing.T) {
	cve := "CVE-2099-4105"
	doc, err := parseVEX(cve, []byte(validVEX(cve)))
	if err != nil {
		t.Fatal(err)
	}

	limits := defaultProjectionLimits()
	limits.logicalProducts = 1
	builder := newProjectionBuilderWithLimits(cve, limits)
	record := projectedRecord{CVEID: cve, Assertions: []assertionDTO{}}
	err = projectVEX(builder, &record, doc, advisoryProvenance{})
	if err == nil || !strings.Contains(err.Error(), "logical product cap") {
		t.Fatalf("descendant VEX product-count error = %v", err)
	}
	if builder.logical != 0 || len(builder.products) != 0 || len(builder.sets) != 0 || len(record.Assertions) != 0 {
		t.Fatalf("VEX projection mutated state before descendant rejection: logical=%d products=%d sets=%d assertions=%d", builder.logical, len(builder.products), len(builder.sets), len(record.Assertions))
	}
}

func TestProjectVEXPreflightsNestingDepthBeforeProjection(t *testing.T) {
	cve := "CVE-2099-4106"
	doc, err := parseVEX(cve, []byte(validVEX(cve)))
	if err != nil {
		t.Fatal(err)
	}
	base := doc.Statements[0].Products[0]
	base.Subcomponents = nil
	nested := base
	for i := 0; i <= maxProductDepth; i++ {
		parent := base
		parent.Subcomponents = []vexProduct{nested}
		nested = parent
	}
	doc.Statements[0].Products = []vexProduct{nested}

	builder := newProjectionBuilder(cve)
	record := projectedRecord{CVEID: cve, Assertions: []assertionDTO{}}
	err = projectVEX(builder, &record, doc, advisoryProvenance{})
	if err == nil || !strings.Contains(err.Error(), "nesting cap") {
		t.Fatalf("VEX nesting-depth error = %v", err)
	}
	if builder.logical != 0 || len(builder.products) != 0 || len(builder.sets) != 0 || len(record.Assertions) != 0 {
		t.Fatalf("VEX projection mutated state before depth rejection: logical=%d products=%d sets=%d assertions=%d", builder.logical, len(builder.products), len(builder.sets), len(record.Assertions))
	}
}

func TestProjectRecordPreflightsCombinedAssertionCount(t *testing.T) {
	cve := "CVE-2099-4107"
	limits := defaultProjectionLimits()
	limits.assertions = 1

	_, err := projectRecordWithLimits(
		cve,
		[]byte(validOSV(cve)),
		[]byte(validVEX(cve)),
		strings.Repeat("a", 64),
		strings.Repeat("b", 64),
		newProjectionState(),
		limits,
	)
	if err == nil || !strings.Contains(err.Error(), "assertion cap") {
		t.Fatalf("combined assertion-count error = %v", err)
	}
}

func TestOSVMissingSourcePURLIsRetainedAsUnscopedEvidence(t *testing.T) {
	cve := syntheticPrimaryCVE
	osv := strings.Replace(
		validOSV(cve),
		`,"purl":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source"`,
		``,
		1,
	)
	state := newProjectionState()
	record, err := projectRecord(cve, []byte(osv), nil, strings.Repeat("a", 64), "", state)
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Coordinates) != 0 {
		t.Fatalf("missing source PURL emitted a fabricated coordinate: %#v", record.Coordinates)
	}
	if len(record.Assertions) != 1 || record.Assertions[0].PackagePURL != "" || record.Assertions[0].Release != "" || record.Assertions[0].ProductSetRef == "" {
		t.Fatalf("unscoped OSV assertion = %#v", record.Assertions)
	}
	if state.counters.UnscopedProducts != int64(len(record.Products)) || len(record.Products) != 4 {
		t.Fatalf("unscoped product accounting = %d products=%#v", state.counters.UnscopedProducts, record.Products)
	}
	for _, product := range record.Products {
		if product.Release != "" || product.Distro != "" || !product.Metadata.MissingRelease {
			t.Fatalf("missing source PURL was not retained as unscoped: %#v", product)
		}
	}
}

func TestVEXMissingDistroIsRetainedAsUnscopedEvidence(t *testing.T) {
	cve := syntheticPrimaryCVE
	vex := strings.Replace(validVEX(cve), "?distro=aurora&arch=source", "?arch=source", 1)
	vex = strings.ReplaceAll(vex, "&distro=aurora", "")
	state := newProjectionState()
	record, err := projectRecord(cve, nil, []byte(vex), "", strings.Repeat("b", 64), state)
	if err != nil {
		t.Fatal(err)
	}
	if state.counters.UnscopedProducts != 2 {
		t.Fatalf("unscoped product count = %d", state.counters.UnscopedProducts)
	}
	for _, product := range record.Products {
		if product.Release != "" || product.Distro != "" || !product.Metadata.MissingRelease {
			t.Fatalf("missing distro was not retained as unscoped: %#v", product)
		}
	}
}

func TestVEXStatementTimestampInheritsDocumentTimestampOnly(t *testing.T) {
	cve := syntheticPrimaryCVE
	vex := strings.Replace(validVEX(cve), `"timestamp":"2099-01-02T03:04:05Z",`, "", 1)
	record, err := projectRecord(cve, nil, []byte(vex), "", strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	assertion := record.Assertions[0]
	if assertion.SourceTimestamp != "2099-01-05T06:07:08.123456Z" {
		t.Fatalf("effective statement timestamp = %q", assertion.SourceTimestamp)
	}
	basis := assertion.Validation["fingerprint_basis"].(map[string]any)
	if basis["statement_timestamp"] != nil || basis["effective_timestamp"] != assertion.SourceTimestamp || basis["document_last_updated"] != "2099-01-06T07:08:09Z" || basis["action_statement"] != nil || basis["impact_statement"] != "fictional component omitted" {
		t.Fatalf("fingerprint basis = %#v", basis)
	}
}

func TestVEXRejectsConflictingProductPURLs(t *testing.T) {
	cve := syntheticPrimaryCVE
	vex := strings.Replace(validVEX(cve), `{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source",`, `{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source","identifiers":{"purl":"pkg:deb/ubuntu/counterfactual-src@8.0-test1?arch=source&distro=aurora"},`, 1)
	if _, err := projectRecord(cve, nil, []byte(vex), "", strings.Repeat("b", 64), newProjectionState()); err == nil || !strings.Contains(err.Error(), "conflicting VEX product PURLs") {
		t.Fatalf("conflicting product PURLs error = %v", err)
	}
}

func TestVEXAllowsRelatedCVEReferenceAliasButRejectsConflictingIdentity(t *testing.T) {
	cve := syntheticPrimaryCVE
	vex := strings.Replace(
		validVEX(cve),
		`"aliases":["https://advisories.example.invalid/CVE-2099-1001"]`,
		`"aliases":["https://advisories.example.invalid/CVE-2099-1001","https://related.example.invalid/CVE-2099-1002"]`,
		1,
	)
	if _, err := projectRecord(cve, nil, []byte(vex), "", strings.Repeat("b", 64), newProjectionState()); err != nil {
		t.Fatalf("related CVE reference alias was rejected: %v", err)
	}

	conflictingIdentity := strings.Replace(
		vex,
		"https://identifiers.example.invalid/CVE-2099-1001",
		"https://identifiers.example.invalid/CVE-2099-1002",
		1,
	)
	if _, err := projectRecord(cve, nil, []byte(conflictingIdentity), "", strings.Repeat("b", 64), newProjectionState()); err == nil || !strings.Contains(err.Error(), "conflicting CVE-2099-1002") {
		t.Fatalf("conflicting vulnerability identity error = %v", err)
	}
}

func TestVEXCanonicalMetadataEnvelopeAndLegacyUTCTimestamps(t *testing.T) {
	cve := "CVE-2099-1101"
	vex := fmt.Sprintf(`{
  "metadata":{
    "@context":"https://openvex.dev/ns/v0.2.0",
    "@id":"https://metadata.example.invalid/enveloped/%[1]s",
    "author":"Canonical Ltd.",
    "timestamp":"2099-02-03T04:05:06.333071",
    "version":27
  },
  "statements":[{
    "vulnerability":{"@id":"https://identifiers.example.invalid/%[1]s","name":"%[1]s"},
    "timestamp":"2099-02-01 02:03:04 UTC",
    "products":[{"@id":"pkg:deb/ubuntu/fictional-kernel-src@99.1-test1?arch=source&distro=aurora"}],
    "status":"affected",
    "action_statement":"Synthetic remediation decision"
  }]
}`, cve)

	record, err := projectRecord(cve, nil, []byte(vex), "", strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatalf("Canonical metadata envelope rejected: %v", err)
	}
	if len(record.Assertions) != 1 || record.Assertions[0].SourceTimestamp != "2099-02-01T02:03:04Z" {
		t.Fatalf("legacy statement timestamp was not normalized: %#v", record.Assertions)
	}
	basis := record.Assertions[0].Validation["fingerprint_basis"].(map[string]any)
	if basis["document_timestamp"] != "2099-02-03T04:05:06.333071Z" || basis["document_id"] == "" {
		t.Fatalf("metadata envelope was not normalized into fingerprint evidence: %#v", basis)
	}

	conflicting := strings.Replace(vex, `"metadata":{`, `"@context":"https://example.invalid/openvex","metadata":{`, 1)
	if _, err := projectRecord(cve, nil, []byte(conflicting), "", strings.Repeat("b", 64), newProjectionState()); err == nil || !strings.Contains(err.Error(), "conflicting VEX document metadata") {
		t.Fatalf("conflicting top-level/enveloped metadata error = %v", err)
	}
}

func TestGlobalProductSetIdentityExcludesCVEStatusAndProductOrder(t *testing.T) {
	productsA := `[{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?arch=source&distro=aurora"},{"@id":"pkg:deb/ubuntu/libasterism@8.0-test1?arch=amd64&distro=aurora"}]`
	productsB := `[{"@id":"pkg:deb/ubuntu/libasterism@8.0-test1?distro=aurora&arch=amd64"},{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source"}]`
	a, err := projectRecord("CVE-2099-1201", nil, []byte(vexWithProducts("CVE-2099-1201", "fixed", productsA)), "", strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	b, err := projectRecord("CVE-2099-1202", nil, []byte(vexWithProducts("CVE-2099-1202", "under_investigation", productsB)), "", strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	if len(a.ProductSets) != 1 || len(b.ProductSets) != 1 || a.ProductSets[0].ID != b.ProductSets[0].ID || a.ProductSets[0].Digest != b.ProductSets[0].Digest {
		t.Fatalf("global set identity depends on assertion semantics/order: %#v / %#v", a.ProductSets, b.ProductSets)
	}
	if a.Assertions[0].AssertionKey == b.Assertions[0].AssertionKey || a.Assertions[0].StatementFingerprint == b.Assertions[0].StatementFingerprint {
		t.Fatal("VEX assertion semantics did not affect statement/assertion identity")
	}
}

func TestAssertionProjectionObjectsAreBounded(t *testing.T) {
	cve := syntheticPrimaryCVE
	vex := strings.Replace(validVEX(cve), `"description":"fictional VEX detail"`, fmt.Sprintf(`"description":%q`, strings.Repeat("x", 9<<10)), 1)
	if _, err := projectRecord(cve, nil, []byte(vex), "", strings.Repeat("b", 64), newProjectionState()); err == nil || !strings.Contains(err.Error(), "8 KiB") {
		t.Fatalf("oversized assertion projection error = %v", err)
	}
}

func TestProjectionDigestIsSemanticAndExcludesRunDigests(t *testing.T) {
	cve := syntheticPrimaryCVE
	osv := strings.Replace(validOSV(cve), "fictional projected advisory", "fictional <advisory> & café \u2028", 1)
	first, err := projectRecord(cve, []byte(osv), []byte(validVEX(cve)), strings.Repeat("a", 64), strings.Repeat("b", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	second, err := projectRecord(cve, []byte(osv), []byte(validVEX(cve)), strings.Repeat("c", 64), strings.Repeat("d", 64), newProjectionState())
	if err != nil {
		t.Fatal(err)
	}
	if first.ProjectionDigest != second.ProjectionDigest {
		t.Fatalf("archive digests changed semantic projection digest: %s != %s", first.ProjectionDigest, second.ProjectionDigest)
	}
	const want = "ff6d81690cbcf3347db7416e4e838e0010b15c4f0e1bfc21b30f6b5122786fa0"
	if first.ProjectionDigest != want {
		t.Fatalf("semantic projection digest golden = %s, want %s", first.ProjectionDigest, want)
	}
	if os.Getenv("UBUNTU_PROJECTOR_PRINT_GOLDEN") == "1" {
		encoded, err := json.Marshal(first)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("projected record v2: %s", encoded)
	}
}

func TestMergeIncludesVEXOnlyAndFinalCompleteness(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{
		{syntheticOSVPath("CVE-2099-1303"), validOSV("CVE-2099-1303")},
		{syntheticOSVPath("CVE-2099-1302"), validOSV("CVE-2099-1302")},
	})
	vex := archive(t, dir, "vex.tar.xz", []entry{
		{syntheticVEXPath("CVE-2099-1301"), validVEX("CVE-2099-1301")},
		{syntheticVEXPath("CVE-2099-1303"), validVEX("CVE-2099-1303")},
	})

	var out bytes.Buffer
	if err := merge(osv, vex, &out, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	frames := readFrames(t, out.Bytes())
	if len(frames) != 4 || frames[0][0] != recordFrame || frames[3][0] != controlFrame {
		t.Fatalf("frames = %d/types %v", len(frames), []byte{frames[0][0], frames[len(frames)-1][0]})
	}
	if !bytes.Contains(frames[0], []byte("CVE-2099-1301")) {
		t.Fatalf("first record is not sorted VEX-only CVE: %q", frames[0])
	}
	if !bytes.Contains(frames[1], []byte("CVE-2099-1302")) {
		t.Fatalf("second record is not the OSV-only CVE: %q", frames[1])
	}
	if !bytes.Contains(frames[3], []byte(`"record_count":3`)) || !bytes.Contains(frames[3], []byte(`"osv_count":2`)) || !bytes.Contains(frames[3], []byte(`"vex_count":2`)) {
		t.Fatalf("control frame = %s", frames[3])
	}
}

func TestMergeOmitsTerminalWhenLaterRecordFailsSemanticProjection(t *testing.T) {
	firstCVE := "CVE-2099-1311"
	secondCVE := "CVE-2099-1312"
	invalidSecondOSV := strings.Replace(
		validOSV(secondCVE),
		`"modified":"2099-01-03T04:05:06Z"`,
		`"modified":"not-a-timestamp"`,
		1,
	)
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{
		{syntheticOSVPath(firstCVE), validOSV(firstCVE)},
		{syntheticOSVPath(secondCVE), invalidSecondOSV},
	})
	vex := archive(t, dir, "vex.tar.xz", []entry{
		{syntheticVEXPath(firstCVE), syntheticVEXTombstone(firstCVE)},
		{syntheticVEXPath(secondCVE), syntheticVEXTombstone(secondCVE)},
	})

	var out bytes.Buffer
	err := merge(osv, vex, &out, defaultLimits())
	if err == nil || !strings.Contains(err.Error(), "invalid OSV modified timestamp") {
		t.Fatalf("late semantic projection error = %v", err)
	}
	frames := readFrames(t, out.Bytes())
	if len(frames) != 1 || frames[0][0] != recordFrame {
		t.Fatalf("late semantic failure frames = %d/types %v, want one record and no terminal", len(frames), frameTypes(frames))
	}
	assertIncompleteProjectionStream(t, out.Bytes())
}

func TestStreamOmitsTerminalWhenLaterRecordExceedsFrameCap(t *testing.T) {
	firstCVE := "CVE-2099-1313"
	secondCVE := "CVE-2099-1314"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{
		{syntheticOSVPath(firstCVE), validOSV(firstCVE)},
		{syntheticOSVPath(secondCVE), strings.Replace(validOSV(secondCVE), "fictional projected advisory", strings.Repeat("z", 32<<10), 1)},
	})
	vex := archive(t, dir, "vex.tar.xz", []entry{
		{syntheticVEXPath(firstCVE), syntheticVEXTombstone(firstCVE)},
		{syntheticVEXPath(secondCVE), syntheticVEXTombstone(secondCVE)},
	})
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	var baseline bytes.Buffer
	if err := streamPrepared(prepared, &baseline, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	frames := readFrames(t, baseline.Bytes())
	if len(frames) != 3 || len(frames[1]) <= len(frames[0]) {
		t.Fatalf("unexpected synthetic frame sizes: %v", []int{len(frames[0]), len(frames[1])})
	}
	lim := defaultLimits()
	lim.frameBytes = len(frames[0])

	var out bytes.Buffer
	err := streamPrepared(prepared, &out, lim)
	if err == nil || !strings.Contains(err.Error(), "frame cap") {
		t.Fatalf("late projection frame cap error = %v", err)
	}
	frames = readFrames(t, out.Bytes())
	if len(frames) != 1 || frames[0][0] != recordFrame {
		t.Fatalf("late frame-cap failure frames = %d/types %v, want one record and no terminal", len(frames), frameTypes(frames))
	}
	assertIncompleteProjectionStream(t, out.Bytes())
}

func TestMergeFailsClosed(t *testing.T) {
	tests := []struct {
		name string
		osv  []entry
	}{
		{"traversal", []entry{{"../osv/cve/2099/UBUNTU-CVE-2099-1401.json", minimalOSV("CVE-2099-1401")}}},
		{"identity", []entry{{syntheticOSVPath("CVE-2099-1401"), minimalOSV("CVE-2099-1499")}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			osv := archive(t, dir, "osv.tar.xz", tc.osv)
			vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-1401"), minimalVEX("CVE-2099-1401")}})
			if err := merge(osv, vex, io.Discard, defaultLimits()); err == nil {
				t.Fatal("expected fail-closed error")
			}
		})
	}
}

func TestPrepareRejectsMalformedAndTruncatedArchives(t *testing.T) {
	tests := []struct {
		name  string
		build func(*testing.T, string) string
	}{
		{
			name: "truncated xz",
			build: func(t *testing.T, dir string) string {
				t.Helper()
				filename := archive(t, dir, "bad.tar.xz", []entry{{syntheticOSVPath("CVE-2099-1501"), minimalOSV("CVE-2099-1501")}})
				st, err := os.Stat(filename)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.Truncate(filename, st.Size()-8); err != nil {
					t.Fatal(err)
				}
				return filename
			},
		},
		{
			name: "truncated tar member",
			build: func(t *testing.T, dir string) string {
				t.Helper()
				return truncatedTarArchive(t, dir, "bad.tar.xz", syntheticOSVPath("CVE-2099-1501"), minimalOSV("CVE-2099-1501"))
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			osv := tc.build(t, dir)
			vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-1501"), minimalVEX("CVE-2099-1501")}})
			out := filepath.Join(dir, "prepared")
			if err := prepare(osv, vex, out, defaultLimits()); err == nil {
				t.Fatal("malformed archive accepted")
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatalf("partial prepared output remains: %v", err)
			}
		})
	}
}

func TestPrepareRejectsNonCanonicalCVEPathsAndTypes(t *testing.T) {
	tests := []struct {
		name string
		bad  tar.Header
	}{
		{"wrong year", tar.Header{Name: "osv/cve/2098/UBUNTU-CVE-2099-1601.json", Typeflag: tar.TypeReg}},
		{"wrong filename", tar.Header{Name: "osv/cve/2099/CVE-2099-1601.json", Typeflag: tar.TypeReg}},
		{"symlink", tar.Header{Name: syntheticOSVPath("CVE-2099-1601"), Typeflag: tar.TypeSymlink, Linkname: "fictional-target"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			body := minimalOSV("CVE-2099-1601")
			tc.bad.Mode = 0o644
			tc.bad.Size = int64(len(body))
			osv := archiveHeader(t, dir, "osv.tar.xz", tc.bad, body)
			vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-1601"), minimalVEX("CVE-2099-1601")}})
			if err := prepare(osv, vex, filepath.Join(dir, "prepared"), defaultLimits()); err == nil {
				t.Fatal("non-canonical CVE entry accepted")
			}
		})
	}
}

func TestPrepareEnforcesArchiveMemberFileTotalAndDictionaryCaps(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{
		{syntheticOSVPath("CVE-2099-1701"), minimalOSV("CVE-2099-1701")},
		{"synthetic-metadata/readme", "intentionally ignored test member"},
	})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-1701"), minimalVEX("CVE-2099-1701")}})
	osvStat, _ := os.Stat(osv)
	tests := []struct {
		name string
		edit func(*limits)
	}{
		{"archive", func(l *limits) { l.archiveBytes = osvStat.Size() - 1 }},
		{"members", func(l *limits) { l.members = 1 }},
		{"file", func(l *limits) { l.fileBytes = 8 }},
		{"total", func(l *limits) { l.totalBytes = 8 }},
		{"dictionary", func(l *limits) { l.dictBytes = 1 }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			lim := defaultLimits()
			tc.edit(&lim)
			if err := prepare(osv, vex, filepath.Join(dir, "prepared-"+tc.name), lim); err == nil {
				t.Fatalf("%s cap was not enforced", tc.name)
			}
		})
	}
}

func TestDefaultDecodedRunCapCoversMaximumAcceptedSpool(t *testing.T) {
	lim := defaultLimits()
	framingBytesPerRecord := int64(runHeaderBytes) + lim.pathBytes
	if framingBytesPerRecord <= 0 || lim.totalBytes < 0 || lim.members < 0 ||
		lim.members > (math.MaxInt64-lim.totalBytes)/framingBytesPerRecord {
		t.Fatal("default decoded run bound overflows int64")
	}

	want := lim.totalBytes + lim.members*framingBytesPerRecord
	if lim.decodedBytes != want {
		t.Fatalf("default decoded run cap = %d bytes, want structural maximum %d", lim.decodedBytes, want)
	}
}

func TestPrepareTokenPreflightRejectsOSVAffectedCapBeforeSpooling(t *testing.T) {
	cve := "CVE-2099-1711"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), syntheticOSVDocument(cve, []map[string]any{
		syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", nil),
		syntheticOSVAffected("nebula-engine-src", "zenith", "98.98:LTS", nil),
	})}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), syntheticVEXTombstone(cve)}})
	lim := defaultLimits()
	lim.projection.assertions = 1
	prepared := filepath.Join(dir, "prepared")

	err := prepare(osv, vex, prepared, lim)
	if err == nil || !strings.Contains(err.Error(), "assertion cap") {
		t.Fatalf("OSV structural assertion-cap error = %v", err)
	}
	if _, err := os.Stat(prepared); !os.IsNotExist(err) {
		t.Fatalf("partial prepared output remains after OSV structural rejection: %v", err)
	}
}

func TestProjectRecordTokenPreflightRejectsOSVLogicalCapBeforeMalformedOverflowElement(t *testing.T) {
	cve := "CVE-2099-1712"
	affected := syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{"7.0-test1", ""})
	lim := defaultProjectionLimits()
	lim.logicalProducts = 1

	_, err := projectRecordWithLimits(
		cve,
		[]byte(syntheticOSVDocument(cve, []map[string]any{affected})),
		nil,
		strings.Repeat("a", 64),
		"",
		newProjectionState(),
		lim,
	)
	if err == nil || !strings.Contains(err.Error(), "logical product cap") {
		t.Fatalf("OSV token-level logical-product error = %v", err)
	}
}

func TestPrepareTokenPreflightRejectsVEXStatementCapBeforeSpooling(t *testing.T) {
	cve := "CVE-2099-1713"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), minimalOSV(cve)}})
	vexDocument := map[string]any{
		"@context":  canonicalTombstoneContext,
		"@id":       "https://metadata.example.invalid/vex/" + cve,
		"author":    canonicalAuthor,
		"timestamp": "2099-01-03T04:05:06Z",
		"version":   1,
		"statements": []map[string]any{
			{"vulnerability": map[string]string{"name": cve}},
			{"vulnerability": map[string]string{"name": "CVE-2099-9999"}},
		},
	}
	vexRaw, err := json.Marshal(vexDocument)
	if err != nil {
		t.Fatal(err)
	}
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), string(vexRaw)}})
	lim := defaultLimits()
	lim.projection.assertions = 1
	prepared := filepath.Join(dir, "prepared")

	err = prepare(osv, vex, prepared, lim)
	if err == nil || !strings.Contains(err.Error(), "assertion cap") {
		t.Fatalf("VEX structural assertion-cap error = %v", err)
	}
	if _, err := os.Stat(prepared); !os.IsNotExist(err) {
		t.Fatalf("partial prepared output remains after VEX structural rejection: %v", err)
	}
}

func TestPrepareTokenPreflightRejectsVEXDescendantProductCapBeforeSpooling(t *testing.T) {
	cve := "CVE-2099-1714"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), minimalOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), validVEX(cve)}})
	lim := defaultLimits()
	lim.projection.logicalProducts = 1
	prepared := filepath.Join(dir, "prepared")

	err := prepare(osv, vex, prepared, lim)
	if err == nil || !strings.Contains(err.Error(), "logical product cap") {
		t.Fatalf("VEX structural descendant-product error = %v", err)
	}
	if _, err := os.Stat(prepared); !os.IsNotExist(err) {
		t.Fatalf("partial prepared output remains after VEX product rejection: %v", err)
	}
}

func TestMergeTokenPreflightRejectsVEXDepthBeforeTypedUnmarshal(t *testing.T) {
	cve := "CVE-2099-1715"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), minimalOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), syntheticDeepVEX(cve, 10_100)}})

	var out bytes.Buffer
	err := merge(osv, vex, &out, defaultLimits())
	if err == nil || !strings.Contains(err.Error(), "product nesting cap") {
		t.Fatalf("VEX token-level nesting error = %v", err)
	}
	if out.Len() != 0 {
		t.Fatalf("merge emitted %d bytes before rejecting excessive VEX nesting", out.Len())
	}
}

func TestTokenPreflightRejectsCaseFoldedDuplicateArrayAndTreeFields(t *testing.T) {
	cve := "CVE-2099-1716"
	osv := strings.Replace(validOSV(cve), `"affected":[`, `"affected":[],"Affected":[`, 1)
	osvVersions := strings.Replace(validOSV(cve), `"versions":[`, `"versions":[],"Versions":[`, 1)
	osvBinaries := strings.Replace(validOSV(cve), `"binaries":[`, `"binaries":[],"Binaries":[`, 1)
	vexStatements := strings.TrimSuffix(syntheticVEXTombstone(cve), "}") +
		`,"Statements":[{"vulnerability":{"name":"` + cve + `"},"products":[]}]}`
	vexProducts := strings.Replace(validVEX(cve), `"products":[`, `"products":[],"Products":[`, 1)
	vexSubcomponents := strings.Replace(validVEX(cve), `"subcomponents":[`, `"subcomponents":[],"Subcomponents":[`, 1)

	for _, tc := range []struct {
		name string
		kind string
		raw  string
	}{
		{"OSV affected", osvKind, osv},
		{"OSV versions", osvKind, osvVersions},
		{"OSV binaries", osvKind, osvBinaries},
		{"VEX statements", "vex", vexStatements},
		{"VEX products", "vex", vexProducts},
		{"VEX subcomponents", "vex", vexSubcomponents},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateIdentityWithLimits(tc.kind, cve, []byte(tc.raw), defaultProjectionLimits())
			if err == nil || !strings.Contains(err.Error(), "noncanonical JSON field") {
				t.Fatalf("case-folded field preflight error = %v", err)
			}
		})
	}
}

func TestTokenPreflightRejectsExactDuplicateFieldsAtEveryMaterializedLevel(t *testing.T) {
	cve := "CVE-2099-1721"
	osvIdentity := strings.Replace(
		validOSV(cve),
		`"id":"UBUNTU-`+cve+`"`,
		`"id":"UBUNTU-`+cve+`","id":"UBUNTU-`+cve+`"`,
		1,
	)
	vexIdentity := strings.Replace(
		validVEX(cve),
		`"@id":"https://metadata.example.invalid/vex/`+cve+`"`,
		`"@id":"https://metadata.example.invalid/vex/`+cve+`","@id":"https://metadata.example.invalid/vex/`+cve+`"`,
		1,
	)
	vulnerability := strings.Replace(
		validVEX(cve),
		`"name":"`+cve+`"`,
		`"name":"`+cve+`","name":"`+cve+`"`,
		1,
	)
	product := strings.Replace(
		validVEX(cve),
		`{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source"`,
		`{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source","@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source"`,
		1,
	)
	subcomponent := strings.Replace(
		validVEX(cve),
		`{"identifiers":{"purl":"pkg:deb/ubuntu/libasterism@8.0-test1?arch=amd64&distro=aurora"}}`,
		`{"identifiers":{"purl":"pkg:deb/ubuntu/libasterism@8.0-test1?arch=amd64&distro=aurora"},"identifiers":{"purl":"pkg:deb/ubuntu/libasterism@8.0-test1?arch=amd64&distro=aurora"}}`,
		1,
	)
	rangeEvent := strings.Replace(
		validOSV(cve),
		`{"introduced":"0"}`,
		`{"introduced":"0","introduced":"0"}`,
		1,
	)

	for _, tc := range []struct {
		name string
		kind string
		raw  string
	}{
		{"OSV identity", osvKind, osvIdentity},
		{"VEX identity", "vex", vexIdentity},
		{"VEX nested vulnerability", "vex", vulnerability},
		{"VEX product", "vex", product},
		{"VEX subcomponent", "vex", subcomponent},
		{"OSV range event", osvKind, rangeEvent},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateIdentityWithLimits(tc.kind, cve, []byte(tc.raw), defaultProjectionLimits())
			if err == nil || !strings.Contains(err.Error(), "duplicate JSON field") {
				t.Fatalf("exact duplicate field preflight error = %v", err)
			}
		})
	}
}

func TestTokenPreflightReleasesSequentialVEXProductFields(t *testing.T) {
	cve := "CVE-2099-1722"
	productsPerStatement := maxJSONStoredFields/2 + 1
	raw := syntheticVEXWithSequentialProducts(cve, productsPerStatement, 2)

	doc, err := parseVEX(cve, []byte(raw))
	if err != nil {
		t.Fatalf("sequential shallow VEX products rejected: %v", err)
	}
	if len(doc.Statements) != 2 {
		t.Fatalf("statement count = %d, want 2", len(doc.Statements))
	}
	for i := range doc.Statements {
		if got := len(doc.Statements[i].Products); got != productsPerStatement {
			t.Fatalf("statement %d product count = %d, want %d", i, got, productsPerStatement)
		}
	}
}

func TestTokenPreflightStillCapsSimultaneouslyLiveObjectFields(t *testing.T) {
	cve := "CVE-2099-1723"
	raw := fmt.Sprintf(
		`{"id":%q,"ignored":%s}`,
		"UBUNTU-"+cve,
		syntheticNestedObjectFieldPressure(17, maxJSONObjectFields),
	)

	err := validateIdentityWithLimits(osvKind, cve, []byte(raw), defaultProjectionLimits())
	if err == nil || !strings.Contains(err.Error(), "field storage cap") {
		t.Fatalf("simultaneously live JSON object fields error = %v", err)
	}
}

func TestFinishContainerClearsPoppedFieldStorage(t *testing.T) {
	decoder := json.NewDecoder(strings.NewReader(`{}`))
	preflight := &structuralPreflight{
		decoder: decoder,
		limits:  defaultProjectionLimits(),
	}
	opened, err := preflight.startContainer('{', false)
	if err != nil || !opened {
		t.Fatalf("start container = %t, %v", opened, err)
	}
	preflight.containers[0].fields = map[string]struct{}{"synthetic": {}}
	preflight.containers[0].fieldBytes = int64(len("synthetic"))
	preflight.storedFields = 1
	preflight.storedFieldBytes = int64(len("synthetic"))

	if err := preflight.finishContainer('}'); err != nil {
		t.Fatalf("finish container: %v", err)
	}
	if preflight.storedFields != 0 || preflight.storedFieldBytes != 0 {
		t.Fatalf("released accounting = (%d, %d), want (0, 0)", preflight.storedFields, preflight.storedFieldBytes)
	}
	backing := preflight.containers[:cap(preflight.containers)]
	if backing[0].fields != nil || backing[0].fieldBytes != 0 {
		t.Fatalf("popped container retains field storage: %#v", backing[0])
	}
}

func TestTokenPreflightRejectsOversizedProductComponents(t *testing.T) {
	cve := "CVE-2099-1717"
	oversized := strings.Repeat("x", maxPURLBytes+1)
	osvAffected := syntheticOSVAffected(oversized, "aurora", "99.99:LTS", nil)
	osv := syntheticOSVDocument(cve, []map[string]any{osvAffected})
	vex := vexWithProducts(cve, "fixed", `[{"identifiers":{"purl":"pkg:deb/ubuntu/`+oversized+`@8.0-test1?arch=source&distro=aurora"}}]`)

	for _, tc := range []struct {
		name string
		kind string
		raw  string
	}{
		{"OSV package", osvKind, osv},
		{"VEX PURL", "vex", vex},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateIdentityWithLimits(tc.kind, cve, []byte(tc.raw), defaultProjectionLimits())
			if err == nil || !strings.Contains(err.Error(), "component cap") {
				t.Fatalf("oversized scalar component preflight error = %v", err)
			}
		})
	}
}

func TestTokenPreflightProductComponentCapIsInclusive(t *testing.T) {
	cve := "CVE-2099-1720"
	for _, size := range []int{maxPURLBytes, maxPURLBytes + 1} {
		affected := syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{strings.Repeat("x", size)})
		err := validateIdentityWithLimits(osvKind, cve, []byte(syntheticOSVDocument(cve, []map[string]any{affected})), defaultProjectionLimits())
		if size == maxPURLBytes && err != nil {
			t.Fatalf("exact scalar component cap rejected: %v", err)
		}
		if size == maxPURLBytes+1 && (err == nil || !strings.Contains(err.Error(), "component cap")) {
			t.Fatalf("scalar component cap+1 error = %v", err)
		}
	}
}

func TestJSONTokenCapAllowsExactBoundaryAndRejectsNextToken(t *testing.T) {
	raw := []byte(`{"id":"UBUNTU-CVE-2099-1718"}`)
	limits := defaultProjectionLimits()
	limits.jsonTokens = 4
	if err := validateIdentityWithLimits(osvKind, "CVE-2099-1718", raw, limits); err != nil {
		t.Fatalf("exact JSON token boundary rejected: %v", err)
	}
	limits.jsonTokens = 3
	if err := validateIdentityWithLimits(osvKind, "CVE-2099-1718", raw, limits); err == nil || !strings.Contains(err.Error(), "token cap") {
		t.Fatalf("JSON token cap+1 error = %v", err)
	}
}

func TestGenericJSONDepthAllowsExactBoundaryAndRejectsNextContainer(t *testing.T) {
	raw := []byte(`{"id":"UBUNTU-CVE-2099-1719","ignored":[[]]}`)
	limits := defaultProjectionLimits()
	limits.jsonNesting = 3
	if err := validateIdentityWithLimits(osvKind, "CVE-2099-1719", raw, limits); err != nil {
		t.Fatalf("exact JSON nesting boundary rejected: %v", err)
	}
	limits.jsonNesting = 2
	if err := validateIdentityWithLimits(osvKind, "CVE-2099-1719", raw, limits); err == nil || !strings.Contains(err.Error(), "nesting cap") {
		t.Fatalf("JSON nesting cap+1 error = %v", err)
	}
}

func TestPrepareTotalWorkCapIncludesInputArchives(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath("CVE-2099-1801"), minimalOSV("CVE-2099-1801")}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-1801"), minimalVEX("CVE-2099-1801")}})
	lim := defaultLimits()
	lim.workBytes = 1
	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, lim); err == nil {
		t.Fatal("expected helper work cap failure")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("partial output remains: %v", err)
	}
}

func TestPrepareConsumesAndHashesTheArchiveIdentityItOpened(t *testing.T) {
	cve := "CVE-2099-1802"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), minimalOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), minimalVEX(cve)}})
	original, err := os.ReadFile(osv)
	if err != nil {
		t.Fatal(err)
	}
	replacement := append([]byte(nil), original...)
	replacement[0] ^= 0xff
	replacementPath := filepath.Join(dir, "same-size-replacement.tar.xz")
	if err := os.WriteFile(replacementPath, replacement, 0o600); err != nil {
		t.Fatal(err)
	}

	lim := defaultLimits()
	lim.afterArchiveOpen = func(kind string) error {
		if kind != osvKind {
			return nil
		}
		if err := os.Rename(osv, filepath.Join(dir, "opened-osv.tar.xz")); err != nil {
			return err
		}
		return os.Rename(replacementPath, osv)
	}
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, lim); err != nil {
		t.Fatalf("path replacement changed already-open archive input: %v", err)
	}
	manifestRaw, err := os.ReadFile(filepath.Join(prepared, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var got manifest
	if err := json.Unmarshal(manifestRaw, &got); err != nil {
		t.Fatal(err)
	}
	wantDigest := sha256.Sum256(original)
	replacementDigest := sha256.Sum256(replacement)
	if got.OSV.ArchiveSHA256 != hex.EncodeToString(wantDigest[:]) {
		t.Fatalf("manifest OSV digest = %s, want consumed opened bytes %x", got.OSV.ArchiveSHA256, wantDigest)
	}
	if got.OSV.ArchiveSHA256 == hex.EncodeToString(replacementDigest[:]) {
		t.Fatal("manifest recorded the replacement pathname bytes")
	}
}

func TestPrepareUsesContinuousExternalSortRuns(t *testing.T) {
	dir := t.TempDir()
	var osvEntries, vexEntries []entry
	for i := 24; i >= 1; i-- {
		cve := fmt.Sprintf("CVE-2099-%04d", 5000+i)
		osvEntries = append(osvEntries, entry{
			syntheticOSVPath(cve),
			withIgnoredPadding(validOSV(cve), strings.Repeat(string(rune('a'+i%20)), 180)),
		})
		vexEntries = append(vexEntries, entry{
			syntheticVEXPath(cve),
			withIgnoredPadding(validVEX(cve), strings.Repeat(string(rune('A'+i%20)), 180)),
		})
	}
	osv := archive(t, dir, "osv.tar.xz", osvEntries)
	vex := archive(t, dir, "vex.tar.xz", vexEntries)
	lim := defaultLimits()
	lim.chunkBytes = 700
	lim.fanIn = 2

	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, lim); err != nil {
		t.Fatal(err)
	}
	m := readManifestMap(t, out)
	for _, kind := range []string{osvKind, vexKind} {
		inv := m[kind].(map[string]any)
		if got := int(inv["initial_runs"].(float64)); got < 6 {
			t.Fatalf("%s initial_runs = %d, want forced multi-run external sort", kind, got)
		}
		if got := int(inv["merge_passes"].(float64)); got < 3 {
			t.Fatalf("%s merge_passes = %d, want hierarchical fan-in", kind, got)
		}
		spool := filepath.Join(out, inv["spool"].(string))
		data, err := os.ReadFile(spool)
		if err != nil {
			t.Fatal(err)
		}
		if got := bytes.Count(data, []byte{0x28, 0xb5, 0x2f, 0xfd}); got != 1 {
			t.Fatalf("%s final spool has %d zstd frames, want one continuous frame", kind, got)
		}
	}

	var streamed bytes.Buffer
	if err := streamPrepared(out, &streamed, lim); err != nil {
		t.Fatal(err)
	}
	frames := readFrames(t, streamed.Bytes())
	cves := make([]string, 0, len(frames)-1)
	for _, frame := range frames[:len(frames)-1] {
		cves = append(cves, recordCVE(t, frame))
	}
	if !sort.StringsAreSorted(cves) || len(cves) != 24 {
		t.Fatalf("streamed CVEs are not a complete sorted set: %v", cves)
	}
}

func TestPrepareIsDeterministicAcrossArchiveOrder(t *testing.T) {
	entries := []entry{
		{syntheticOSVPath("CVE-2099-3001"), minimalOSVWithDetail("CVE-2099-3001", "fictional alpha")},
		{syntheticOSVPath("CVE-2099-3002"), minimalOSVWithDetail("CVE-2099-3002", "fictional beta")},
		{syntheticOSVPath("CVE-2099-3003"), minimalOSVWithDetail("CVE-2099-3003", "fictional gamma")},
	}
	vexEntries := []entry{
		{syntheticVEXPath("CVE-2099-3003"), minimalVEX("CVE-2099-3003")},
		{syntheticVEXPath("CVE-2099-3001"), minimalVEX("CVE-2099-3001")},
	}
	dir := t.TempDir()
	osvA := archive(t, dir, "osv-a.tar.xz", entries)
	osvB := archive(t, dir, "osv-b.tar.xz", reverseEntries(entries))
	vexA := archive(t, dir, "vex-a.tar.xz", vexEntries)
	vexB := archive(t, dir, "vex-b.tar.xz", reverseEntries(vexEntries))
	lim := defaultLimits()
	lim.chunkBytes = 100
	lim.fanIn = 2
	outA, outB := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	if err := prepare(osvA, vexA, outA, lim); err != nil {
		t.Fatal(err)
	}
	if err := prepare(osvB, vexB, outB, lim); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"osv.spool", "vex.spool"} {
		a, err := os.ReadFile(filepath.Join(outA, name))
		if err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(filepath.Join(outB, name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(a, b) {
			t.Fatalf("%s differs when archive order changes", name)
		}
	}
}

func TestPrepareRejectsBudgetExceededDuringMergeAndCleansOutput(t *testing.T) {
	dir := t.TempDir()
	var osvEntries []entry
	for i := 1; i <= 8; i++ {
		cve := fmt.Sprintf("CVE-2099-%04d", 6000+i)
		osvEntries = append(osvEntries, entry{
			syntheticOSVPath(cve),
			fmt.Sprintf(`{"id":%q,"details":%q}`, "UBUNTU-"+cve, deterministicNoise(i, 8<<10)),
		})
	}
	osv := archive(t, dir, "osv.tar.xz", osvEntries)
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-6001"), minimalVEX("CVE-2099-6001")}})
	osvStat, _ := os.Stat(osv)
	vexStat, _ := os.Stat(vex)
	lim := defaultLimits()
	lim.chunkBytes = 9 << 10
	lim.fanIn = 2
	lim.workBytes = osvStat.Size() + vexStat.Size() + (100 << 10)
	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, lim); err == nil || !strings.Contains(err.Error(), "work cap") {
		t.Fatalf("prepare error = %v, want merge-time work cap failure", err)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("partial output remains: %v", err)
	}
}

func TestCanonicalEmptyVEXTombstoneRequiresTrustedMetadata(t *testing.T) {
	valid := []byte(syntheticVEXTombstone("CVE-2099-7001"))
	if err := validateIdentity("vex", "CVE-2099-7001", valid); err != nil {
		t.Fatalf("valid Canonical tombstone rejected: %v", err)
	}
	invalid := bytes.Replace(valid, []byte("2099-01-03T04:05:06Z"), []byte("not-a-time"), 1)
	if err := validateIdentity("vex", "CVE-2099-7001", invalid); err == nil {
		t.Fatal("unparseable Canonical tombstone timestamp accepted")
	}
	missing := bytes.Replace(valid, []byte(`"statements":[]`), []byte(`"other":[]`), 1)
	if err := validateIdentity("vex", "CVE-2099-7001", missing); err == nil {
		t.Fatal("missing statements key accepted as an empty tombstone")
	}
}

func TestPrepareRejectsDuplicateCVEAcrossRuns(t *testing.T) {
	dir := t.TempDir()
	cve := "CVE-2099-7101"
	osv := archive(t, dir, "osv.tar.xz", []entry{
		{syntheticOSVPath(cve), minimalOSVWithDetail(cve, "fictional duplicate alpha")},
		{syntheticOSVPath(cve), minimalOSVWithDetail(cve, "fictional duplicate beta")},
	})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), minimalVEX(cve)}})
	lim := defaultLimits()
	lim.chunkBytes = 1
	if err := prepare(osv, vex, filepath.Join(dir, "prepared"), lim); err == nil || !strings.Contains(err.Error(), "duplicate CVE") {
		t.Fatalf("prepare error = %v, want duplicate CVE failure", err)
	}
}

func TestStreamPreparedPropagatesBrokenPipe(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(syntheticPrimaryCVE), validOSV(syntheticPrimaryCVE)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(syntheticPrimaryCVE), validVEX(syntheticPrimaryCVE)}})
	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	if err := streamPrepared(out, failingWriter{}, defaultLimits()); err == nil {
		t.Fatal("broken output pipe was not propagated")
	}
}

func TestAuditPreparedUsesProjectionStreamAndEmitsOnlyTerminalJSON(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(syntheticPrimaryCVE), validOSV(syntheticPrimaryCVE)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(syntheticPrimaryCVE), validVEX(syntheticPrimaryCVE)}})
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	blockedTemp := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(blockedTemp, []byte("synthetic"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", blockedTemp)
	var summary bytes.Buffer
	if err := auditPrepared(prepared, &summary, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(summary.Bytes(), []byte("projection_digest")) || bytes.Contains(summary.Bytes(), []byte("product_sets")) {
		t.Fatalf("audit materialized record payloads: %s", summary.Bytes())
	}
	var terminal testTerminal
	if err := json.Unmarshal(bytes.TrimSpace(summary.Bytes()), &terminal); err != nil {
		t.Fatalf("audit summary is not standalone terminal JSON: %v: %q", err, summary.Bytes())
	}
	if terminal.CVECount != 1 || terminal.AssertionCount != 2 || terminal.UniqueProductCount != 6 || terminal.EmittedFrameCount != 2 || terminal.EmittedBytes <= 0 || terminal.MaxFrameBytes <= 0 {
		t.Fatalf("audit terminal counters = %#v", terminal)
	}
}

func TestProjectionFrameCapRejectsBeforeWriting(t *testing.T) {
	var out bytes.Buffer
	payload := make([]byte, maxProjectionFrameBytes+1)
	err := writeFrame(&out, payload)
	if err == nil || !strings.Contains(err.Error(), "frame cap") ||
		!strings.Contains(err.Error(), fmt.Sprintf("%d > %d", len(payload), maxProjectionFrameBytes)) {
		t.Fatalf("oversized frame error = %v", err)
	}
	if out.Len() != 0 {
		t.Fatalf("oversized frame wrote %d bytes before rejection", out.Len())
	}
}

func TestMergeRejectsOversizedFirstProjectedRecordBeforeWriting(t *testing.T) {
	cve := "CVE-2099-4200"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), validOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), validVEX(cve)}})
	lim := defaultLimits()
	lim.frameBytes = 256

	var out bytes.Buffer
	err := merge(osv, vex, &out, lim)
	if err == nil || !strings.Contains(err.Error(), "frame cap") {
		t.Fatalf("oversized first projection frame error = %v", err)
	}
	if out.Len() != 0 {
		t.Fatalf("merge wrote %d bytes before rejecting oversized first projection frame", out.Len())
	}
}

func TestMergeEnforcesPerRecordProjectionBudgetsBeforeOutput(t *testing.T) {
	tests := []struct {
		name           string
		cve            string
		osv            string
		configure      func(*limits)
		wantError      string
		wantLogical    int64
		wantAssertions int64
	}{
		{
			name: "duplicate logical products at boundary",
			cve:  "CVE-2099-4201",
			osv: syntheticOSVDocument("CVE-2099-4201", []map[string]any{
				syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{"7.0-test1", "7.0-test1"}),
			}),
			configure:      func(lim *limits) { lim.projection.logicalProducts = 2 },
			wantLogical:    2,
			wantAssertions: 1,
		},
		{
			name: "duplicate logical products exceed cap",
			cve:  "CVE-2099-4202",
			osv: syntheticOSVDocument("CVE-2099-4202", []map[string]any{
				syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{"7.0-test1", "7.0-test1"}),
			}),
			configure: func(lim *limits) { lim.projection.logicalProducts = 1 },
			wantError: "logical product cap",
		},
		{
			name: "range-only assertions at boundary",
			cve:  "CVE-2099-4203",
			osv: syntheticOSVDocument("CVE-2099-4203", []map[string]any{
				syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", nil),
				syntheticOSVAffected("nebula-engine-src", "zenith", "98.98:LTS", nil),
			}),
			configure:      func(lim *limits) { lim.projection.assertions = 2 },
			wantAssertions: 2,
		},
		{
			name: "range-only assertions exceed cap",
			cve:  "CVE-2099-4204",
			osv: syntheticOSVDocument("CVE-2099-4204", []map[string]any{
				syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", nil),
				syntheticOSVAffected("nebula-engine-src", "zenith", "98.98:LTS", nil),
			}),
			configure: func(lim *limits) { lim.projection.assertions = 1 },
			wantError: "assertion cap",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(tc.cve), tc.osv}})
			vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(tc.cve), syntheticVEXTombstone(tc.cve)}})
			lim := defaultLimits()
			tc.configure(&lim)

			var out bytes.Buffer
			err := merge(osv, vex, &out, lim)
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("merge error = %v, want %q", err, tc.wantError)
				}
				if out.Len() != 0 {
					t.Fatalf("merge wrote %d bytes before rejecting an oversized first record", out.Len())
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			frames := readFrames(t, out.Bytes())
			if len(frames) != 2 || frames[1][0] != controlFrame {
				t.Fatalf("frame types/count = %v/%d", frameTypes(frames), len(frames))
			}
			var terminal testTerminal
			if err := json.Unmarshal(frames[1][1:], &terminal); err != nil {
				t.Fatal(err)
			}
			if terminal.LogicalProductOccurrenceCount != tc.wantLogical || terminal.AssertionCount != tc.wantAssertions {
				t.Fatalf("terminal budget counters = logical %d assertions %d, want %d/%d", terminal.LogicalProductOccurrenceCount, terminal.AssertionCount, tc.wantLogical, tc.wantAssertions)
			}
		})
	}
}

func TestMergeRejectsOversizedOSVProductComponentsBeforeOutput(t *testing.T) {
	oversized := strings.Repeat("x", maxPURLBytes+1)
	tests := []struct {
		name   string
		cve    string
		mutate func(map[string]any)
	}{
		{
			name: "source package name without purl",
			cve:  "CVE-2099-4211",
			mutate: func(affected map[string]any) {
				pkg := affected["package"].(map[string]any)
				pkg["name"] = oversized
				delete(pkg, "purl")
			},
		},
		{
			name: "source version",
			cve:  "CVE-2099-4212",
			mutate: func(affected map[string]any) {
				affected["versions"] = []string{oversized}
			},
		},
		{
			name: "binary package name",
			cve:  "CVE-2099-4213",
			mutate: func(affected map[string]any) {
				ecosystem := affected["ecosystem_specific"].(map[string]any)
				ecosystem["binaries"] = []map[string]string{{"binary_name": oversized, "binary_version": "8.0-test1"}}
			},
		},
		{
			name: "binary package version",
			cve:  "CVE-2099-4214",
			mutate: func(affected map[string]any) {
				ecosystem := affected["ecosystem_specific"].(map[string]any)
				ecosystem["binaries"] = []map[string]string{{"binary_name": "libasterism", "binary_version": oversized}}
			},
		},
		{
			name: "release channel",
			cve:  "CVE-2099-4215",
			mutate: func(affected map[string]any) {
				pkg := affected["package"].(map[string]any)
				pkg["ecosystem"] = "Ubuntu:" + oversized
			},
		},
		{
			name: "range fixed version",
			cve:  "CVE-2099-4216",
			mutate: func(affected map[string]any) {
				ranges := affected["ranges"].([]map[string]any)
				events := ranges[0]["events"].([]map[string]string)
				events[1]["fixed"] = oversized
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			affected := syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{"7.0-test1"})
			tc.mutate(affected)
			dir := t.TempDir()
			osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(tc.cve), syntheticOSVDocument(tc.cve, []map[string]any{affected})}})
			vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(tc.cve), syntheticVEXTombstone(tc.cve)}})

			var out bytes.Buffer
			err := merge(osv, vex, &out, defaultLimits())
			if err == nil || !strings.Contains(err.Error(), "component cap") {
				t.Fatalf("oversized OSV component error = %v", err)
			}
			if out.Len() != 0 {
				t.Fatalf("merge wrote %d bytes before rejecting oversized first-record component", out.Len())
			}
		})
	}
}

func TestProductSetRejectsMoreThan65536UniqueProducts(t *testing.T) {
	products := make([]normalizedProduct, maxProductSetMembers+1)
	for i := range products {
		binary.BigEndian.PutUint32(products[i].IDBytes[:4], uint32(i))
		products[i].DTO.ID = fmt.Sprintf("product-%d", i)
	}
	if _, err := newProjectionBuilder(syntheticPrimaryCVE).addSet(products); err == nil || !strings.Contains(err.Error(), "member cap") {
		t.Fatalf("oversized product set error = %v", err)
	}
}

func TestProductSetStopsAtUniqueMemberCapBeforeLaterCollision(t *testing.T) {
	products := make([]normalizedProduct, maxProductSetMembers+2)
	for i := 0; i <= maxProductSetMembers; i++ {
		binary.BigEndian.PutUint32(products[i].IDBytes[:4], uint32(i))
		products[i].DTO.ID = fmt.Sprintf("product-%d", i)
	}
	products[len(products)-1].DTO.ID = products[0].DTO.ID
	products[len(products)-1].DTO.Digest = "different-synthetic-digest"

	_, err := newProjectionBuilder(syntheticPrimaryCVE).addSet(products)
	if err == nil || !strings.Contains(err.Error(), "member cap") {
		t.Fatalf("product-set early member-cap error = %v", err)
	}
}

func TestManifestAccountsForInputsFinalFilesAndPeakWork(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath("CVE-2099-7201"), minimalOSV("CVE-2099-7201")}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-7201"), minimalVEX("CVE-2099-7201")}})
	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	m := readManifestMap(t, out)
	osvInventory := m[osvKind].(map[string]any)
	vexInventory := m["vex"].(map[string]any)
	osvArchiveBytes, osvOK := osvInventory["archive_bytes"].(float64)
	vexArchiveBytes, vexOK := vexInventory["archive_bytes"].(float64)
	if !osvOK || !vexOK {
		t.Fatal("manifest does not record both acquisition input sizes")
	}
	osvStat, _ := os.Stat(osv)
	vexStat, _ := os.Stat(vex)
	if int64(osvArchiveBytes) != osvStat.Size() || int64(vexArchiveBytes) != vexStat.Size() {
		t.Fatalf("archive byte accounting = %.0f/%.0f, want %d/%d", osvArchiveBytes, vexArchiveBytes, osvStat.Size(), vexStat.Size())
	}
	manifestStat, _ := os.Stat(filepath.Join(out, "manifest.json"))
	osvSpoolStat, _ := os.Stat(filepath.Join(out, "osv.spool"))
	vexSpoolStat, _ := os.Stat(filepath.Join(out, "vex.spool"))
	wantWork := osvStat.Size() + vexStat.Size() + manifestStat.Size() + osvSpoolStat.Size() + vexSpoolStat.Size()
	if got := int64(m["work_bytes"].(float64)); got != wantWork {
		t.Fatalf("work_bytes = %d, want exact final footprint %d", got, wantWork)
	}
	if peak := int64(m["peak_work_bytes"].(float64)); peak < wantWork || peak > 1<<30 {
		t.Fatalf("peak_work_bytes = %d, want [%d, %d]", peak, wantWork, int64(1<<30))
	}
}

func TestStreamRejectsTamperedManifestBeforeAnyRecordFrame(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{
		{syntheticOSVPath("CVE-2099-7301"), minimalOSV("CVE-2099-7301")},
		{syntheticOSVPath("CVE-2099-7302"), minimalOSV("CVE-2099-7302")},
	})
	vex := archive(t, dir, "vex.tar.xz", []entry{
		{syntheticVEXPath("CVE-2099-7301"), minimalVEX("CVE-2099-7301")},
		{syntheticVEXPath("CVE-2099-7302"), minimalVEX("CVE-2099-7302")},
	})
	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(filepath.Join(out, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	mutations := []struct {
		name   string
		mutate func(*manifest)
	}{
		{"input total", func(m *manifest) { m.InputBytes++; m.WorkBytes++ }},
		{"final work total", func(m *manifest) { m.WorkBytes++ }},
		{"peak below final work", func(m *manifest) { m.PeakWorkBytes = m.WorkBytes - 1 }},
		{"negative count", func(m *manifest) { m.OSV.Count = -1 }},
		{"members below count", func(m *manifest) { m.OSV.Members = 0 }},
		{"negative total", func(m *manifest) { m.OSV.Total = -1 }},
		{"wrong spool bytes", func(m *manifest) { m.OSV.SpoolBytes++ }},
		{"late reference differs from run", func(m *manifest) { m.OSV.Refs[1].CVE = "CVE-2099-7399" }},
	}
	for _, tc := range mutations {
		t.Run(tc.name, func(t *testing.T) {
			var m manifest
			if err := json.Unmarshal(original, &m); err != nil {
				t.Fatal(err)
			}
			tc.mutate(&m)
			encoded, err := json.Marshal(m)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(out, "manifest.json"), encoded, 0o600); err != nil {
				t.Fatal(err)
			}
			var streamed bytes.Buffer
			if err := streamPrepared(out, &streamed, defaultLimits()); err == nil {
				t.Fatal("tampered manifest accepted")
			}
			if streamed.Len() != 0 {
				t.Fatalf("emitted %d bytes before rejecting tampered manifest", streamed.Len())
			}
		})
	}
}

func TestStreamScansCorruptSpoolBeforeAnyRecordFrame(t *testing.T) {
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath("CVE-2099-7401"), minimalOSV("CVE-2099-7401")}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath("CVE-2099-7401"), minimalVEX("CVE-2099-7401")}})
	out := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, out, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	spool := filepath.Join(out, "vex.spool")
	contents, err := os.ReadFile(spool)
	if err != nil {
		t.Fatal(err)
	}
	contents[len(contents)-1] ^= 0xff
	if err := os.WriteFile(spool, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	var streamed bytes.Buffer
	if err := streamPrepared(out, &streamed, defaultLimits()); err == nil {
		t.Fatal("corrupt spool accepted")
	}
	if streamed.Len() != 0 {
		t.Fatalf("emitted %d bytes before rejecting corrupt spool", streamed.Len())
	}
}

func TestScanRunRejectsUnexpectedExtraRecordAtItsHeader(t *testing.T) {
	dir := t.TempDir()
	spool := syntheticRun(t, dir, "extra-record.spool", []runRecord{
		{CVE: "CVE-2099-7511", Raw: []byte(`{"id":"UBUNTU-CVE-2099-7511"}`)},
		{CVE: "CVE-2099-7512", Raw: []byte(`{"id":"UBUNTU-CVE-2099-7512"}`)},
	})

	_, err := scanRun(spool, 1, defaultLimits())
	if err == nil || !strings.Contains(err.Error(), "record cap") {
		t.Fatalf("unexpected extra spool record error = %v", err)
	}
}

func TestScanRunRejectsAggregateDecodedBytesBeforeOverflowPayload(t *testing.T) {
	dir := t.TempDir()
	spool := syntheticRun(t, dir, "decoded-byte-cap.spool", []runRecord{
		{CVE: "CVE-2099-7521", Raw: []byte(`{}`)},
		{CVE: "CVE-2099-7522", Raw: []byte(`{}`)},
	})
	// Each record is 40 framing bytes + 13 CVE bytes + 2 payload bytes.
	t.Run("boundary", func(t *testing.T) {
		lim := defaultLimits()
		lim.decodedBytes = 110
		if _, err := scanRun(spool, 2, lim); err != nil {
			t.Fatalf("exact decoded spool byte cap rejected: %v", err)
		}
	})
	t.Run("cap plus one", func(t *testing.T) {
		lim := defaultLimits()
		lim.decodedBytes = 109
		_, err := scanRun(spool, 2, lim)
		if err == nil || !strings.Contains(err.Error(), "decoded byte cap") {
			t.Fatalf("aggregate decoded spool byte error = %v", err)
		}
	})
}

func TestStreamRejectsDecodedSpoolCapBeforeAnyRecordFrame(t *testing.T) {
	cve := "CVE-2099-7523"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), validOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), validVEX(cve)}})
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	lim := defaultLimits()
	lim.decodedBytes = 1

	var streamed bytes.Buffer
	err := streamPrepared(prepared, &streamed, lim)
	if err == nil || !strings.Contains(err.Error(), "decoded byte cap") {
		t.Fatalf("stream decoded spool byte error = %v", err)
	}
	if streamed.Len() != 0 {
		t.Fatalf("stream emitted %d bytes before decoded spool cap rejection", streamed.Len())
	}
}

func TestScanRunAllowsExactFileByteCapAndRejectsCapPlusOne(t *testing.T) {
	dir := t.TempDir()
	spool := syntheticRun(t, dir, "file-byte-cap.spool", []runRecord{{
		CVE: "CVE-2099-7524",
		Raw: []byte("12345678"),
	}})

	lim := defaultLimits()
	lim.fileBytes = 8
	if _, err := scanRun(spool, 1, lim); err != nil {
		t.Fatalf("exact per-record file byte cap rejected: %v", err)
	}
	lim.fileBytes = 7
	if _, err := scanRun(spool, 1, lim); err == nil || !strings.Contains(err.Error(), "record length") {
		t.Fatalf("per-record file byte cap+1 error = %v", err)
	}
}

func TestMergeRunGroupBoundsAggregateCursorAndDecoderResidency(t *testing.T) {
	const rawBytes = 64 << 10
	for _, tc := range []struct {
		name      string
		capOffset int64
		wantError bool
	}{
		{name: "exact aggregate cap", capOffset: 0},
		{name: "aggregate cap plus one", capOffset: -1, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			records := []runRecord{
				{CVE: "CVE-2099-7527", Raw: bytes.Repeat([]byte("a"), rawBytes)},
				{CVE: "CVE-2099-7528", Raw: bytes.Repeat([]byte("b"), rawBytes)},
			}
			sources := make([]runFile, 0, len(records))
			for i, record := range records {
				filename := syntheticRun(t, dir, fmt.Sprintf("resident-%d.spool", i), []runRecord{record})
				info, err := os.Stat(filename)
				if err != nil {
					t.Fatal(err)
				}
				sources = append(sources, runFile{path: filename, size: info.Size()})
			}

			lim := defaultLimits()
			lim.fileBytes = rawBytes
			lim.decoderBytes = 16 << 20
			const expectedWriterReserve = int64(16 << 20)
			cursorReserve := lim.fileBytes + lim.pathBytes
			lim.residentBytes = expectedWriterReserve + int64(len(records))*lim.decoderBytes + int64(len(records)+1)*cursorReserve + tc.capOffset
			budget := &workBudget{limit: 1 << 20}
			for _, source := range sources {
				if err := budget.reserve(source.size); err != nil {
					t.Fatal(err)
				}
			}
			destination := filepath.Join(dir, "merged.spool")
			_, err := mergeRunGroup(destination, sources, lim, budget)
			if tc.wantError {
				if !errors.Is(err, errResidentCap) {
					t.Fatalf("aggregate resident cap error = %v", err)
				}
				if _, statErr := os.Stat(destination); !os.IsNotExist(statErr) {
					t.Fatalf("partial merged run remains after resident cap rejection: %v", statErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("two individually max-sized records rejected at exact aggregate cap: %v", err)
			}
		})
	}
}

func TestStreamEncodedByteCapIsInclusiveWithoutProjectionTempFiles(t *testing.T) {
	cve := "CVE-2099-7525"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), validOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), validVEX(cve)}})
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, defaultLimits()); err != nil {
		t.Fatal(err)
	}

	var baseline bytes.Buffer
	if err := streamPrepared(prepared, &baseline, defaultLimits()); err != nil {
		t.Fatal(err)
	}
	blockedTemp := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(blockedTemp, []byte("synthetic"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", blockedTemp)

	lim := defaultLimits()
	lim.encodedBytes = int64(baseline.Len())
	var exact bytes.Buffer
	if err := streamPrepared(prepared, &exact, lim); err != nil {
		t.Fatalf("exact aggregate encoded byte cap rejected: %v", err)
	}
	if !bytes.Equal(exact.Bytes(), baseline.Bytes()) {
		t.Fatal("transactional stream changed at exact encoded byte boundary")
	}
	lim.encodedBytes--
	var rejected bytes.Buffer
	if err := streamPrepared(prepared, &rejected, lim); err == nil || !strings.Contains(err.Error(), "encoded output cap") {
		t.Fatalf("aggregate encoded byte cap+1 error = %v", err)
	}
	frames := readFrames(t, rejected.Bytes())
	if len(frames) != 1 || frames[0][0] != recordFrame {
		t.Fatalf("encoded-cap failure frames = %d/types %v, want one record and no terminal", len(frames), frameTypes(frames))
	}
	assertIncompleteProjectionStream(t, rejected.Bytes())
	info, err := os.Stat(blockedTemp)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("stream changed blocked TMPDIR sentinel: %v, %v", info, err)
	}
}

func TestScanRunRejectsOverflowingInjectedDecoderMemoryLimits(t *testing.T) {
	dir := t.TempDir()
	spool := syntheticRun(t, dir, "overflow-limits.spool", []runRecord{{
		CVE: "CVE-2099-7527",
		Raw: []byte(`{}`),
	}})
	lim := defaultLimits()
	lim.fileBytes = math.MaxInt64
	lim.chunkBytes = math.MaxInt64
	if _, err := scanRun(spool, 1, lim); err == nil || !strings.Contains(err.Error(), "invalid helper limits") {
		t.Fatalf("overflowing decoder-memory limits error = %v", err)
	}
}

func TestProjectedWireByteBoundIsExactAndOverflowChecked(t *testing.T) {
	lim := defaultLimits()
	lim.members = 3
	lim.frameBytes = 1_024
	got, err := projectedWireByteBound(lim)
	if err != nil {
		t.Fatal(err)
	}
	if want := int64((2*3 + 1) * (4 + 1_024)); got != want {
		t.Fatalf("projected wire bound = %d, want %d", got, want)
	}
	lim.encodedBytes = got + 1
	if err := validateLimits(lim); err != nil {
		t.Fatalf("safe encoded cap above structural wire bound rejected: %v", err)
	}

	lim = defaultLimits()
	frameBytes := int64(4 + maxProjectionFrameBytes)
	lim.members = (math.MaxInt64/frameBytes-1)/2 + 1
	if _, err := projectedWireByteBound(lim); err == nil {
		t.Fatal("overflowing projected wire bound accepted")
	}
	if err := validateLimits(lim); err == nil || !strings.Contains(err.Error(), "invalid helper limits") {
		t.Fatalf("overflowing projected wire limits error = %v", err)
	}
}

func TestProjectedManifestWireByteBoundUsesValidatedRecordCounts(t *testing.T) {
	lim := defaultLimits()
	lim.frameBytes = 1_024
	m := &manifest{
		OSV: inventory{Count: 2},
		VEX: inventory{Count: 3},
	}
	got, err := projectedManifestWireByteBound(m, lim)
	if err != nil {
		t.Fatal(err)
	}
	if want := int64((2 + 3 + 1) * (4 + 1_024)); got != want {
		t.Fatalf("manifest wire bound = %d, want %d", got, want)
	}
}

func TestPrepareRejectsOverflowingExpandedArchiveLimit(t *testing.T) {
	cve := "CVE-2099-7528"
	dir := t.TempDir()
	osv := archive(t, dir, "osv.tar.xz", []entry{{syntheticOSVPath(cve), minimalOSV(cve)}})
	vex := archive(t, dir, "vex.tar.xz", []entry{{syntheticVEXPath(cve), minimalVEX(cve)}})
	lim := defaultLimits()
	lim.totalBytes = math.MaxInt64
	lim.members = math.MaxInt64
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, lim); err == nil || !strings.Contains(err.Error(), "invalid helper limits") {
		t.Fatalf("overflowing expanded archive limits error = %v", err)
	}
	if _, err := os.Stat(prepared); !os.IsNotExist(err) {
		t.Fatalf("overflowing limits left prepared output: %v", err)
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type testProjectedRecord struct {
	ProtocolVersion  int              `json:"protocol_version"`
	CVEID            string           `json:"cve_id"`
	ProjectionDigest string           `json:"projection_digest"`
	Advisory         testAdvisory     `json:"advisory"`
	Coordinates      []testCoordinate `json:"coordinates"`
	Products         []testProduct    `json:"products"`
	ProductSets      []testProductSet `json:"product_sets"`
	Assertions       []testAssertion  `json:"assertions"`
}

type testAdvisory struct {
	SourceObjectID string `json:"source_object_id"`
	Description    string `json:"description"`
	Provenance     struct {
		OSVDocumentSHA256 string `json:"osv_document_sha256"`
		VEXDocumentSHA256 string `json:"vex_document_sha256"`
	} `json:"provenance"`
}

type testCoordinate struct {
	Value string `json:"value"`
}

type testProduct struct {
	ID        string `json:"id"`
	Digest    string `json:"digest"`
	LookupKey string `json:"lookup_key"`
	Version   string `json:"version"`
	PURL      string `json:"purl"`
}

type testProductSet struct {
	ID                 string   `json:"id"`
	Digest             string   `json:"digest"`
	ProductIDs         []string `json:"product_ids"`
	Count              int      `json:"count"`
	CanonicalSizeBytes int      `json:"canonical_size_bytes"`
}

type testAssertion struct {
	AffectedVersions     []string `json:"affected_versions"`
	StatementFingerprint string   `json:"statement_fingerprint"`
	ProductSetRef        string   `json:"product_set_ref"`
	ProductSetDigest     string   `json:"product_set_digest"`
}

type testTerminal struct {
	ProtocolVersion               int   `json:"protocol_version"`
	CVECount                      int64 `json:"cve_count"`
	OSVDocumentCount              int64 `json:"osv_document_count"`
	VEXDocumentCount              int64 `json:"vex_document_count"`
	OSVAffectedEntryCount         int64 `json:"osv_affected_entry_count"`
	VEXStatementCount             int64 `json:"vex_statement_count"`
	LogicalProductOccurrenceCount int64 `json:"logical_product_occurrence_count"`
	UniqueProductCount            int64 `json:"unique_product_count"`
	UniqueProductSetCount         int64 `json:"unique_product_set_count"`
	AssertionCount                int64 `json:"assertion_count"`
	EmittedBytes                  int64 `json:"emitted_bytes"`
	EmittedFrameCount             int64 `json:"emitted_frame_count"`
	MaxFrameBytes                 int64 `json:"max_frame_bytes"`
}

func validOSV(cve string) string {
	return fmt.Sprintf(`{
  "schema_version":"synthetic-v1",
  "id":"UBUNTU-%[1]s",
  "details":"fictional projected advisory",
  "aliases":["%[1]s"],
  "upstream":["%[1]s"],
  "severity":[{"type":"Ubuntu","score":"medium"},{"type":"CVSS_V3","score":"CVSS:3.1/AV:N"}],
  "published":"2099-01-02T03:04:05Z",
  "modified":"2099-01-03T04:05:06Z",
  "affected":[{
    "package":{"ecosystem":"Ubuntu:99.99:LTS","name":"asterism-src","purl":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source"},
    "ranges":[{"type":"ECOSYSTEM","events":[{"introduced":"0"},{"fixed":"8.0-test1"}]}],
    "versions":["7:6.0~test1","6.5+test2"],
    "ecosystem_specific":{"binaries":[{"binary_name":"asterism-cli","binary_version":"8.0-test1"},{"binary_name":"libasterism","binary_version":"8.0-test1"}]}
  }],
  "references":[{"type":"REPORT","url":"https://advisories.example.invalid/%[1]s"}],
  "ignored":"SYNTHETIC_RAW_SENTINEL"
}`, cve)
}

func syntheticBudgetOSV(cve string) string {
	return syntheticOSVDocument(cve, []map[string]any{
		syntheticOSVAffected("asterism-src", "aurora", "99.99:LTS", []string{"7.0-test1"}),
	})
}

func syntheticOSVDocument(cve string, affected []map[string]any) string {
	document := map[string]any{
		"id":        "UBUNTU-" + cve,
		"details":   "Intentionally fictional advisory used only by the Ubuntu projector tests.",
		"aliases":   []string{cve},
		"published": "2099-01-02T03:04:05Z",
		"modified":  "2099-01-03T04:05:06Z",
		"affected":  affected,
		"references": []map[string]any{
			{"type": "REPORT", "url": "https://advisories.example.invalid/" + cve},
		},
	}
	encoded, err := json.Marshal(document)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func syntheticOSVAffected(source, distro, channel string, versions []string) map[string]any {
	return map[string]any{
		"package": map[string]any{
			"ecosystem": "Ubuntu:" + channel,
			"name":      source,
			"purl":      fmt.Sprintf("pkg:deb/ubuntu/%s@8.0-test1?arch=source&distro=%s", source, distro),
		},
		"ranges": []map[string]any{{
			"type": "ECOSYSTEM",
			"events": []map[string]string{
				{"introduced": "0"},
				{"fixed": "8.0-test1"},
			},
		}},
		"versions": versions,
		"ecosystem_specific": map[string]any{
			"binaries": []map[string]string{},
		},
	}
}

func syntheticVEXTombstone(cve string) string {
	document := map[string]any{
		"@context":   canonicalTombstoneContext,
		"@id":        "https://metadata.example.invalid/vex/" + cve,
		"author":     canonicalAuthor,
		"timestamp":  "2099-01-03T04:05:06Z",
		"version":    1,
		"statements": []any{},
	}
	encoded, err := json.Marshal(document)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func syntheticOSVPath(cve string) string {
	return "osv/cve/2099/UBUNTU-" + cve + ".json"
}

func syntheticVEXPath(cve string) string {
	return "vex/cve/2099/" + cve + ".json"
}

func minimalOSV(cve string) string {
	return minimalOSVWithDetail(cve, "intentionally minimal fictional document")
}

func minimalOSVWithDetail(cve, detail string) string {
	encoded, err := json.Marshal(map[string]any{
		"id":      "UBUNTU-" + cve,
		"details": detail,
	})
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func minimalVEX(cve string) string {
	encoded, err := json.Marshal(map[string]any{
		"statements": []map[string]any{{
			"vulnerability": map[string]string{"name": cve},
		}},
	})
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func validVEX(cve string) string {
	return fmt.Sprintf(`{
  "@context":"https://openvex.dev/ns/v0.2.0",
  "@id":"https://metadata.example.invalid/vex/%[1]s",
  "author":"Canonical Ltd.",
  "timestamp":"2099-01-05T06:07:08.123456Z",
  "last_updated":"2099-01-06T07:08:09Z",
  "version":10,
  "statements":[{
    "vulnerability":{"@id":"https://identifiers.example.invalid/%[1]s","name":"%[1]s","description":"fictional VEX detail","aliases":["https://advisories.example.invalid/%[1]s"]},
    "timestamp":"2099-01-02T03:04:05Z",
    "version":3,
    "products":[{"@id":"pkg:deb/ubuntu/asterism-src@8.0-test1?distro=aurora&arch=source","subcomponents":[{"identifiers":{"purl":"pkg:deb/ubuntu/libasterism@8.0-test1?arch=amd64&distro=aurora"}}]}],
    "status":"not_affected",
    "justification":"vulnerable_code_not_present",
    "impact_statement":"fictional component omitted"
  }],
  "ignored":"SYNTHETIC_RAW_SENTINEL"
}`, cve)
}

func vexWithProducts(cve, status, products string) string {
	return fmt.Sprintf(`{
  "@context":"https://openvex.dev/ns/v0.2.0",
  "@id":"https://metadata.example.invalid/vex/%[1]s",
  "author":"Canonical Ltd.",
  "timestamp":"2099-03-04T05:06:07Z",
  "version":1,
  "statements":[{
    "vulnerability":{"name":"%[1]s"},
    "products":%[3]s,
    "status":"%[2]s"
  }]
}`, cve, status, products)
}

func syntheticDeepVEX(cve string, nesting int) string {
	const productPURL = "pkg:deb/ubuntu/asterism-src@8.0-test1?arch=source&distro=aurora"
	product := strings.Repeat(`{"@id":"`+productPURL+`","subcomponents":[`, nesting)
	product += `{"@id":"` + productPURL + `"}`
	product += strings.Repeat(`]}`, nesting)
	return fmt.Sprintf(`{
  "@context":"https://openvex.dev/ns/v0.2.0",
  "@id":"https://metadata.example.invalid/vex/%[1]s",
  "author":"Canonical Ltd.",
  "timestamp":"2099-03-04T05:06:07Z",
  "version":1,
  "statements":[{
    "vulnerability":{"name":"%[1]s"},
    "products":[%[2]s],
    "status":"fixed"
  }]
}`, cve, product)
}

func syntheticVEXWithSequentialProducts(cve string, productsPerStatement, statementCount int) string {
	var document strings.Builder
	fmt.Fprintf(&document, `{"@context":%q,"@id":%q,"author":%q,"timestamp":"2099-03-04T05:06:07Z","version":1,"statements":[`,
		canonicalTombstoneContext,
		"https://metadata.example.invalid/vex/"+cve,
		canonicalAuthor,
	)
	for statement := 0; statement < statementCount; statement++ {
		if statement > 0 {
			document.WriteByte(',')
		}
		fmt.Fprintf(&document, `{"vulnerability":{"name":%q},"products":[`, cve)
		for product := 0; product < productsPerStatement; product++ {
			if product > 0 {
				document.WriteByte(',')
			}
			fmt.Fprintf(
				&document,
				`{"@id":"pkg:deb/ubuntu/synthetic-widget-%d-%d@1.0-test1?arch=amd64&distro=aurora"}`,
				statement,
				product,
			)
		}
		document.WriteString(`],"status":"fixed"}`)
	}
	document.WriteString(`]}`)
	return document.String()
}

func syntheticNestedObjectFieldPressure(levels, fieldsPerObject int) string {
	value := `null`
	for level := 0; level < levels; level++ {
		var object strings.Builder
		object.WriteByte('{')
		for field := 0; field < fieldsPerObject-1; field++ {
			if field > 0 {
				object.WriteByte(',')
			}
			fmt.Fprintf(&object, `"field-%d":null`, field)
		}
		if fieldsPerObject > 1 {
			object.WriteByte(',')
		}
		fmt.Fprintf(&object, `"nested":%s}`, value)
		value = object.String()
	}
	return value
}

func syntheticRun(t *testing.T, dir, name string, records []runRecord) string {
	t.Helper()
	filename := filepath.Join(dir, name)
	budget := &workBudget{limit: 1 << 20}
	if _, err := writeRunAtomic(filename, budget, func(yield func(runRecord) error) error {
		for _, record := range records {
			if err := yield(record); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return filename
}

func withIgnoredPadding(document, padding string) string {
	end := strings.LastIndex(document, "}")
	if end < 0 {
		panic("test document is not an object")
	}
	return document[:end] + fmt.Sprintf(`,"padding":%q}`, padding)
}

func frameTypes(frames [][]byte) []byte {
	types := make([]byte, 0, len(frames))
	for _, frame := range frames {
		if len(frame) == 0 {
			types = append(types, 0)
		} else {
			types = append(types, frame[0])
		}
	}
	return types
}

func assertIncompleteProjectionStream(t *testing.T, encoded []byte) {
	t.Helper()
	sink := &auditFrameWriter{}
	if _, err := sink.Write(encoded); err != nil {
		t.Fatalf("invalid complete-frame prefix: %v", err)
	}
	if _, err := sink.finish(); err == nil || !strings.Contains(err.Error(), "incomplete audit stream") {
		t.Fatalf("failed projection prefix was accepted as complete: %v", err)
	}
}

func maxPayloadLen(frames [][]byte) int {
	max := 0
	for _, frame := range frames {
		if len(frame) > max {
			max = len(frame)
		}
	}
	return max
}

func isSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	for _, b := range []byte(value) {
		if (b < '0' || b > '9') && (b < 'a' || b > 'f') {
			return false
		}
	}
	return true
}

func isUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' || value[14] != '8' || !strings.ContainsRune("89ab", rune(value[19])) {
		return false
	}
	for i, b := range []byte(value) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			continue
		}
		if (b < '0' || b > '9') && (b < 'a' || b > 'f') {
			return false
		}
	}
	return true
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func readManifestMap(t *testing.T, dir string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func recordCVE(t *testing.T, frame []byte) string {
	t.Helper()
	if len(frame) < 2 || frame[0] != recordFrame {
		t.Fatalf("invalid record frame: %x", frame)
	}
	var record struct {
		CVEID string `json:"cve_id"`
	}
	if err := json.Unmarshal(frame[1:], &record); err != nil || record.CVEID == "" {
		t.Fatalf("invalid projected record frame: %v", err)
	}
	return record.CVEID
}

func reverseEntries(in []entry) []entry {
	out := append([]entry(nil), in...)
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func deterministicNoise(seed, n int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	x := uint64(seed) + 1
	for i := range b {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		b[i] = alphabet[x%uint64(len(alphabet))]
	}
	return string(b)
}

type entry struct{ name, body string }

func archive(t *testing.T, dir, name string, entries []entry) string {
	t.Helper()
	path := filepath.Join(dir, name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	xw, err := xz.NewWriter(f)
	if err != nil {
		t.Fatal(err)
	}
	tw := tar.NewWriter(xw)
	for _, e := range entries {
		if err := tw.WriteHeader(&tar.Header{Name: e.name, Mode: 0o644, Size: int64(len(e.body)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(e.body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func archiveHeader(t *testing.T, dir, name string, header tar.Header, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	xw, err := xz.NewWriter(f)
	if err != nil {
		t.Fatal(err)
	}
	tw := tar.NewWriter(xw)
	if err := tw.WriteHeader(&header); err != nil {
		t.Fatal(err)
	}
	if isRegularTarType(header.Typeflag) {
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func truncatedTarArchive(t *testing.T, dir, name, member, body string) string {
	t.Helper()
	var tarBytes bytes.Buffer
	tw := tar.NewWriter(&tarBytes)
	if err := tw.WriteHeader(&tar.Header{Name: member, Mode: 0o644, Size: int64(len(body) + 32), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	// Deliberately do not close the tar writer: the current member and archive
	// terminator remain incomplete, while the surrounding xz stream is valid.
	path := filepath.Join(dir, name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	xw, err := xz.NewWriter(f)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := xw.Write(tarBytes.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func readFrames(t *testing.T, data []byte) [][]byte {
	t.Helper()
	var frames [][]byte
	for len(data) > 0 {
		if len(data) < 4 {
			t.Fatal("short length")
		}
		n := int(binary.BigEndian.Uint32(data[:4]))
		data = data[4:]
		if n > len(data) {
			t.Fatal("short frame")
		}
		frames = append(frames, append([]byte(nil), data[:n]...))
		data = data[n:]
	}
	return frames
}
