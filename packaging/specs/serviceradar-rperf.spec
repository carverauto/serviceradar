Name:           serviceradar-rperf
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar RPerf Server
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
This package provides the ServiceRadar RPerf server for network performance testing, measuring metrics such as throughput, latency, jitter, and packet loss.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/log/rperf
mkdir -p %{buildroot}/var/lib/serviceradar

# Install the binary (assumes binary is built at /src/cmd/checkers/rperf-server/target/release/serviceradar-rperf)
install -m 755 %{_builddir}/serviceradar-rperf %{buildroot}/usr/local/bin/

# Install systemd service from packaging directory
install -m 644 %{_sourcedir}/rperf/systemd/serviceradar-rperf.service %{buildroot}/lib/systemd/system/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-rperf
%attr(0644, root, root) /lib/systemd/system/serviceradar-rperf.service
%dir %attr(0755, serviceradar, serviceradar) /var/log/rperf
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-rperf.service
mkdir -p /var/log/rperf
chown -R serviceradar:serviceradar /var/log/rperf
chmod 755 /usr/local/bin/serviceradar-rperf
chmod -R 750 /var/log/rperf

%preun
%systemd_preun serviceradar-rperf.service

%postun
%systemd_postun_with_restart serviceradar-rperf.service
