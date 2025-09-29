Name:           serviceradar-profiler
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar eBPF Profiler for Linux Systems
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
The ServiceRadar eBPF Profiler collects performance metrics from Linux systems using eBPF technology. It is designed to provide deep insights into system performance with minimal overhead.
This package includes the profiler binary and a systemd service for easy management.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/log/serviceradar

# Install the binary (assumes binary is built at /src/cmd/profiler/target/release/serviceradar-profiler)
install -m 755 %{_builddir}/serviceradar-profiler %{buildroot}/usr/local/bin/

# Install systemd service from packaging directory
install -m 644 %{_sourcedir}/profiler/systemd/serviceradar-profiler.service %{buildroot}/lib/systemd/system/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-profiler
%attr(0644, root, root) /lib/systemd/system/serviceradar-profiler.service
%dir %attr(0755, serviceradar, serviceradar) /var/log/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-profiler.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-profiler.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-profiler.service >/dev/null 2>&1 || :
fi
mkdir -p /var/log/serviceradar
chown -R serviceradar:serviceradar /var/log/serviceradar
chmod 755 /usr/local/bin/serviceradar-profiler
chmod -R 750 /var/log/serviceradar

%preun
%systemd_preun serviceradar-profiler.service

%postun
%systemd_postun_with_restart serviceradar-profiler.service
