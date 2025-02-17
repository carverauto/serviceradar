#!/bin/bash
# setup-deb-snmp-checker.sh
set -e  # Exit on any error

VERSION=${VERSION:-1.0.17}
echo "Building serviceradar-snmp-checker version ${VERSION}"

echo "Setting up package structure..."

# Create package directory structure
PKG_ROOT="serviceradar-snmp-checker_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binaries..."

# Build snmp checker binary
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-snmp-checker" ./cmd/checkers/snmp

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-snmp-checker
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar SNMP poller
 This package provides the serviceradar SNMP checker plugin for monitoring services.
EOF

cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/checkers/snmp.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-snmp-checker.service" << EOF
[Unit]
Description=ServiceRadar SNMP Checker Service
After=network.target

[Service]
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/serviceradar-snmp-checker
Restart=always
RestartSec=10
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF


cat > "${PKG_ROOT}/etc/serviceradar/checkers/snmp.json" << EOF
{
  "node_address": "localhost:50051",
  "listen_addr": ":50054",
  "timeout": "5m",
  "targets": [
    {
      "name": "test-router",
      "host": "192.168.1.1",
      "port": 161,
      "community": "public",
      "version": "v2c",
      "interval": "30s",
      "retries": 2,
      "oids": [
        {
          "oid": ".1.3.6.1.2.1.2.2.1.10.4",
          "name": "ifInOctets_4",
          "type": "counter",
          "scale": 1.0
        }
      ]
    }
  ]
}
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
chmod 755 /usr/local/bin/serviceradar-snmp-checker

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-snmp-checker
systemctl start serviceradar-snmp-checker

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-snmp-checker
systemctl disable serviceradar-snmp-checker

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p ./release-artifacts

# Build the package
dpkg-deb --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "./release-artifacts/"

echo "Package built: release-artifacts/${PKG_ROOT}.deb"
