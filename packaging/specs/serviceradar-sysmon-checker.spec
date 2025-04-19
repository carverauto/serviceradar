Name:           serviceradar-sysmon-checker
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SysMon metrics checker plugin
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
Requires:       serviceradar-sysmon
%{?systemd_requires}

%description
This package provides the ServiceRadar SysMon checker plugin for monitoring SysMon (sysinfo+zfs/zpool) metrics.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar/checkers
mkdir -p %{buildroot}/var/lib/serviceradar

# Install the binary (assumes binary is built at /src/cmd/checkers/sysmon-client/target/release/serviceradar-sysmon-checker)
install -m 755 %{_builddir}/serviceradar-sysmon-checker %{buildroot}/usr/local/bin/

# Install systemd service and config files from packaging directory
install -m 644 %{_sourcedir}/sysmon-checker/systemd/serviceradar-sysmon-checker.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/sysmon-checker/config/checkers/sysmon.json %{buildroot}/etc/serviceradar/checkers/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-sysmon-checker
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/sysmon.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-sysmon-checker.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/checkers
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-sysmon-checker.service
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chmod 755 /usr/local/bin/serviceradar-sysmon-checker

%preun
%systemd_preun serviceradar-sysmon-checker.service

%postun
%systemd_postun_with_restart serviceradar-sysmon-checker.service
