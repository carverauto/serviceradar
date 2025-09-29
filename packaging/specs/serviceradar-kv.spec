Name:           serviceradar-kv
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar KV service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
ServiceRadar KV service.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

install -m 755 %{_builddir}/serviceradar-kv %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-kv.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/kv.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-kv
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/kv.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-kv.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-kv.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-kv.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-kv.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-kv

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-kv.service
systemctl start serviceradar-kv.service

# Verify the service started successfully
if ! systemctl is-active --quiet serviceradar-kv.service; then
    echo "WARNING: Failed to start service. Check logs with: journalctl -xeu serviceradar-kv.service"
fi


%preun
%systemd_preun serviceradar-kv.service

%postun
%systemd_postun_with_restart serviceradar-kv.service