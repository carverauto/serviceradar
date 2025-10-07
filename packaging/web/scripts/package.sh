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

# package.sh for serviceradar-web component - Prepares files for Debian packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.34}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p serviceradar-web-build
cd serviceradar-web-build

# Create package directory structure (Debian paths)
mkdir -p DEBIAN
mkdir -p usr/local/share/serviceradar-web
mkdir -p lib/systemd/system
mkdir -p etc/serviceradar
mkdir -p etc/nginx/conf.d

echo "Building web application..."

# Build the Next.js standalone bundle via Bazel for reproducible output
cd "${BASE_DIR}"
BAZEL="${BASE_DIR}/tools/bazel/bazel"
NEXT_PUBLIC_VERSION="$VERSION" "${BAZEL}" build //pkg/core/api/web:files

BAZEL_BIN="$("${BAZEL}" info bazel-bin)"
WEB_BUNDLE="${BAZEL_BIN}/pkg/core/api/web/.next"
DEST_DIR="${BASE_DIR}/serviceradar-web-build/usr/local/share/serviceradar-web"

# Copy the Bazel-produced assets into the package payload
echo "Copying built web files..."
rm -rf "${DEST_DIR}"
mkdir -p "${DEST_DIR}"

# The standalone directory contains server.js and runtime dependencies
cp -R "${WEB_BUNDLE}/standalone/." "${DEST_DIR}/"
chmod -R u+w "${DEST_DIR}/.next" || true

# Preserve the full .next tree for static assets and manifests
mkdir -p "${DEST_DIR}/.next"
cp -R "${WEB_BUNDLE}/." "${DEST_DIR}/.next/"

# Copy public assets from source if they exist
if [ -d "${BASE_DIR}/web/public" ]; then
    mkdir -p "${DEST_DIR}/public"
    cp -R "${BASE_DIR}/web/public/." "${DEST_DIR}/public/"
fi

cd "${BASE_DIR}/serviceradar-web-build"

echo "Preparing ServiceRadar Web package files..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/web/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    cp "$CONTROL_SRC" DEBIAN/control
    echo "Copied control file from $CONTROL_SRC"
else
    echo "Error: control file not found at $CONTROL_SRC"
    exit 1
fi

# Copy conffiles
CONFFILES_SRC="${PACKAGING_DIR}/web/DEBIAN/conffiles"
if [ -f "$CONFFILES_SRC" ]; then
    cp "$CONFFILES_SRC" DEBIAN/conffiles
    echo "Copied conffiles from $CONFFILES_SRC"
else
    echo "Error: conffiles not found at $CONFFILES_SRC"
    exit 1
fi

# Copy systemd service file
SERVICE_SRC="${PACKAGING_DIR}/web/systemd/serviceradar-web.service"
if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" lib/systemd/system/serviceradar-web.service
    echo "Copied serviceradar-web.service from $SERVICE_SRC"
else
    echo "Error: serviceradar-web.service not found at $SERVICE_SRC"
    exit 1
fi

# Copy web configuration file (only if it doesn't exist on the target system)
WEB_CONFIG_SRC="${PACKAGING_DIR}/web/config/web.json"
if [ ! -f "/etc/serviceradar/web.json" ] && [ -f "$WEB_CONFIG_SRC" ]; then
    cp "$WEB_CONFIG_SRC" etc/serviceradar/web.json
    echo "Copied web.json from $WEB_CONFIG_SRC"
elif [ ! -f "$WEB_CONFIG_SRC" ]; then
    echo "Error: web.json not found at $WEB_CONFIG_SRC"
    exit 1
fi

# Copy Nginx configuration file (only if it doesn't exist on the target system)
NGINX_CONFIG_SRC="${PACKAGING_DIR}/web/nginx/serviceradar-web.conf"
if [ ! -f "/etc/nginx/conf.d/serviceradar-web.conf" ] && [ -f "$NGINX_CONFIG_SRC" ]; then
    cp "$NGINX_CONFIG_SRC" etc/nginx/conf.d/serviceradar-web.conf
    echo "Copied serviceradar-web.conf from $NGINX_CONFIG_SRC"
elif [ ! -f "$NGINX_CONFIG_SRC" ]; then
    echo "Error: serviceradar-web.conf not found at $NGINX_CONFIG_SRC"
    exit 1
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/web/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" DEBIAN/postinst
    chmod 755 DEBIAN/postinst
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/web/scripts/preremove.sh"
if [ -f "$PRERM_SRC" ]; then
    cp "$PRERM_SRC" DEBIAN/prerm
    chmod 755 DEBIAN/prerm
    echo "Copied prerm from $PRERM_SRC"
else
    echo "Error: preremove.sh not found at $PRERM_SRC"
    exit 1
fi

# Optional: Copy api.env if it exists
API_ENV_SRC="${PACKAGING_DIR}/web/config/api.env"
if [ -f "$API_ENV_SRC" ]; then
    cp "$API_ENV_SRC" etc/serviceradar/api.env
    echo "Copied api.env from $API_ENV_SRC"
else
    echo "Note: api.env not found at $API_ENV_SRC, skipping..."
fi

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p "${BASE_DIR}/release-artifacts"

# Build the package
dpkg-deb --root-owner-group --build . "serviceradar-web_${VERSION}.deb"

# Move the deb file to the release-artifacts directory
mv "serviceradar-web_${VERSION}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/serviceradar-web_${VERSION}.deb"
