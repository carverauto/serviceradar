Name:           serviceradar-snmp-checker
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SNMP poller
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
%{?systemd_requires}

%description
This package provides the serviceradar SNMP checker plugin for monitoring services.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar/checkers
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/serviceradar

# Install the binary
install -m 755 %{_builddir}/serviceradar-snmp-checker %{buildroot}/usr/local/bin/

# Install systemd service and config files
install -m 644 %{_sourcedir}/systemd/serviceradar-snmp-checker.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/checkers/snmp.json %{buildroot}/etc/serviceradar/checkers/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-snmp-checker
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/snmp.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-snmp-checker.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/checkers
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-snmp-checker.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-snmp-checker

%preun
%systemd_preun serviceradar-snmp-checker.service

%postun
%systemd_postun_with_restart serviceradar-snmp-checker.service