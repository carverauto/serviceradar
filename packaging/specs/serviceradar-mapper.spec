Name:           serviceradar-mapper
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Mapper Service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
ServiceRadar Mapper service.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

install -m 755 %{_builddir}/serviceradar-mapper %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-mapper.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/mapper.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-mapper
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/mapper.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-mapper.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-mapper.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-mapper

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-mapper.service
systemctl start serviceradar-mapper.service

# Verify the service started successfully
if ! systemctl is-active --quiet serviceradar-mapper.service; then
    echo "WARNING: Failed to start service. Check logs with: journalctl -xeu serviceradar-mapper.service"
fi


%preun
%systemd_preun serviceradar-mapper.service

%postun
%systemd_postun_with_restart serviceradar-mapper.service