Name:           serviceradar-poller
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar poller service
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
%{?systemd_requires}

%description
Poller component for ServiceRadar monitoring system.
Collects and forwards monitoring data from agents to cloud service.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/serviceradar

install -m 755 %{_builddir}/serviceradar-poller %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-poller.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/poller.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-poller
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/poller.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-poller.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-poller.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-poller

%preun
%systemd_preun serviceradar-poller.service

%postun
%systemd_postun_with_restart serviceradar-poller.service
