Name:           serviceradar-nats
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar NATS JetStream service
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
%{?systemd_requires}

%description
NATS JetStream (Message Broker, KV) service for ServiceRadar monitoring system.

%install
mkdir -p %{buildroot}/usr/sbin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/nats

install -m 755 %{_builddir}/nats-server %{buildroot}/usr/sbin/
install -m 644 %{_sourcedir}/systemd/serviceradar-nats.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/nats-server.conf %{buildroot}/etc/

%files
%attr(0755, nats, nats) /usr/sbin/nats-server
%config(noreplace) %attr(0644, nats, nats) /etc/nats-server.conf
%attr(0644, root, root) /lib/systemd/system/serviceradar-nats.service

%pre
# Create nats user if it doesn't exist
if ! id -u nats >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin nats
fi

%post
%systemd_post serviceradar-nats.service
chmod 755 /usr/sbin/nats-server

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-nats.service
systemctl start serviceradar-nats.service

%preun
%systemd_preun serviceradar-nats.service

%postun
%systemd_postun_with_restart serviceradar-nats.service
