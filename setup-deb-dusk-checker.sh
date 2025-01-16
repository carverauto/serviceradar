#!/bin/bash
# setup-deb-dusk-checker.sh
set -e  # Exit on any error

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.0}

# Create package directory structure
PKG_ROOT="homemon-dusk-checker_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/homemon/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."

# Build dusk checker binary
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/dusk-checker" ./cmd/checkers/dusk

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: homemon-dusk
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: HomeMon Dusk node checker
 Provides monitoring capabilities for Dusk blockchain nodes.
Config: /etc/homemon/checkers/dusk.json
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/homemon/checkers/external.json
/etc/homemon/checkers/dusk.json
EOF

# Create systemd service file for dusk checker
cat > "${PKG_ROOT}/lib/systemd/system/homemon-dusk-checker.service" << EOF
[Unit]
Description=HomeMon Dusk Node Checker
After=network.target

[Service]
Type=simple
User=homemon
ExecStart=/usr/local/bin/dusk-checker -config /etc/homemon/checkers/dusk.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create default config files
cat > "${PKG_ROOT}/etc/homemon/checkers/dusk.json" << EOF
{
    "name": "dusk",
    "node_address": "localhost:8080",
    "timeout": "5m",
    "listen_addr": ":50052"
}
EOF

# Create external.json
cat > "${PKG_ROOT}/etc/homemon/checkers/external.json" << EOF
{
    "name": "dusk",
    "address": "localhost:50052"
}
EOF

# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create homemon user if it doesn't exist
if ! id -u homemon >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin homemon
fi

# Set permissions
chown -R homemon:homemon /etc/homemon
chmod 755 /usr/local/bin/dusk-checker

# Enable and start service
systemctl daemon-reload
systemctl enable homemon-dusk-checker
systemctl start homemon-dusk-checker

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop homemon-dusk-checker
systemctl disable homemon-dusk-checker

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