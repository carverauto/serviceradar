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

# Install the binary (assumes binary is built at /src/cmd/checkers/rperf-server/target/release/serviceradar-rperf)
install -m 755 %{_builddir}/serviceradar-rperf %{buildroot}/usr/local/bin/

# Install systemd service from packaging directory
install -m 644 %{_sourcedir}/packaging/rperf/systemd/serviceradar-rperf.service %{buildroot}/lib/systemd/system/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-rperf
%attr(0644, root, root) /lib/systemd/system/serviceradar-rperf.service
%dir %attr(0755, serviceradar, serviceradar) /var/log/rperf

%pre
# Ensure serviceradar group exists before user creation
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user with managed home directory if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/serviceradar --create-home \
        --shell /usr/sbin/nologin --gid serviceradar serviceradar
else
    # Align existing user home directory if needed
    CURRENT_HOME=$(getent passwd serviceradar | cut -d: -f6)
    if [ "$CURRENT_HOME" != "/var/lib/serviceradar" ]; then
        usermod --home /var/lib/serviceradar serviceradar >/dev/null 2>&1 || :
    fi
fi

%post
%systemd_post serviceradar-rperf.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-rperf.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-rperf.service >/dev/null 2>&1 || :
fi
mkdir -p /var/log/rperf
chown -R serviceradar:serviceradar /var/log/rperf
chmod 755 /usr/local/bin/serviceradar-rperf
chmod -R 750 /var/log/rperf

%preun
%systemd_preun serviceradar-rperf.service

%postun
%systemd_postun_with_restart serviceradar-rperf.service
