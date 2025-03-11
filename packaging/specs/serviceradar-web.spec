Name:           serviceradar-web
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar web interface
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
Requires:       nginx
Requires:       nodejs >= 20.0.0
Requires:       epel-release
Recommends:     serviceradar-core
%{?systemd_requires}

%description
Next.js web interface for the ServiceRadar monitoring system.
Includes Nginx configuration for integrated API and UI access.

%install
mkdir -p %{buildroot}/usr/lib/serviceradar/web
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/etc/nginx/conf.d
mkdir -p %{buildroot}/etc/serviceradar/selinux

# Copy all web files - handle with wildcard to avoid errors if some files don't exist
cp -r %{_builddir}/web/* %{buildroot}/usr/lib/serviceradar/web/ 2>/dev/null || :
cp -r %{_builddir}/web/.next %{buildroot}/usr/lib/serviceradar/web/ 2>/dev/null || :

# Install systemd service
install -m 644 %{_sourcedir}/systemd/serviceradar-web.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/web.json %{buildroot}/etc/serviceradar/
install -m 644 %{_sourcedir}/config/nginx.conf %{buildroot}/etc/nginx/conf.d/serviceradar-web.conf

# Install SELinux policy file
install -m 644 %{_sourcedir}/selinux/serviceradar-nginx.te %{buildroot}/etc/serviceradar/selinux/

%files
%attr(0755, serviceradar, serviceradar) /usr/lib/serviceradar/web
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/web.json
%config(noreplace) %attr(0644, root, root) /etc/nginx/conf.d/serviceradar-web.conf
%attr(0644, root, root) /lib/systemd/system/serviceradar-web.service
%attr(0644, root, root) /etc/serviceradar/selinux/serviceradar-nginx.te
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/selinux

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Create directory structure
mkdir -p /usr/lib/serviceradar/web

%post
%systemd_post serviceradar-web.service

# Add epel if needed
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

# Check for Node.js 20 and enable if needed
if ! dnf module list nodejs | grep -q 'nodejs.*\[e\]'; then
    dnf module enable -y nodejs:20
    dnf install -y nodejs
fi

# Check for API key from core package
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "WARNING: API key file not found. Creating temporary API key..."
    API_KEY=$(openssl rand -hex 32)
    echo "API_KEY=$API_KEY" > /etc/serviceradar/api.env
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "For proper functionality, please install serviceradar-core package."
else
    # Fix permissions on existing API key file
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
fi

# Configure SELinux if available
if command -v setsebool >/dev/null 2>&1 && command -v semanage >/dev/null 2>&1; then
    # Install SELinux utilities if needed
    if ! command -v checkmodule >/dev/null 2>&1; then
        dnf install -y policycoreutils-python-utils
    fi

    # Allow Nginx to connect to network services
    setsebool -P httpd_can_network_connect 1

    # Configure port types
    semanage port -a -t http_port_t -p tcp 3000 || semanage port -m -t http_port_t -p tcp 3000
    semanage port -a -t http_port_t -p tcp 8090 || semanage port -m -t http_port_t -p tcp 8090

    # Apply SELinux policy module
    if [ -f "/etc/serviceradar/selinux/serviceradar-nginx.te" ] && [ "$(getenforce)" = "Enforcing" ]; then
        checkmodule -M -m -o /tmp/serviceradar-nginx.mod /etc/serviceradar/selinux/serviceradar-nginx.te
        semodule_package -o /tmp/serviceradar-nginx.pp -m /tmp/serviceradar-nginx.mod
        semodule -i /tmp/serviceradar-nginx.pp
        rm -f /tmp/serviceradar-nginx.mod /tmp/serviceradar-nginx.pp
    fi

    # Fix context on web files
    restorecon -Rv /usr/lib/serviceradar/web || true
fi

# Configure firewall if needed
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=3000/tcp
    firewall-cmd --reload
fi

# Configure Nginx
if systemctl is-active --quiet nginx; then
    systemctl reload nginx || systemctl restart nginx || echo "Warning: Failed to reload/restart Nginx."
fi

# Ensure web service is enabled and started
systemctl daemon-reload
systemctl enable serviceradar-web
systemctl start serviceradar-web || echo "Failed to start service, please check logs with: journalctl -xeu serviceradar-web"

%preun
%systemd_preun serviceradar-web.service

%postun
%systemd_postun_with_restart serviceradar-web.service