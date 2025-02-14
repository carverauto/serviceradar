#!/bin/bash
# setup-rpm-dusk-checker.sh
set -e  # Exit on any error

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.16}
RELEASE=${RELEASE:-1}

# Set up RPM build environment
RPM_ROOT=$(rpm --eval '%{_topdir}')
[ -d "$RPM_ROOT" ] || RPM_ROOT="$HOME/rpmbuild"

mkdir -p ${RPM_ROOT}/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
mkdir -p ${RPM_ROOT}/SOURCES/{systemd,config}

echo "Building Go binary..."

# Build dusk checker binary
GOOS=linux GOARCH=amd64 go build -o "${RPM_ROOT}/BUILD/dusk-checker" ./cmd/checkers/dusk

# Copy configuration files
cp packaging/dusk/systemd/serviceradar-dusk-checker.service ${RPM_ROOT}/SOURCES/systemd/
cp packaging/config/checkers/dusk.json ${RPM_ROOT}/SOURCES/config/

# Copy spec file
cp packaging/specs/serviceradar-dusk-checker.spec ${RPM_ROOT}/SPECS/

echo "Building RPM package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p release-artifacts/${VERSION}/rpm

# Build the package
rpmbuild -bb \
    --define "version ${VERSION}" \
    --define "release ${RELEASE}" \
    ${RPM_ROOT}/SPECS/serviceradar-dusk-checker.spec

# Copy the built RPM to release-artifacts
find ${RPM_ROOT}/RPMS -name "serviceradar-dusk-checker-${VERSION}*.rpm" -exec cp {} release-artifacts/${VERSION}/rpm/ \;

echo "Package built: check release-artifacts/${VERSION}/rpm/ directory"