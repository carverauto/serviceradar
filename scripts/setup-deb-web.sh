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

# setup-deb-web.sh
set -e  # Exit on any error

echo "Setting up package structure for Next.js web interface..."

VERSION=${VERSION:-1.0.28}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create package directory structure
PKG_ROOT="serviceradar-web_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/share/serviceradar-web"
mkdir -p "${PKG_ROOT}/lib/systemd/system"
mkdir -p "${PKG_ROOT}/etc/serviceradar"
mkdir -p "${PKG_ROOT}/etc/nginx/conf.d"

echo "Building Next.js application..."

# Build Next.js application
cd "${BASE_DIR}/web"

# Ensure package.json contains the right scripts and dependencies
if ! grep -q '"next": ' package.json; then
  echo "ERROR: This doesn't appear to be a Next.js app. Check your web directory."
  exit 1
fi

# Install dependencies with npm
npm install

# Build the Next.js application
echo "Building Next.js application with standalone output..."
npm run build

# Copy the Next.js standalone build
echo "Copying Next.js standalone build to package..."
cp -r .next/standalone/* "../${PKG_ROOT}/usr/local/share/serviceradar-web/"
cp -r .next/standalone/.next "../${PKG_ROOT}/usr/local/share/serviceradar-web/"

# Make sure static files are copied
mkdir -p "../${PKG_ROOT}/usr/local/share/serviceradar-web/.next/static"
cp -r .next/static "../${PKG_ROOT}/usr/local/share/serviceradar-web/.next/"

# Copy public files if they exist
if [ -d "public" ]; then
  cp -r public "../${PKG_ROOT}/usr/local/share/serviceradar-web/"
fi

cd ..

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-web
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd, nodejs (>= 16.0.0), nginx
Recommends: serviceradar-core
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar web interface
 Next.js web interface for the ServiceRadar monitoring system.
 Includes Nginx configuration for integrated API and UI access.
Config: /etc/serviceradar/web.json
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/web.json
/etc/nginx/conf.d/serviceradar-web.conf
/etc/serviceradar/api.env
EOF

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/web/systemd/serviceradar-web.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" "${PKG_ROOT}/lib/systemd/system/serviceradar-web.service"
    echo "Copied serviceradar-web.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-web.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy web.json from the filesystem
WEB_JSON_SRC="${PACKAGING_DIR}/config/web.json"
if [ -f "$WEB_JSON_SRC" ]; then
    cp "$WEB_JSON_SRC" "${PKG_ROOT}/etc/serviceradar/web.json"
    echo "Copied web.json from $WEB_JSON_SRC"
else
    echo "Error: web.json not found at $WEB_JSON_SRC"
    exit 1
fi

# Copy Nginx configuration from the filesystem
NGINX_CONF_SRC="${PACKAGING_DIR}/core/config/nginx.conf"
if [ -f "$NGINX_CONF_SRC" ]; then
    cp "$NGINX_CONF_SRC" "${PKG_ROOT}/etc/nginx/conf.d/serviceradar-web.conf"
    echo "Copied serviceradar-web.conf from $NGINX_CONF_SRC"
else
    echo "Error: nginx.conf not found at $NGINX_CONF_SRC"
    exit 1
fi

# Copy api.env from the filesystem
API_ENV_SRC="${PACKAGING_DIR}/core/config/api.env"
if [ -f "$API_ENV_SRC" ]; then
    cp "$API_ENV_SRC" "${PKG_ROOT}/etc/serviceradar/api.env"
    echo "Copied api.env from $API_ENV_SRC"
else
    echo "Error: api.env not found at $API_ENV_SRC"
    exit 1
fi

# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Check for Nginx
if ! command -v nginx >/dev/null 2>&1; then
    echo "ERROR: Nginx is required but not installed. Please install nginx and try again."
    exit 1
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Install Node.js if not already installed
if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
fi

# Set permissions
chown -R serviceradar:serviceradar /usr/local/share/serviceradar-web
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/share/serviceradar-web
chmod 644 /etc/serviceradar/web.json
chmod 600 /etc/serviceradar/api.env  # Ensure api.env has restrictive permissions

# Configure Nginx
if [ -f /etc/nginx/sites-enabled/default ]; then
    echo "Disabling default Nginx site..."
    rm -f /etc/nginx/sites-enabled/default
fi

# Create symbolic link if Nginx uses sites-enabled pattern
if [ -d /etc/nginx/sites-enabled ]; then
    ln -sf /etc/nginx/conf.d/serviceradar-web.conf /etc/nginx/sites-enabled/
fi

# Test and reload Nginx
echo "Testing Nginx configuration..."
nginx -t || { echo "Warning: Nginx configuration test failed. Please check your configuration."; }
systemctl reload nginx || systemctl restart nginx || echo "Warning: Failed to reload/restart Nginx."

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-web
systemctl start serviceradar-web || echo "Failed to start service, please check the logs"

echo "ServiceRadar Web Interface installed successfully!"
echo "Web UI is running on port 3000"
echo "Nginx configured as reverse proxy - you can access the UI at http://localhost/"

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-web || true
systemctl disable serviceradar-web || true

# Remove Nginx symlink if exists
if [ -f /etc/nginx/sites-enabled/serviceradar-web.conf ]; then
    rm -f /etc/nginx/sites-enabled/serviceradar-web.conf
fi

# Reload Nginx if running
if systemctl is-active --quiet nginx; then
    systemctl reload nginx || true
fi

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p ./release-artifacts

# Build the package with root-owner-group to avoid ownership warnings
dpkg-deb --root-owner-group --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "./release-artifacts/"

echo "Package built: release-artifacts/${PKG_ROOT}.deb"