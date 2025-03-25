#!/bin/bash
set -e  # Exit on any error

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.12}

# Create package directory structure
PKG_ROOT="serviceradar-nats${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-nats
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar NATS JetStream service
 Message Broker and KV store for ServiceRadar monitoring system.
Config: /etc/nats-server.conf
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/nats-server.conf
something here
EOF

# Create systemd service file
# Taken from here https://github.com/nats-io/nats-server/blob/main/util/nats-server-hardened.service
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-nats.service" << EOF
[Unit]
Description=NATS Server
After=network-online.target ntp.service

# If you use a dedicated filesystem for JetStream data, then you might use something like:
# ConditionPathIsMountPoint=/srv/jetstream
# See also Service.ReadWritePaths

[Service]
Type=simple
EnvironmentFile=-/etc/default/nats-server
ExecStart=/usr/bin/nats-server -c /etc/nats-server.conf
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s SIGINT $MAINPID

User=nats
Group=nats

Restart=always
RestartSec=5
# The nats-server uses SIGUSR2 to trigger using Lame Duck Mode (LDM) shutdown
KillSignal=SIGUSR2
# You might want to adjust TimeoutStopSec too.

# Capacity Limits
# JetStream requires 2 FDs open per stream.
LimitNOFILE=800000
# Environment=GOMEMLIMIT=12GiB
# You might find it better to set GOMEMLIMIT via /etc/default/nats-server,
# so that you can change limits without needing a systemd daemon-reload.

# Hardening
CapabilityBoundingSet=
LockPersonality=true
MemoryDenyWriteExecute=true
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
PrivateUsers=true
ProcSubset=pid
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
ReadOnlyPaths=
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallFilter=@system-service ~@privileged ~@resources
UMask=0077

# Consider locking down all areas of /etc which hold machine identity keys, etc
InaccessiblePaths=/etc/ssh

# If you have systemd >= 247
ProtectProc=invisible

# If you have systemd >= 248
PrivateIPC=true

# Optional: writable directory for JetStream.
# See also: Unit.ConditionPathIsMountPoint
ReadWritePaths=/var/lib/nats

# Optional: resource control.
# Replace weights by values that make sense for your situation.
# For a list of all options see:
# https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html
#CPUAccounting=true
#CPUWeight=100 # of 10000
#IOAccounting=true
#IOWeight=100 # of 10000
#MemoryAccounting=true
#MemoryMax=1GB
#IPAccounting=true

[Install]
WantedBy=multi-user.target
# If you install this service as nats-server.service and want 'nats'
# to work as an alias, then uncomment this next line:
Alias=nats.service
EOF

# Create default config only if we're creating a fresh package
cat > "${PKG_ROOT}/etc/nats-server.conf" << EOF
jetstream {
   store_dir=nats
}
EOF

# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create nats user if it doesn't exist
if ! id -u nats >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin nats
fi

# Set permissions
chown nats:nats /etc/nats-server.conf
chmod 755 /usr/bin/nats-server

# Enable and start service
systemctl daemon-reload
systemctl enable nats-server
systemctl start nats-server

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop nats-server
systemctl disable nats-server

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
