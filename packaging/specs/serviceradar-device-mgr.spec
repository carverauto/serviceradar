Name:           serviceradar-device-mgr
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Device Manager
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
Requires:       epel-release
%{?systemd_requires}

Source: systemd/serviceradar-device-mgr.service

%description
ServiceRadar Device Manager

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/lib/systemd/system

install -m 755 %{_builddir}/serviceradar-device-mgr %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-device-mgr.service %{buildroot}/lib/systemd/system/serviceradar-device-mgr.service
install -m 644 %{_sourcedir}/config/devices.json %{buildroot}/etc/serviceradar/


%files
%attr(0755, root, root) /usr/local/bin/serviceradar-device-mgr
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/devices.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-device-mgr.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-device-mgr.service

# Check if EPEL repository is installed, install if missing
if ! rpm -q epel-release >/dev/null 2>&1; then
    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
fi

# Enable CodeReady Builder repository for Oracle Linux
if grep -q "Oracle Linux" /etc/os-release; then
    if command -v /usr/bin/crb >/dev/null 2>&1; then
        /usr/bin/crb enable
    else
        dnf config-manager --set-enabled ol9_codeready_builder || true
    fi
fi

# Set proper permissions for configuration
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar

# Start and enable service
systemctl daemon-reload
systemctl enable serviceradar-device-mgr
systemctl start serviceradar-device-mgr || echo "Failed to start service, please check the logs with: journalctl -xeu serviceradar-device-mgr"

echo "ServiceRadar Device Manager service installed successfully!"

%preun
# Stop and disable service if this is a complete uninstall (not an upgrade)
if [ $1 -eq 0 ]; then
    systemctl stop serviceradar-device-mgr >/dev/null 2>&1 || :
    systemctl disable serviceradar-device-mgr >/dev/null 2>&1 || :
fi

%postun
# Restart the service on upgrade
if [ $1 -ge 1 ]; then
    systemctl try-restart serviceradar-device-mgr >/dev/null 2>&1 || :
fi