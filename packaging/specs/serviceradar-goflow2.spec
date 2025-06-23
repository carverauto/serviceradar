#
# RPM spec file for serviceradar-goflow2
#
Name:           serviceradar-goflow2
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar NetFlow/sFlow/IPFIX collector with NATS support.
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd, serviceradar-cli
%{?systemd_requires}

%description
A forked build of goflow2 that includes NATS JetStream transport for use
with the ServiceRadar monitoring system. It collects flow data (NetFlow, sFlow, IPFIX)
and forwards it to a NATS stream for processing.

%install
# Create directories in the buildroot
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

# Install files into the buildroot
# The serviceradar-goflow2 binary should be placed in %{_builddir} by your build script
install -m 755 %{_builddir}/serviceradar-goflow2 %{buildroot}/usr/local/bin/serviceradar-goflow2

# The service and conf files should be in %{_sourcedir}
install -m 644 %{_sourcedir}/systemd/serviceradar-goflow2.service %{buildroot}/lib/systemd/system/serviceradar-goflow2.service
install -m 644 %{_sourcedir}/config/goflow2.conf %{buildroot}/etc/serviceradar/goflow2.conf

%files
%attr(0755, serviceradar, serviceradar) /usr/local/bin/serviceradar-goflow2
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/goflow2.conf
%attr(0644, root, root) /lib/systemd/system/serviceradar-goflow2.service

%pre
# Create serviceradar user and group if they don't exist.
# This makes the package installable on a standalone machine.
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid serviceradar serviceradar
fi

%post
# Use standard systemd macros to handle service installation
%systemd_post serviceradar-goflow2.service

# Ensure the 'serviceradar' user can read the shared TLS certificates
if [ -d "/etc/serviceradar/certs/" ]; then
    chmod 750 /etc/serviceradar/certs/
fi

# Reload the systemd daemon, then enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-goflow2.service
# Using '|| true' prevents the package installation from failing if the service can't start immediately
systemctl start serviceradar-goflow2.service || true

%preun
# Use standard systemd macro for service uninstallation
%systemd_preun serviceradar-goflow2.service

%postun
# Use standard systemd macro to handle service after uninstallation
%systemd_postun_with_restart serviceradar-goflow2.service