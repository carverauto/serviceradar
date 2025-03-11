Name:           serviceradar-core
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar core service with web interface
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
Requires:       epel-release
%{?systemd_requires}

Source: systemd/serviceradar-core.service

%description
Provides centralized monitoring and web dashboard for ServiceRadar.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/etc/serviceradar/checkers/sweep
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/serviceradar
mkdir -p %{buildroot}/etc/serviceradar/selinux

install -m 755 %{_builddir}/serviceradar-core %{buildroot}/usr/local/bin/
install -m 644 %{_sourcedir}/systemd/serviceradar-core.service %{buildroot}/lib/systemd/system/serviceradar-core.service
install -m 644 %{_sourcedir}/config/core.json %{buildroot}/etc/serviceradar/
install -m 644 %{_sourcedir}/config/checkers/sweep/sweep.json %{buildroot}/etc/serviceradar/checkers/sweep/

# Install SELinux policy template
cat > %{buildroot}/etc/serviceradar/selinux/serviceradar-core.te << 'EOF'
module serviceradar-core 1.0;

require {
    type httpd_t;
    type port_t;
    class tcp_socket name_connect;
}

#============= httpd_t ==============
allow httpd_t port_t:tcp_socket name_connect;
EOF

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-core
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/core.json
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/sweep/sweep.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-core.service
%attr(0644, root, root) /etc/serviceradar/selinux/serviceradar-core.te
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-core.service

# Check if EPEL repository is installed, install if missing
if ! rpm -q epel-release >/dev/null 2>&1; then
    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
fi

# Enable CodeReady Builder repository for Oracle Linux
if grep -q "Oracle Linux" /etc/os-release; then
    if command -v /usr/bin/crb >/dev/null 2>&1; then
        /usr/bin/crb enable
    else
        dnf config-manager --set-enabled ol9_codeready_builder || true
    fi
fi

# Generate API key if it doesn't exist
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "Generating API key..."
    API_KEY=$(openssl rand -hex 32)
    echo "API_KEY=$API_KEY" > /etc/serviceradar/api.env
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "API key generated and stored in /etc/serviceradar/api.env"
else
    # Make sure existing API key has correct permissions
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
fi

# Configure SELinux if available
if command -v setsebool >/dev/null 2>&1 && command -v semanage >/dev/null 2>&1; then
    # Install SELinux utilities if needed
    if ! command -v checkmodule >/dev/null 2>&1; then
        dnf install -y policycoreutils-python-utils
    fi

    # Allow HTTP connections
    setsebool -P httpd_can_network_connect 1

    # Configure port types
    semanage port -a -t http_port_t -p tcp 8090 || semanage port -m -t http_port_t -p tcp 8090
    semanage port -a -t http_port_t -p tcp 50052 || semanage port -m -t http_port_t -p tcp 50052

    # Apply SELinux policy if in enforcing mode
    if [ "$(getenforce)" = "Enforcing" ]; then
        checkmodule -M -m -o /tmp/serviceradar-core.mod /etc/serviceradar/selinux/serviceradar-core.te
        semodule_package -o /tmp/serviceradar-core.pp -m /tmp/serviceradar-core.mod
        semodule -i /tmp/serviceradar-core.pp
        rm -f /tmp/serviceradar-core.mod /tmp/serviceradar-core.pp
    fi

    # Set correct context for binary and data directories
    restorecon -Rv /usr/local/bin/serviceradar-core
    restorecon -Rv /var/lib/serviceradar
fi

# Configure firewall if running
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=8090/tcp --zone=public
    firewall-cmd --permanent --add-port=50052/tcp --zone=public
    firewall-cmd --reload
    logger "Configured firewalld for ServiceRadar (ports 8090/tcp and 50052/tcp, zone public)."
fi

# Create data directory with proper permissions
mkdir -p /var/lib/serviceradar
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /var/lib/serviceradar

# Set proper permissions for configuration
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar

# Start and enable service
systemctl daemon-reload
systemctl enable serviceradar-core
systemctl start serviceradar-core || echo "Failed to start service, please check the logs with: journalctl -xeu serviceradar-core"

echo "ServiceRadar Core API service installed successfully!"
echo "API is running on port 8090"

%preun
# Stop and disable service if this is a complete uninstall (not an upgrade)
if [ $1 -eq 0 ]; then
    systemctl stop serviceradar-core >/dev/null 2>&1 || :
    systemctl disable serviceradar-core >/dev/null 2>&1 || :
fi

%postun
# Restart the service on upgrade
if [ $1 -ge 1 ]; then
    systemctl try-restart serviceradar-core >/dev/null 2>&1 || :
fi