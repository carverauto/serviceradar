#!/bin/bash
set -e

# Script directory (assumed to be in serviceradar monorepo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}/.."

# Define RPERF_DIR for Dockerfile location
RPERF_DIR="./cmd/checkers/rperf-server"
if [ ! -f "$RPERF_DIR/Dockerfile-deb" ]; then
    echo "Error: Dockerfile not found in $RPERF_DIR."
    exit 1
fi

VERSION="1.0.30"
VERSION_CLEAN=$(echo "${VERSION}" | sed 's/-/~/g')
PKG_NAME="serviceradar-rperf"
MAINTAINER="Carver Automation Corporation <support@carverauto.com>"
DESCRIPTION="ServiceRadar RPerf Network Performance Testing Tool"

# Temp directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf ${TEMP_DIR}' EXIT

# Directory structure
mkdir -p "${TEMP_DIR}/DEBIAN"
mkdir -p "${TEMP_DIR}/usr/local/bin"
mkdir -p "${TEMP_DIR}/lib/systemd/system"
mkdir -p "${TEMP_DIR}/var/log/rperf"

# Build using Docker
echo "Building serviceradar-rperf for AMD64 from crates.io..."
docker build \
    --platform linux/amd64 \
    -t rperf-builder \
    -f "$RPERF_DIR/Dockerfile-deb" \
    --target builder \
    "$RPERF_DIR"

# Remove any existing container with the same name
echo "Removing any existing temp-rperf-builder container..."
docker rm -f temp-rperf-builder 2>/dev/null || true

# Extract binary
echo "Creating new temp-rperf-builder container..."
docker create --name temp-rperf-builder rperf-builder
echo "Copying binary..."
docker cp temp-rperf-builder:/usr/local/bin/rperf "${TEMP_DIR}/usr/local/bin/serviceradar-rperf"
echo "Removing temp-rperf-builder container..."
docker rm temp-rperf-builder

# Verify binary
file "${TEMP_DIR}/usr/local/bin/serviceradar-rperf"

# DEBIAN/control file
cat > "${TEMP_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION_CLEAN}
Architecture: amd64
Maintainer: ${MAINTAINER}
Section: net
Priority: optional
Depends: systemd
Homepage: https://github.com/mfreeman451/rperf
Description: ${DESCRIPTION}
 A network performance testing tool for measuring throughput, latency, and more.
EOF

# Create systemd service file
cat > "${TEMP_DIR}/lib/systemd/system/serviceradar-rperf.service" << EOF
[Unit]
Description=ServiceRadar RPerf Server
After=network-online.target

[Service]
Type=simple
Environment="RUST_LOG=info"
ExecStart=/usr/local/bin/serviceradar-rperf --server --port 5199 --tcp-port-pool 5200-5210 --udp-port-pool 5200-5210
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s SIGINT \$MAINPID
User=serviceradar
Group=serviceradar
Restart=always
RestartSec=5
StandardOutput=append:/var/log/rperf/rperf.log
StandardError=append:/var/log/rperf/rperf.log
LimitNOFILE=800000

[Install]
WantedBy=multi-user.target
EOF

# Create postinst script
cat > "${TEMP_DIR}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create serviceradar user and group if they don't exist
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid serviceradar serviceradar
fi

# Create required directories
mkdir -p /var/log/rperf

# Set permissions
chown -R serviceradar:serviceradar /var/log/rperf
chmod 755 /usr/local/bin/serviceradar-rperf
chmod -R 750 /var/log/rperf

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-rperf
systemctl start serviceradar-rperf || echo "Failed to start service, please check /var/log/rperf/rperf.log"

echo "ServiceRadar RPerf service installed successfully!"
echo "RPerf is running on port 5199"
exit 0
EOF
chmod 755 "${TEMP_DIR}/DEBIAN/postinst"

# Create prerm script
cat > "${TEMP_DIR}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-rperf || true
systemctl disable serviceradar-rperf || true

exit 0
EOF
chmod 755 "${TEMP_DIR}/DEBIAN/prerm"

# Build package
mkdir -p release-artifacts/
DEB_FILE="release-artifacts/${PKG_NAME}_${VERSION_CLEAN}.deb"
dpkg-deb --root-owner-group --build "${TEMP_DIR}" "${DEB_FILE}"

echo "Package built: ${DEB_FILE}"