Name:           serviceradar-srql
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SRQL OCaml query service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       ca-certificates
Requires:       libev
Requires:       gmp
Requires:       lz4
Requires:       zstd
Requires:       openssl
%{?systemd_requires}

%description
ServiceRadar SRQL provides the OCaml implementation of the ServiceRadar Query Language
(SRQL) and exposes REST endpoints for translating and executing SRQL queries against
Proton. The service relies on Proton's certificates for secure connectivity and uses a
configurable API key for request authentication.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

install -m 755 %{_builddir}/serviceradar-srql %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/srql/systemd/serviceradar-srql.service %{buildroot}/lib/systemd/system/
install -m 640 %{_sourcedir}/srql/config/srql.env %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-srql
%config(noreplace) %attr(0640, root, serviceradar) /etc/serviceradar/srql.env
%attr(0644, root, root) /lib/systemd/system/serviceradar-srql.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

%post
%systemd_post serviceradar-srql.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-srql.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-srql.service >/dev/null 2>&1 || :
fi
mkdir -p /var/log/serviceradar
chown serviceradar:serviceradar /var/log/serviceradar
if [ -f /etc/serviceradar/srql.env ]; then
    chown root:serviceradar /etc/serviceradar/srql.env
    chmod 640 /etc/serviceradar/srql.env
fi
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -Rv /usr/local/bin/serviceradar-srql /etc/serviceradar 2>/dev/null || true
    fi
fi

%preun
%systemd_preun serviceradar-srql.service

%postun
%systemd_postun_with_restart serviceradar-srql.service
