Name:           serviceradar-event-writer
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Event Writer
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       epel-release
%{?systemd_requires}

Source: systemd/serviceradar-event-writer.service

%description
ServiceRadar Device Manager

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar/consumers
mkdir -p %{buildroot}/lib/systemd/system

install -m 755 %{_builddir}/serviceradar-event-writer %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/packaging/event-writer/systemd/serviceradar-event-writer.service %{buildroot}/lib/systemd/system/serviceradar-event-writer.service
install -m 644 %{_sourcedir}/packaging/event-writer/config/db-event-writer.json %{buildroot}/etc/serviceradar/consumers/


%files
%attr(0755, root, root) /usr/local/bin/serviceradar-event-writer
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/consumers/db-event-writer.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-event-writer.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Ensure serviceradar group exists before user creation
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user with managed home directory if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/serviceradar --create-home \
        --shell /usr/sbin/nologin --gid serviceradar serviceradar
else
    # Align existing user home directory if needed
    CURRENT_HOME=$(getent passwd serviceradar | cut -d: -f6)
    if [ "$CURRENT_HOME" != "/var/lib/serviceradar" ]; then
        usermod --home /var/lib/serviceradar serviceradar >/dev/null 2>&1 || :
    fi
fi

%post
%systemd_post serviceradar-event-writer.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-event-writer.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-event-writer.service >/dev/null 2>&1 || :
fi

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
systemctl enable serviceradar-event-writer
systemctl start serviceradar-event-writer || echo "Failed to start service, please check the logs with: journalctl -xeu serviceradar-event-writer"

echo "ServiceRadar Device Manager service installed successfully!"

%preun
# Stop and disable service if this is a complete uninstall (not an upgrade)
if [ $1 -eq 0 ]; then
    systemctl stop serviceradar-event-writer >/dev/null 2>&1 || :
    systemctl disable serviceradar-event-writer >/dev/null 2>&1 || :
fi

%postun
# Restart the service on upgrade
if [ $1 -ge 1 ]; then
    systemctl try-restart serviceradar-event-writer >/dev/null 2>&1 || :
fi