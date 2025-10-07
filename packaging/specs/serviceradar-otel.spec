Name:           serviceradar-otel
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar OTEL Collector
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
This package provides the ServiceRadar OpenTelemetry Collector for collecting and exporting telemetry data
to NATS JetStream. It is designed to work with the ServiceRadar platform, providing observability and monitoring
capabilities.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/log/serviceradar

# Install the binary (assumes binary is built at /src/cmd/otel/target/release/serviceradar-otel)
install -m 755 %{_builddir}/serviceradar-otel %{buildroot}/usr/local/bin/

# Install systemd service from packaging directory
install -m 644 %{_sourcedir}/packaging/otel/systemd/serviceradar-otel.service %{buildroot}/lib/systemd/system/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-otel
%attr(0644, root, root) /lib/systemd/system/serviceradar-otel.service
%dir %attr(0755, serviceradar, serviceradar) /var/log/serviceradar

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
%systemd_post serviceradar-otel.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-otel.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-otel.service >/dev/null 2>&1 || :
fi
mkdir -p /var/log/serviceradar
chown -R serviceradar:serviceradar /var/log/serviceradar
chmod 755 /usr/local/bin/serviceradar-otel
chmod -R 750 /var/log/serviceradar

%preun
%systemd_preun serviceradar-otel.service

%postun
%systemd_postun_with_restart serviceradar-otel.service
