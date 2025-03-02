#!/bin/bash
# setup-deb-poller.sh
set -e  # Exit on any error

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.20}

# Create package directory structure
PKG_ROOT="serviceradar-poller_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."

# Build poller binary
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-poller" ./cmd/poller

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-poller
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar poller service
 Poller component for ServiceRadar monitoring system.
 Collects and forwards monitoring data from agents to cloud service.
Config: /etc/serviceradar/poller.json
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/poller.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-poller.service" << EOF
[Unit]
Description=ServiceRadar Poller Service
After=network.target

[Service]
LimitNOFILE=65535
LimitNPROC=65535
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/serviceradar-poller -config /etc/serviceradar/poller.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create default config only if we're creating a fresh package
cat > "${PKG_ROOT}/etc/serviceradar/poller.json" << EOF
{
    "agents": {
        "local-agent": {
            "address": "localhost:50051",
            "security": {
              "server_name": "changeme",
              "mode": "none"
            },
            "checks": [
                {
                    "service_type": "process",
                    "service_name": "rusk",
                    "details": "rusk"
                },
                {
                    "service_type": "port",
                    "service_name": "SSH",
                    "details": "127.0.0.1:22"
                },
                {
                    "service_type": "grpc",
                    "service_name": "dusk",
                    "details": "192.168.2.22:50052"
                },
                {
                    "service_type": "snmp",
                    "service_name": "snmp",
                    "details": "192.168.2.22:50054"
                },
                {
                    "service_type": "icmp",
                    "service_name": "ping",
		                "details": "8.8.8.8"
                },
                {
                    "service_type": "sweep",
                    "service_name": "network_sweep",
                    "details": ""
                }
            ]
        }
    },
    "cloud_address": "localhost:50052",
    "listen_addr": ":50053",
    "poll_interval": "30s",
    "poller_id": "dusk",
    "service_name": "PollerService",
    "service_type": "grpc",
      "security": {
	    "mode": "none",
	    "cert_dir": "/etc/serviceradar/certs",
	    "server_name": "changeme",
	    "role": "poller"
	  }
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
chmod 755 /usr/local/bin/serviceradar-poller

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-poller
systemctl start serviceradar-poller

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-poller
systemctl disable serviceradar-poller

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
