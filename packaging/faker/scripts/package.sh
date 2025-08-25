#!/bin/bash

set -e

COMPONENT="faker"
BUILD_DIR="${BUILD_DIR:-/tmp/serviceradar-build}"
PACKAGE_DIR="${BUILD_DIR}/${COMPONENT}"
VERSION="${VERSION:-1.0.0}"
ARCH="${ARCH:-amd64}"

echo "Building ServiceRadar Faker package v${VERSION} for ${ARCH}..."

# Clean and create build directory
rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}/usr/local/bin"
mkdir -p "${PACKAGE_DIR}/usr/share/serviceradar/faker/config"
mkdir -p "${PACKAGE_DIR}/usr/share/serviceradar/faker/systemd"
mkdir -p "${PACKAGE_DIR}/usr/share/serviceradar/faker/scripts"
mkdir -p "${PACKAGE_DIR}/etc/serviceradar"
mkdir -p "${PACKAGE_DIR}/var/lib/serviceradar/faker"
mkdir -p "${PACKAGE_DIR}/var/log/serviceradar"

# Build the binary
echo "Building faker binary..."
cd ../../../
CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go build -ldflags="-s -w -X main.Version=${VERSION}" -o "${PACKAGE_DIR}/usr/local/bin/serviceradar-faker" ./cmd/faker

# Copy configuration files
cp packaging/faker/config/faker.json "${PACKAGE_DIR}/usr/share/serviceradar/faker/config/"

# Copy systemd service file
cp packaging/faker/systemd/serviceradar-faker.service "${PACKAGE_DIR}/usr/share/serviceradar/faker/systemd/"

# Copy scripts
cp packaging/faker/scripts/postinstall.sh "${PACKAGE_DIR}/usr/share/serviceradar/faker/scripts/"
cp packaging/faker/scripts/preremove.sh "${PACKAGE_DIR}/usr/share/serviceradar/faker/scripts/"
chmod +x "${PACKAGE_DIR}/usr/share/serviceradar/faker/scripts/"*.sh

# Set permissions
chmod 755 "${PACKAGE_DIR}/usr/local/bin/serviceradar-faker"

# Create package based on type
PACKAGE_TYPE="${PACKAGE_TYPE:-rpm}"

if [ "${PACKAGE_TYPE}" = "rpm" ]; then
    echo "Creating RPM package..."
    rpmbuild -bb \
        --define "_topdir ${BUILD_DIR}/rpmbuild" \
        --define "_builddir ${BUILD_DIR}/rpmbuild/BUILD" \
        --define "_rpmdir ${BUILD_DIR}/rpmbuild/RPMS" \
        --define "_sourcedir ${BUILD_DIR}/rpmbuild/SOURCES" \
        --define "_specdir ${BUILD_DIR}/rpmbuild/SPECS" \
        --define "_srcrpmdir ${BUILD_DIR}/rpmbuild/SRPMS" \
        --define "version ${VERSION}" \
        --define "buildroot ${PACKAGE_DIR}" \
        packaging/specs/serviceradar-faker.spec
    
    echo "RPM package created at: ${BUILD_DIR}/rpmbuild/RPMS/${ARCH}/serviceradar-faker-${VERSION}-1.${ARCH}.rpm"

elif [ "${PACKAGE_TYPE}" = "deb" ]; then
    echo "Creating DEB package..."
    
    # Create DEBIAN directory
    mkdir -p "${PACKAGE_DIR}/DEBIAN"
    
    # Create control file
    cat > "${PACKAGE_DIR}/DEBIAN/control" <<EOF
Package: serviceradar-faker
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: ServiceRadar Team <support@serviceradar.io>
Description: ServiceRadar Fake Armis API Service
 Simulates Armis API for testing ServiceRadar integrations.
 Includes IP address change simulation to test duplicate device handling.
EOF
    
    # Create postinst script
    cp "${PACKAGE_DIR}/usr/share/serviceradar/faker/scripts/postinstall.sh" "${PACKAGE_DIR}/DEBIAN/postinst"
    chmod 755 "${PACKAGE_DIR}/DEBIAN/postinst"
    
    # Create prerm script
    cp "${PACKAGE_DIR}/usr/share/serviceradar/faker/scripts/preremove.sh" "${PACKAGE_DIR}/DEBIAN/prerm"
    chmod 755 "${PACKAGE_DIR}/DEBIAN/prerm"
    
    # Build DEB package
    dpkg-deb --build "${PACKAGE_DIR}" "serviceradar-faker_${VERSION}_${ARCH}.deb"
    
    echo "DEB package created: serviceradar-faker_${VERSION}_${ARCH}.deb"
fi

echo "Package build complete!"