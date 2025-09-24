Name:           serviceradar-sync
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar KV sync service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
ServiceRadar KV sync service.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

install -m 755 %{_builddir}/serviceradar-sync %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-sync.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/sync.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-sync
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/sync.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-sync.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-sync.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-sync

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-sync.service
systemctl start serviceradar-sync.service

# Verify the service started successfully
if ! systemctl is-active --quiet serviceradar-sync.service; then
    echo "WARNING: Failed to start service. Check logs with: journalctl -xeu serviceradar-sync.service"
fi


%preun
%systemd_preun serviceradar-sync.service

%postun
%systemd_postun_with_restart serviceradar-sync.service
