package endpointinventory

import (
	"strings"
	"testing"
)

const testPackageNginx = "nginx"

func TestParseDpkgStatusOnlyInstalledPackages(t *testing.T) {
	input := `Package: nginx
Status: install ok installed
Architecture: amd64
Version: 1.24.0-2ubuntu7

Package: oldpkg
Status: deinstall ok config-files
Architecture: amd64
Version: 0.1

Package: curl
Status: install ok installed
Architecture: arm64
Version: 8.5.0-2
`

	packages, err := ParseDpkgStatus(strings.NewReader(input))
	if err != nil {
		t.Fatal(err)
	}

	if len(packages) != 2 {
		t.Fatalf("len(packages) = %d, want 2: %#v", len(packages), packages)
	}
	if packages[0].Name != testPackageNginx || packages[0].Manager != PackageSourceDpkg || packages[0].PURL != "pkg:deb/nginx@1.24.0-2ubuntu7" {
		t.Fatalf("unexpected first package: %#v", packages[0])
	}
	if packages[1].Name != "curl" || packages[1].Arch != "arm64" {
		t.Fatalf("unexpected second package: %#v", packages[1])
	}
}

func TestParseAPKInstalled(t *testing.T) {
	input := `P:nginx
V:1.29.0-r0
A:x86_64

P:busybox
V:1.37.0-r12
A:x86_64
`

	packages, err := ParseAPKInstalled(strings.NewReader(input))
	if err != nil {
		t.Fatal(err)
	}

	if len(packages) != 2 {
		t.Fatalf("len(packages) = %d, want 2", len(packages))
	}
	if packages[0].Name != testPackageNginx || packages[0].Manager != PackageSourceAPK || packages[0].PURL != "pkg:apk/nginx@1.29.0-r0" {
		t.Fatalf("unexpected package: %#v", packages[0])
	}
}

func TestParseRPMQuery(t *testing.T) {
	packages := ParseRPMQuery(strings.NewReader("nginx\t1.28.0-1.el9\tx86_64\n"))
	if len(packages) != 1 {
		t.Fatalf("len(packages) = %d, want 1", len(packages))
	}
	if packages[0].Name != testPackageNginx || packages[0].Manager != PackageSourceRPM || packages[0].PURL != "pkg:rpm/nginx@1.28.0-1.el9" {
		t.Fatalf("unexpected package: %#v", packages[0])
	}
}
