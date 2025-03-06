Name:           serviceradar-web
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar web interface
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
Requires:       nginx
Requires:       nodejs >= 16.0.0
Recommends:     serviceradar-core
%{?systemd_requires}

%description
Next.js web interface for the ServiceRadar monitoring system.
Includes Nginx configuration for integrated API and UI access.

%install
mkdir -p %{buildroot}/usr/local/share/serviceradar-web
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar
mkdir -p %{buildroot}/etc/nginx/conf.d

# Copy all web files - handle with wildcard to avoid errors if some files don't exist
cp -r %{_builddir}/web/* %{buildroot}/usr/local/share/serviceradar-web/ 2>/dev/null || :
cp -r %{_builddir}/web/.next %{buildroot}/usr/local/share/serviceradar-web/ 2>/dev/null || :

# Install systemd service
install -m 644 %{_sourcedir}/systemd/serviceradar-web.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/web.json %{buildroot}/etc/serviceradar/
install -m 644 %{_sourcedir}/config/nginx.conf %{buildroot}/etc/nginx/conf.d/serviceradar-web.conf

%files
%attr(0755, serviceradar, serviceradar) /usr/local/share/serviceradar-web
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/web.json
%config(noreplace) %attr(0644, root, root) /etc/nginx/conf.d/serviceradar-web.conf
%attr(0644, root, root) /lib/systemd/system/serviceradar-web.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-web.service

# Check for API key from core package
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "WARNING: API key file not found. Creating temporary API key..."
    API_KEY=$(openssl rand -hex 32)
    echo "API_KEY=$API_KEY" > /etc/serviceradar/api.env
    chmod 600 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "For proper functionality, please install serviceradar-core package."
fi

# Configure Nginx
if systemctl is-active --quiet nginx; then
    systemctl reload nginx || systemctl restart nginx || echo "Warning: Failed to reload/restart Nginx."
fi

%preun
%systemd_preun serviceradar-web.service

%postun
%systemd_postun_with_restart serviceradar-web.service