#!/bin/bash
# setup-deb-cloud.sh
set -e  # Exit on any error

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.19}
BUILD_TAGS=${BUILD_TAGS:-""}

# Create package directory structure
PKG_ROOT="serviceradar-cloud_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar"
mkdir -p "${PKG_ROOT}/lib/systemd/system"
mkdir -p "${PKG_ROOT}/usr/local/share/serviceradar-cloud/web"

echo "Building web interface..."

# Build web interface if not already built
if [ ! -d "web/dist" ]; then
    cd ./web
    npm install
    npm run build
    cd ..
fi

# Create a directory for the embedded content
mkdir -p pkg/cloud/api/web
cp -r web/dist pkg/cloud/api/web/

# Only copy web assets to package directory for container builds
# For non-container builds, they're embedded in the binary
if [[ "$BUILD_TAGS" == *"containers"* ]]; then
    cp -r web/dist "${PKG_ROOT}/usr/local/share/serviceradar-cloud/web/"
    echo "Copied web assets for container build"
fi

echo "Building Go binary..."

# Build Go binary with or without container tags
BUILD_CMD="CGO_ENABLED=1 GOOS=linux GOARCH=amd64"
if [[ ! -z "$BUILD_TAGS" ]]; then
    BUILD_CMD="$BUILD_CMD GOFLAGS=\"-tags=$BUILD_TAGS\""
fi
BUILD_CMD="$BUILD_CMD go build -o \"../../${PKG_ROOT}/usr/local/bin/serviceradar-cloud\""

# Build Go binary
cd cmd/cloud
eval $BUILD_CMD
cd ../..

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-cloud
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar cloud service with web interface
 Provides centralized monitoring and web dashboard for ServiceRadar.
Config: /etc/serviceradar/cloud.json
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/cloud.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-cloud.service" << EOF
[Unit]
Description=ServiceRadar Cloud Service
After=network.target

[Service]
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/serviceradar-cloud -config /etc/serviceradar/cloud.json
Restart=always
RestartSec=10
TimeoutStopSec=20
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

# Create default config only if we're creating a fresh package
if [ ! -f "/etc/serviceradar/cloud.json" ]; then
    # Create default config file
    cat > "${PKG_ROOT}/etc/serviceradar/cloud.json" << EOF
{
    "listen_addr": ":8090",
    "grpc_addr": ":50052",
    "alert_threshold": "5m",
    "known_pollers": ["home-poller-1"],
    "metrics": {
        "enabled": true,
        "retention": 100,
        "max_nodes": 10000
    },
    "security": {
        "mode": "none",
        "cert_dir": "/etc/serviceradar/certs",
        "role": "cloud"
    },
    "webhooks": [
        {
            "enabled": false,
            "url": "https://your-webhook-url",
            "cooldown": "15m",
            "headers": [
                {
                    "key": "Authorization",
                    "value": "Bearer your-token"
                }
            ]
        },
        {
            "enabled": true,
            "url": "https://discord.com/api/webhooks/changeme",
            "cooldown": "15m",
            "template": "{\"embeds\":[{\"title\":\"{{.alert.Title}}\",\"description\":\"{{.alert.Message}}\",\"color\":{{if eq .alert.Level \"error\"}}15158332{{else if eq .alert.Level \"warning\"}}16776960{{else}}3447003{{end}},\"timestamp\":\"{{.alert.Timestamp}}\",\"fields\":[{\"name\":\"Node ID\",\"value\":\"{{.alert.NodeID}}\",\"inline\":true}{{range $key, $value := .alert.Details}},{\"name\":\"{{$key}}\",\"value\":\"{{$value}}\",\"inline\":true}{{end}}]}]}"
        }
    ]
}
EOF
fi

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
chmod 755 /usr/local/bin/serviceradar-cloud

# Create data directory
mkdir -p /var/lib/serviceradar
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /var/lib/serviceradar

# Set permissions for web assets
if [ -d "/usr/local/share/serviceradar-cloud/web" ]; then
    chown -R serviceradar:serviceradar /usr/local/share/serviceradar-cloud
    chmod -R 755 /usr/local/share/serviceradar-cloud
fi

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-cloud
systemctl start serviceradar-cloud || echo "Failed to start service, please check the logs"

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-cloud || true
systemctl disable serviceradar-cloud || true

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

if [[ ! -z "$BUILD_TAGS" ]]; then
    # For tagged builds, add the tag to the filename
    PACKAGE_NAME="serviceradar-cloud_${VERSION}-${BUILD_TAGS//,/_}.deb"
    mv "./release-artifacts/${PKG_ROOT}.deb" "./release-artifacts/$PACKAGE_NAME"
    echo "Package built: release-artifacts/$PACKAGE_NAME"
else
    echo "Package built: release-artifacts/${PKG_ROOT}.deb"
fi