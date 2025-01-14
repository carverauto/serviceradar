#!/bin/bash
# setup-deb.sh

# Create package directory structure
PKG_ROOT="homemon-dusk_1.0.0"
mkdir -p ${PKG_ROOT}/DEBIAN
mkdir -p ${PKG_ROOT}/usr/local/bin
mkdir -p ${PKG_ROOT}/etc/homemon/checkers
mkdir -p ${PKG_ROOT}/lib/systemd/system

# Create control file
cat > ${PKG_ROOT}/DEBIAN/control << EOF
Package: homemon-dusk
Version: 1.0.0
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Your Name <your.email@example.com>
Description: Homemon monitoring agent with Dusk node checker
 This package provides the homemon monitoring agent and
 a Dusk node checker plugin for monitoring Dusk blockchain nodes.
EOF

# Create postinst script
cat > ${PKG_ROOT}/DEBIAN/postinst << EOF
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

# Enable and start services
systemctl daemon-reload
systemctl enable homemon-agent
systemctl enable homemon-dusk-checker
systemctl start homemon-agent
systemctl start homemon-dusk-checker

exit 0
EOF

# Make postinst executable
chmod 755 ${PKG_ROOT}/DEBIAN/postinst

# Create prerm script
cat > ${PKG_ROOT}/DEBIAN/prerm << EOF
#!/bin/bash
set -e

# Stop and disable services
systemctl stop homemon-dusk-checker
systemctl stop homemon-agent
systemctl disable homemon-dusk-checker
systemctl disable homemon-agent

exit 0
EOF

chmod 755 ${PKG_ROOT}/DEBIAN/prerm

# Create systemd service file for agent
cat > ${PKG_ROOT}/lib/systemd/system/homemon-agent.service << EOF
[Unit]
Description=Homemon Monitoring Agent
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

# Create systemd service file for dusk checker
cat > ${PKG_ROOT}/lib/systemd/system/homemon-dusk-checker.service << EOF
[Unit]
Description=Homemon Dusk Node Checker
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

# Create default config for dusk checker
cat > ${PKG_ROOT}/etc/homemon/checkers/dusk.json << EOF
{
    "name": "dusk",
    "node_address": "localhost:8080",
    "timeout": "5m",
    "listen_addr": ":50052"
}
EOF

# Create external checker config
cat > ${PKG_ROOT}/etc/homemon/checkers/external.json << EOF
{
    "name": "dusk",
    "address": "localhost:50052"
}
EOF

# Create build script for the package
cat > build-deb.sh << EOF
#!/bin/bash
set -e

# Build binaries
GOOS=linux GOARCH=amd64 go build -o ${PKG_ROOT}/usr/local/bin/homemon-agent ./cmd/agent
GOOS=linux GOARCH=amd64 go build -o ${PKG_ROOT}/usr/local/bin/dusk-checker ./cmd/checkers/dusk

# Set permissions
chmod 755 ${PKG_ROOT}/usr/local/bin/*

# Build debian package
dpkg-deb --build ${PKG_ROOT}

echo "Package built: ${PKG_ROOT}.deb"
EOF

chmod +x build-deb.sh
