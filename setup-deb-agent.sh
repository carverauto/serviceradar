#!/bin/bash
# setup-deb-agent.sh
set -e  # Exit on any error

echo "Setting up package structure..."

# Create package directory structure
PKG_ROOT="homemon-agent_1.0.0"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/homemon/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binaries..."

# Build agent and checker binaries
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/homemon-agent" ./cmd/agent
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/dusk-checker" ./cmd/checkers/dusk

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: homemon-agent
Version: 1.0.0
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Your Name <your.email@example.com>
Description: HomeMon monitoring agent with Dusk node checker
 This package provides the homemon monitoring agent and
 a Dusk node checker plugin for monitoring services.
EOF

# Create conffiles
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/homemon/checkers/dusk.json
/etc/homemon/checkers/external.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/homemon-agent.service" << EOF
[Unit]
Description=HomeMon Agent Service
After=network.target

[Service]
Type=simple
User=homemon
ExecStart=/usr/local/bin/homemon-agent
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
chmod 755 /usr/local/bin/homemon-agent
chmod 755 /usr/local/bin/dusk-checker

# Enable and start service
systemctl daemon-reload
systemctl enable homemon-agent
systemctl start homemon-agent

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop homemon-agent
systemctl disable homemon-agent

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Build the package
dpkg-deb --build "${PKG_ROOT}"

echo "Package built: ${PKG_ROOT}.deb"