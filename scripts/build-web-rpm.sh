#!/bin/bash

# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

# Native RPM build script for serviceradar-web
# Runs directly on Oracle Linux 9 without Docker

VERSION="${VERSION:-1.0.0}"
BUILD_ID="${BUILD_ID:-$(date +%d%H%M)$(git rev-parse --short HEAD 2>/dev/null | cut -c1-2 || echo "xx")}"
RELEASE="${RELEASE:-1}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPMBUILD_DIR="${HOME}/rpmbuild"

echo "Building serviceradar-web RPM natively"
echo "Version: $VERSION"
echo "Build ID: $BUILD_ID"
echo "Release: $RELEASE"

# Ensure required packages are installed
echo "Checking dependencies..."
if ! command -v rpmbuild &> /dev/null; then
    echo "Installing RPM build tools..."
    sudo dnf install -y rpm-build rpmdevtools
fi

if ! command -v node &> /dev/null; then
    echo "Installing Node.js 20..."
    sudo dnf module enable -y nodejs:20
    sudo dnf install -y nodejs
fi

NODE_VERSION=$(node --version)
echo "Using Node.js $NODE_VERSION"

# Set up RPM build environment
echo "Setting up RPM build environment..."
rpmdev-setuptree

# Create necessary directories
mkdir -p "${RPMBUILD_DIR}/SOURCES/systemd"
mkdir -p "${RPMBUILD_DIR}/SOURCES/config"
mkdir -p "${RPMBUILD_DIR}/SOURCES/selinux"
mkdir -p "${RPMBUILD_DIR}/BUILD/web"

# Build Next.js application
echo "Building Next.js application..."
cd "${BASE_DIR}/web"

# Clean install
echo "Installing dependencies..."
npm cache clean --force
npm install --omit=optional

# Build with version info
echo "Building Next.js with standalone output..."
NEXT_PUBLIC_VERSION="$VERSION" NEXT_PUBLIC_BUILD_ID="$BUILD_ID" npm run build

# Verify standalone output exists
if [ ! -d ".next/standalone" ]; then
    echo "ERROR: .next/standalone not found. Make sure next.config.js has output: 'standalone'"
    exit 1
fi

# Copy to RPM build directory
echo "Copying built files to RPM build directory..."
cp -r .next/standalone/* "${RPMBUILD_DIR}/BUILD/web/"
mkdir -p "${RPMBUILD_DIR}/BUILD/web/.next"
cp -r .next/static "${RPMBUILD_DIR}/BUILD/web/.next/"
cp -r .next/standalone/.next/* "${RPMBUILD_DIR}/BUILD/web/.next/" 2>/dev/null || true

# Copy public directory if it exists
if [ -d "public" ]; then
    cp -r public "${RPMBUILD_DIR}/BUILD/web/"
fi

# Create build-info.json
cat > "${RPMBUILD_DIR}/BUILD/web/public/build-info.json" << EOF
{
  "version": "$VERSION",
  "buildId": "$BUILD_ID",
  "buildTime": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Copy packaging files
echo "Copying packaging files..."
cp "${BASE_DIR}/packaging/specs/serviceradar-web.spec" "${RPMBUILD_DIR}/SPECS/"
cp "${BASE_DIR}/packaging/web/config/web.json" "${RPMBUILD_DIR}/SOURCES/config/"
cp "${BASE_DIR}/packaging/web/config/nginx.conf" "${RPMBUILD_DIR}/SOURCES/config/nginx.conf"
cp "${BASE_DIR}/packaging/web/systemd/serviceradar-web.service" "${RPMBUILD_DIR}/SOURCES/systemd/"
cp "${BASE_DIR}/packaging/selinux/"*.te "${RPMBUILD_DIR}/SOURCES/selinux/" 2>/dev/null || echo "No SELinux policies found"

# Build RPM
echo "Building RPM package..."
cd "${BASE_DIR}"
RPM_VERSION=$(echo ${VERSION} | sed 's/-/_/g')
echo "RPM-compatible version: ${RPM_VERSION}"

rpmbuild -bb \
    --noclean \
    --define "version ${RPM_VERSION}" \
    --define "release ${RELEASE}" \
    --define "_sourcedir ${RPMBUILD_DIR}/SOURCES" \
    --define "_builddir ${RPMBUILD_DIR}/BUILD" \
    --define "_rpmdir ${RPMBUILD_DIR}/RPMS" \
    --undefine=_disable_source_fetch \
    --nocheck \
    "${RPMBUILD_DIR}/SPECS/serviceradar-web.spec"

# Copy RPM to release directory
RELEASE_DIR="${BASE_DIR}/release-artifacts/rpm/${VERSION}"
mkdir -p "${RELEASE_DIR}"
find "${RPMBUILD_DIR}/RPMS" -name "*.rpm" -exec cp {} "${RELEASE_DIR}/" \;

echo ""
echo "RPM built successfully!"
echo "Location: ${RELEASE_DIR}/serviceradar-web-${RPM_VERSION}-${RELEASE}.*.rpm"
ls -lh "${RELEASE_DIR}"/serviceradar-web-*.rpm