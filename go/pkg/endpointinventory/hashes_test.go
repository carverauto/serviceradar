package endpointinventory

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const (
	testArchAMD64               = "amd64"
	testPackageOpenSSL          = "openssl"
	testOpenSSLVersion          = "3.0.0"
	testCanonicalOpenSSLDebPURL = "pkg:deb/debian/openssl@3.0.0?arch=amd64"
)

func TestCanonicalPackagePURLAddsNamespaceAndSortedArchQualifier(t *testing.T) {
	pkg := Package{
		Name:      testPackageOpenSSL,
		Version:   testOpenSSLVersion,
		Arch:      testArchAMD64,
		Manager:   PackageSourceDpkg,
		Ecosystem: "deb",
		PURL:      "pkg:deb/openssl@3.0.0?distro=bookworm",
	}

	expected := "pkg:deb/debian/openssl@3.0.0?arch=amd64&distro=bookworm"
	if actual := CanonicalPackagePURL(pkg); actual != expected {
		t.Fatalf("CanonicalPackagePURL() = %q, want %q", actual, expected)
	}
}

func TestComputePackageSetHashIgnoresOrderAndRawPURLShape(t *testing.T) {
	left := []Package{
		{
			Name:      testPackageOpenSSL,
			Version:   testOpenSSLVersion,
			Arch:      testArchAMD64,
			Manager:   PackageSourceDpkg,
			Ecosystem: "deb",
			PURL:      "pkg:deb/openssl@3.0.0",
		},
		{
			Name:      "curl",
			Version:   "8.5.0",
			Arch:      testArchAMD64,
			Manager:   PackageSourceDpkg,
			Ecosystem: "deb",
			PURL:      "pkg:deb/debian/curl@8.5.0?arch=amd64",
		},
	}
	right := []Package{
		{
			Name:      "curl",
			Version:   "8.5.0",
			Arch:      testArchAMD64,
			Manager:   PackageSourceDpkg,
			Ecosystem: "deb",
			PURL:      "pkg:deb/curl@8.5.0?arch=amd64",
		},
		{
			Name:      testPackageOpenSSL,
			Version:   testOpenSSLVersion,
			Arch:      testArchAMD64,
			Manager:   PackageSourceDpkg,
			Ecosystem: "deb",
			PURL:      testCanonicalOpenSSLDebPURL,
		},
	}

	if ComputePackageSetHash(left) != ComputePackageSetHash(right) {
		t.Fatal("package-set hash changed for equivalent package identities")
	}
}

func TestComputePackageSetHashChangesWhenIdentityChanges(t *testing.T) {
	base := []Package{{
		Name:      testPackageOpenSSL,
		Version:   testOpenSSLVersion,
		Arch:      testArchAMD64,
		Manager:   PackageSourceDpkg,
		Ecosystem: "deb",
		PURL:      testCanonicalOpenSSLDebPURL,
	}}
	changed := append([]Package(nil), base...)
	changed[0].Version = "3.0.1"
	changed[0].PURL = "pkg:deb/debian/openssl@3.0.1?arch=amd64"

	if ComputePackageSetHash(base) == ComputePackageSetHash(changed) {
		t.Fatal("package-set hash did not change after package version changed")
	}
}

func TestComputeArtifactHashExcludesScanProvenance(t *testing.T) {
	pkg := Package{
		Name:      testPackageOpenSSL,
		Version:   testOpenSSLVersion,
		Arch:      testArchAMD64,
		Manager:   PackageSourceDpkg,
		Ecosystem: "deb",
		PURL:      "pkg:deb/openssl@3.0.0",
	}
	first := BuildCycloneDX(Config{AgentID: "agent-one"}, time.Unix(10, 0).UTC(), OSInfo{ID: "debian"}, []Package{pkg})
	second := BuildCycloneDX(Config{AgentID: "agent-two"}, time.Unix(20, 0).UTC(), OSInfo{ID: "ubuntu"}, []Package{pkg})

	if first.SerialNumber == second.SerialNumber || first.Metadata.Timestamp.Equal(second.Metadata.Timestamp) {
		t.Fatal("test setup expected volatile CycloneDX provenance to differ")
	}
	if ComputeArtifactHash(first) != ComputeArtifactHash(second) {
		t.Fatal("artifact hash changed for identical component payloads with different scan provenance")
	}
}

func TestComputeArtifactHashSortsComponentProperties(t *testing.T) {
	left := CycloneDXBOM{
		BOMFormat:   CycloneDXFormat,
		SpecVersion: CycloneDXSpecVersion,
		Components: []CycloneDXComponent{{
			Type:    "library",
			Name:    testPackageOpenSSL,
			Version: testOpenSSLVersion,
			PURL:    testCanonicalOpenSSLDebPURL,
			Properties: []CycloneDXProperty{
				{Name: "serviceradar:architecture", Value: testArchAMD64},
				{Name: "serviceradar:package_manager", Value: PackageSourceDpkg},
			},
		}},
	}
	right := left
	right.Components = []CycloneDXComponent{{
		Type:    "library",
		Name:    testPackageOpenSSL,
		Version: testOpenSSLVersion,
		PURL:    testCanonicalOpenSSLDebPURL,
		Properties: []CycloneDXProperty{
			{Name: "serviceradar:package_manager", Value: PackageSourceDpkg},
			{Name: "serviceradar:architecture", Value: testArchAMD64},
		},
	}}

	if ComputeArtifactHash(left) != ComputeArtifactHash(right) {
		t.Fatal("artifact hash changed for equivalent component properties")
	}
}

// packageSetHashVectors is testdata/package_set_hash_v1.json, generated from
// core's ServiceRadar.Inventory.EndpointInventoryPackageSet. Core tests against
// the same file, so a mismatch here is a hash the server will reject.
type packageSetHashVectors struct {
	HashAlgorithm string `json:"hash_algorithm"`
	Cases         []struct {
		Name                 string    `json:"name"`
		Packages             []Package `json:"packages"`
		ExpectedPURLs        []*string `json:"expected_purls"`
		ExpectedPackageCount int       `json:"expected_package_count"`
		ExpectedHash         string    `json:"expected_hash"`
	} `json:"cases"`
}

func TestPackageSetHashMatchesCoreVectors(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "package_set_hash_v1.json"))
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}

	var vectors packageSetHashVectors
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatalf("decode vectors: %v", err)
	}
	if vectors.HashAlgorithm != HashAlgorithm || len(vectors.Cases) == 0 {
		t.Fatalf("vectors are for %q with %d cases, want %q", vectors.HashAlgorithm, len(vectors.Cases), HashAlgorithm)
	}

	for _, vector := range vectors.Cases {
		t.Run(vector.Name, func(t *testing.T) {
			if len(vector.ExpectedPURLs) != len(vector.Packages) {
				t.Fatalf("%d expected purls for %d packages", len(vector.ExpectedPURLs), len(vector.Packages))
			}
			for index, pkg := range vector.Packages {
				want := vector.ExpectedPURLs[index]
				if want == nil {
					continue // core drops the entry; covered by the count and hash
				}
				if got := CanonicalPackagePURL(pkg); got != *want {
					t.Errorf("packages[%d] CanonicalPackagePURL() = %q, want %q", index, got, *want)
				}
			}
			if got := len(packageSetIdentities(vector.Packages)); got != vector.ExpectedPackageCount {
				t.Errorf("hashed %d packages, want %d", got, vector.ExpectedPackageCount)
			}
			if got := ComputePackageSetHash(vector.Packages); got != vector.ExpectedHash {
				t.Errorf("ComputePackageSetHash() = %s, want %s", got, vector.ExpectedHash)
			}
		})
	}
}

// The producer uploads JSON, and encoding/json turns each invalid UTF-8 byte
// into U+FFFD before core sees it. The hash has to be taken over what core
// receives, which the shared vectors cannot express (they are JSON too).
func TestPackageSetHashUsesTheUploadedFormOfInvalidUTF8(t *testing.T) {
	raw := []Package{{Name: "bad\xff\xfename", Version: "1.0\xc3", Manager: PackageSourceDpkg}}

	uploaded, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var received []Package
	if err := json.Unmarshal(uploaded, &received); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if received[0].Name != "bad\uFFFD\uFFFDname" {
		t.Fatalf("encoding/json sent name %q, want one U+FFFD per invalid byte", received[0].Name)
	}

	if got, want := ComputePackageSetHash(raw), ComputePackageSetHash(received); got != want {
		t.Fatalf("hash of raw packages = %s, hash of uploaded packages = %s", got, want)
	}
}
