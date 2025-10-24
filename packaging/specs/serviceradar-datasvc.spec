Name:           serviceradar-datasvc
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Data Service (KV + object store)
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
ServiceRadar data service providing both KV and object-store APIs.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

install -m 755 %{_builddir}/serviceradar-datasvc %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/packaging/datasvc/systemd/serviceradar-datasvc.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/packaging/datasvc/config/datasvc.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-datasvc
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/datasvc.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-datasvc.service
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
%systemd_post serviceradar-datasvc.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-datasvc.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-datasvc.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-datasvc

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-datasvc.service
systemctl start serviceradar-datasvc.service

# Verify the service started successfully
if ! systemctl is-active --quiet serviceradar-datasvc.service; then
    echo "WARNING: Failed to start service. Check logs with: journalctl -xeu serviceradar-datasvc.service"
fi


%preun
%systemd_preun serviceradar-datasvc.service

%postun
%systemd_postun_with_restart serviceradar-datasvc.service
