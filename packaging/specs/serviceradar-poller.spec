Name:           serviceradar-poller
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar poller service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
Poller component for ServiceRadar monitoring system.
Collects and forwards monitoring data from agents to core service.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/lib/systemd/system

install -m 755 %{_builddir}/serviceradar-poller %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/packaging/poller/systemd/serviceradar-poller.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/packaging/poller/config/poller.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-poller
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/poller.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-poller.service
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
%systemd_post serviceradar-poller.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-poller.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-poller.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
install -d -m 0750 -o serviceradar -g serviceradar /var/lib/serviceradar
chmod 755 /usr/local/bin/serviceradar-poller

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-poller.service
systemctl start serviceradar-poller.service

%preun
%systemd_preun serviceradar-poller.service

%postun
%systemd_postun_with_restart serviceradar-poller.service
