Name:           serviceradar-agent
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar monitoring agent
License:        Proprietary

BuildRequires:  systemd-rpm-macros
BuildRequires:  libcap-devel
BuildRequires:  gcc
Requires:       systemd
Requires:       libcap
%{?systemd_requires}

%description
Monitoring agent for ServiceRadar system.
Provides local system monitoring capabilities.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar/checkers/sweep
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/serviceradar

install -m 755 %{_builddir}/serviceradar-agent %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-agent.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/agent.json %{buildroot}/etc/serviceradar/
install -m 644 %{_sourcedir}/config/checkers/sweep/sweep.json %{buildroot}/etc/serviceradar/checkers/sweep/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-agent
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/agent.json
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/sweep/sweep.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-agent.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/checkers
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-agent.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-agent
# Set required capability for ICMP scanning
# setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent
sudo setcap '13,21,38,39+ep' /usr/local/bin/serviceradar-agent

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-agent.service
systemctl start serviceradar-agent.service

# Verify the service started successfully
if ! systemctl is-active --quiet serviceradar-agent.service; then  # or serviceradar-poller.service
    echo "WARNING: Failed to start service. Check logs with: journalctl -xeu serviceradar-agent.service"
fi


%preun
%systemd_preun serviceradar-agent.service

%postun
%systemd_postun_with_restart serviceradar-agent.service
