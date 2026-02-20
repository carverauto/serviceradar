Name:           serviceradar-bmp-collector
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar BMP collector
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       serviceradar-cli
%{?systemd_requires}

%description
This package provides the ServiceRadar BMP collector runtime using Arancini,
which receives BGP BMP telemetry and publishes updates to NATS JetStream.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system

install -m 755 %{_builddir}/serviceradar-bmp-collector %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/packaging/bmp-collector/systemd/serviceradar-bmp-collector.service %{buildroot}/lib/systemd/system/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-bmp-collector
%attr(0644, root, root) /lib/systemd/system/serviceradar-bmp-collector.service

%pre
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/serviceradar --create-home \
        --shell /usr/sbin/nologin --gid serviceradar serviceradar
else
    CURRENT_HOME=$(getent passwd serviceradar | cut -d: -f6)
    if [ "$CURRENT_HOME" != "/var/lib/serviceradar" ]; then
        usermod --home /var/lib/serviceradar serviceradar >/dev/null 2>&1 || :
    fi
fi

%post
%systemd_post serviceradar-bmp-collector.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-bmp-collector.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-bmp-collector.service >/dev/null 2>&1 || :
fi
[ -d /etc/serviceradar ] && chown -R serviceradar:serviceradar /etc/serviceradar || :
chmod 755 /usr/local/bin/serviceradar-bmp-collector

%preun
%systemd_preun serviceradar-bmp-collector.service

%postun
%systemd_postun_with_restart serviceradar-bmp-collector.service
