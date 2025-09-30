Name:           serviceradar-proton
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Proton Server (Time-series database)
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
Proton time-series database server component for ServiceRadar monitoring system.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/proton-server
mkdir -p %{buildroot}/var/lib/proton
mkdir -p %{buildroot}/var/lib/proton/tmp
mkdir -p %{buildroot}/var/lib/proton/checkpoint
mkdir -p %{buildroot}/var/lib/proton/nativelog/meta
mkdir -p %{buildroot}/var/lib/proton/nativelog/log
mkdir -p %{buildroot}/var/lib/proton/user_files
mkdir -p %{buildroot}/var/log/proton-server

# Install binary
install -m 755 %{_sourcedir}/packaging/proton/proton %{buildroot}/usr/bin/

# Provide compatibility symlinks expected by service scripts
ln -sf proton %{buildroot}/usr/bin/proton-server
ln -sf proton %{buildroot}/usr/bin/proton-client
ln -sf proton %{buildroot}/usr/bin/proton-local

# Install systemd service
install -m 644 %{_sourcedir}/packaging/proton/systemd/serviceradar-proton.service %{buildroot}/lib/systemd/system/

# Install configuration files
install -m 644 %{_sourcedir}/packaging/proton/config/config.yaml %{buildroot}/etc/proton-server/
install -m 644 %{_sourcedir}/packaging/proton/config/users.yaml %{buildroot}/etc/proton-server/

%files
%attr(0755, root, root) /usr/bin/proton
/usr/bin/proton-server
/usr/bin/proton-client
/usr/bin/proton-local
%config(noreplace) %attr(0644, proton, proton) /etc/proton-server/config.yaml
%config(noreplace) %attr(0644, proton, proton) /etc/proton-server/users.yaml
%attr(0644, root, root) /lib/systemd/system/serviceradar-proton.service
%dir %attr(0755, proton, proton) /var/lib/proton
%dir %attr(0755, proton, proton) /var/lib/proton/tmp
%dir %attr(0755, proton, proton) /var/lib/proton/checkpoint
%dir %attr(0755, proton, proton) /var/lib/proton/nativelog
%dir %attr(0755, proton, proton) /var/lib/proton/nativelog/meta
%dir %attr(0755, proton, proton) /var/lib/proton/nativelog/log
%dir %attr(0755, proton, proton) /var/lib/proton/user_files
%dir %attr(0755, proton, proton) /var/log/proton-server
%ghost %dir %attr(0755, proton, proton) /run/proton-server

%pre
# Create proton group if it doesn't exist
if ! getent group proton >/dev/null; then
    groupadd --system proton
fi

# Create proton user if it doesn't exist
if ! id -u proton >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g proton proton
fi

%post
%systemd_post serviceradar-proton.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-proton.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-proton.service >/dev/null 2>&1 || :
fi

# Set up required directories
mkdir -p /var/lib/proton/{tmp,checkpoint,nativelog/meta,nativelog/log,user_files}
mkdir -p /var/log/proton-server
install -d -m 0755 -o proton -g proton /run/proton-server

# Set proper ownership and permissions
chown -R proton:proton /etc/proton-server
chown -R proton:proton /var/lib/proton
chown -R proton:proton /var/log/proton-server
chown root:root /usr/bin/proton
chmod 755 /usr/bin/proton

# Run proton install to set up the server properly
echo "Running proton install to set up the server..."
/usr/bin/proton install

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-proton
if ! systemctl start serviceradar-proton; then
    echo "WARNING: Failed to start serviceradar-proton service. Please check the logs."
    echo "Run: journalctl -u serviceradar-proton.service"
fi

%preun
%systemd_preun serviceradar-proton.service

%postun
%systemd_postun_with_restart serviceradar-proton.service
