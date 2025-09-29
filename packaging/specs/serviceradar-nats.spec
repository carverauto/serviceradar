Name:           serviceradar-nats
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar NATS JetStream service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
NATS JetStream (Message Broker, KV) service for ServiceRadar monitoring system.

%install
# Create directories in the buildroot
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/nats/jetstream
mkdir -p %{buildroot}/var/log/nats
mkdir -p %{buildroot}/etc/nats

# Install files into the buildroot
install -m 755 %{_builddir}/nats-server %{buildroot}/usr/bin/nats-server
install -m 644 %{_sourcedir}/packaging/nats/systemd/serviceradar-nats.service %{buildroot}/lib/systemd/system/serviceradar-nats.service
install -m 644 %{_sourcedir}/packaging/nats/config/nats-server.conf %{buildroot}/etc/nats/nats-server.conf

%files
%attr(0755, nats, nats) /usr/bin/nats-server
%config(noreplace) %attr(0644, nats, nats) /etc/nats/nats-server.conf
%attr(0644, root, root) /lib/systemd/system/serviceradar-nats.service
%dir %attr(0755, nats, nats) /var/lib/nats
%dir %attr(0755, nats, nats) /var/lib/nats/jetstream
%dir %attr(0755, nats, nats) /var/log/nats

%pre
# Create nats user if it doesn't exist
if ! getent group nats >/dev/null; then
    groupadd --system nats
fi
if ! id -u nats >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid nats nats
fi

%post
%systemd_post serviceradar-nats.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-nats.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-nats.service >/dev/null 2>&1 || :
fi
# Create required directories with proper permissions
mkdir -p /var/lib/nats/jetstream /var/log/nats
chown -R nats:nats /var/lib/nats /var/log/nats
chmod -R 750 /var/lib/nats /var/log/nats

# Add nats user to serviceradar group if it exists
if getent group serviceradar >/dev/null; then
    usermod -aG serviceradar nats
fi
# Allow nats user to read the ServiceRadar certificates if they exist
if [ -d "/etc/serviceradar/certs/" ]; then
    chmod 750 /etc/serviceradar/certs/
fi
chmod 755 /usr/bin/nats-server

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-nats.service
systemctl start serviceradar-nats.service || true

%preun
%systemd_preun serviceradar-nats.service

%postun
%systemd_postun_with_restart serviceradar-nats.service