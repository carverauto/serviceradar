Name:           serviceradar-cloud
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar cloud service with web interface
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
%{?systemd_requires}

%description
Provides centralized monitoring and web dashboard for ServiceRadar.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/serviceradar

install -m 755 %{_builddir}/serviceradar-cloud %{buildroot}/usr/local/bin/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-cloud
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-cloud.service

%preun
%systemd_preun serviceradar-cloud.service

%postun
%systemd_postun_with_restart serviceradar-cloud.service