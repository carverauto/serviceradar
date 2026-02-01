Name:           serviceradar-netflow-collector
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar NetFlow/IPFIX collector
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       serviceradar-netflow-collector
Requires:       serviceradar-cli
%{?systemd_requires}

%description
This package provides the ServiceRadar NetFlow/IPFIX collector, which receives
flow telemetry and publishes it to NATS JetStream for processing.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

# Install the binary
install -m 755 %{_builddir}/serviceradar-netflow-collector %{buildroot}/usr/local/bin/

# Install systemd service and config files from packaging directory
install -m 644 %{_sourcedir}/packaging/netflow-collector/systemd/serviceradar-netflow-collector.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/packaging/netflow-collector/config/netflow-collector.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-netflow-collector
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/netflow-collector.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-netflow-collector.service
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
%systemd_post serviceradar-netflow-collector.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-netflow-collector.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-netflow-collector.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-netflow-collector

%preun
%systemd_preun serviceradar-netflow-collector.service

%postun
%systemd_postun_with_restart serviceradar-netflow-collector.service
