#!/bin/bash
# setup-rpm-cloud.sh
set -e  # Exit on any error

echo "Setting up RPM package structure..."

VERSION=${VERSION:-1.0.16}
RELEASE=${RELEASE:-1}

# Create RPM build directory structure
RPM_ROOT=$(rpm --eval '%{_topdir}')
[ -d "$RPM_ROOT" ] || RPM_ROOT="$HOME/rpmbuild"

mkdir -p ${RPM_ROOT}/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
mkdir -p ${RPM_ROOT}/BUILD/serviceradar-cloud-${VERSION}

# Copy source files to build directory
BUILD_ROOT="${RPM_ROOT}/BUILD/serviceradar-cloud-${VERSION}"
mkdir -p "${BUILD_ROOT}/usr/local/bin"
mkdir -p "${BUILD_ROOT}/etc/serviceradar"
mkdir -p "${BUILD_ROOT}/lib/systemd/system"
mkdir -p "${BUILD_ROOT}/var/lib/serviceradar"

echo "Building web interface..."
# Use the container's build script
/usr/local/bin/container-build-web.sh

# Create a directory for the embedded content
mkdir -p pkg/cloud/api/web
cp -r web/dist pkg/cloud/api/web/

echo "Building Go binary..."

# Build Go binary with embedded web content
cd cmd/cloud
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o "../../${BUILD_ROOT}/usr/local/bin/serviceradar-cloud"
cd ../..

echo "Creating RPM spec file..."

# Create RPM spec file
cat > ${RPM_ROOT}/SPECS/serviceradar-cloud.spec << EOF
Name:           serviceradar-cloud
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        ServiceRadar cloud service with web interface
License:        Proprietary
URL:            https://github.com/yourusername/serviceradar

BuildRequires:  systemd
Requires:       systemd
%{?systemd_requires}

%description
Provides centralized monitoring and web dashboard for ServiceRadar.

%install
cp -r %{_builddir}/%{name}-%{version}/* %{buildroot}/

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-cloud.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-cloud
mkdir -p /var/lib/serviceradar
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /var/lib/serviceradar

%preun
%systemd_preun serviceradar-cloud.service

%postun
%systemd_postun_with_restart serviceradar-cloud.service

%files
%dir %attr(0755, root, root) /etc/serviceradar
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/cloud.json
%attr(0755, root, root) /usr/local/bin/serviceradar-cloud
%attr(0644, root, root) /lib/systemd/system/serviceradar-cloud.service
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

EOF

# Create systemd service file
cat > "${BUILD_ROOT}/lib/systemd/system/serviceradar-cloud.service" << EOF
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

# Create default config file
cat > "${BUILD_ROOT}/etc/serviceradar/cloud.json" << EOF
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

echo "Building RPM package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p release-artifacts

# Build the RPM package
rpmbuild -bb ${RPM_ROOT}/SPECS/serviceradar-cloud.spec

# Copy the built RPM to release-artifacts
find ${RPM_ROOT}/RPMS -name "serviceradar-cloud-${VERSION}*.rpm" -exec cp {} release-artifacts/ \;

echo "Package built: Check release-artifacts/ directory for the RPM"