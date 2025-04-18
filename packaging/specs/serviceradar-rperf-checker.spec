Name:           serviceradar-rperf-checker
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar RPerf Network Performance Checker
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
Requires:       serviceradar-rperf
%{?systemd_requires}

%description
This package provides the ServiceRadar RPerf checker plugin for monitoring network performance metrics such as throughput, latency, jitter, and packet loss.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar/checkers
mkdir -p %{buildroot}/var/lib/serviceradar

# Install the binary (assumes binary is built at /src/cmd/checkers/rperf-client/target/release/serviceradar-rperf-checker)
install -m 755 %{_builddir}/serviceradar-rperf-checker %{buildroot}/usr/local/bin/

# Install systemd service and config files from packaging directory
install -m 644 %{_sourcedir}/rperf-checker/systemd/serviceradar-rperf-checker.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/rperf-checker/config/checkers/rperf.json %{buildroot}/etc/serviceradar/checkers/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-rperf-checker
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/rperf.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-rperf-checker.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/checkers
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-rperf-checker.service
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chmod 755 /usr/local/bin/serviceradar-rperf-checker

%preun
%systemd_preun serviceradar-rperf-checker.service

%postun
%systemd_postun_with_restart serviceradar-rperf-checker.service
