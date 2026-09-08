package endpointinventory

import (
	"strings"
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

func TestPackageSetHashUsesVersionPrefix(t *testing.T) {
	hash := ComputePackageSetHash([]Package{{
		Name:    testPackageOpenSSL,
		Manager: PackageSourceDpkg,
	}})

	if strings.TrimSpace(hash) == "" || len(hash) != 64 {
		t.Fatalf("ComputePackageSetHash() = %q, want sha256 hex", hash)
	}
}
