#!/bin/bash
# setup-deb-agent.sh
set -e  # Exit on any error

# Get version from environment or default to 1.0.1
VERSION=${VERSION:-1.0.1}
echo "Building serviceradar-agent version ${VERSION}"

echo "Setting up package structure..."

# Create package directory structure
PKG_ROOT="serviceradar-agent_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binaries..."

# Build agent and checker binaries
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-agent" ./cmd/agent

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-agent
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar monitoring agent with Dusk node checker
 This package provides the serviceradar monitoring agent and
 a Dusk node checker plugin for monitoring services.
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-agent.service" << EOF
[Unit]
Description=ServiceRadar Agent Service
After=network.target

[Service]
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/serviceradar-agent
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF


# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-agent

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-agent
systemctl start serviceradar-agent

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-agent
systemctl disable serviceradar-agent

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p release-artifacts

# Build the package
dpkg-deb --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "release-artifacts/"

echo "Package built: release-artifacts/${PKG_ROOT}.deb"
