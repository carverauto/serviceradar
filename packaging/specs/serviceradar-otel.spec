Name:           serviceradar-otel
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar OTEL Collector
License:        Proprietary

BuildRequires:  systemd
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
install -m 644 %{_sourcedir}/otel/systemd/serviceradar-otel.service %{buildroot}/lib/systemd/system/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-otel
%attr(0644, root, root) /lib/systemd/system/serviceradar-otel.service
%dir %attr(0755, serviceradar, serviceradar) /var/log/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-otel.service
mkdir -p /var/log/serviceradar
chown -R serviceradar:serviceradar /var/log/serviceradar
chmod 755 /usr/local/bin/serviceradar-otel
chmod -R 750 /var/log/serviceradar

%preun
%systemd_preun serviceradar-otel.service

%postun
%systemd_postun_with_restart serviceradar-otel.service
