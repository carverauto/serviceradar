Name:           serviceradar-dusk-checker
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Dusk node checker
License:        Proprietary

BuildRequires:  systemd
Requires:       systemd
%{?systemd_requires}

%description
Provides monitoring capabilities for Dusk blockchain nodes.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar/checkers
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/var/lib/serviceradar

# Install the binary
install -m 755 %{_builddir}/dusk-checker %{buildroot}/usr/local/bin/dusk-checker

# Install systemd service and config files
install -m 644 %{_sourcedir}/systemd/serviceradar-dusk-checker.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/config/checkers/dusk.json %{buildroot}/etc/serviceradar/checkers/

%files
%attr(0755, root, root) /usr/local/bin/dusk-checker
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/dusk.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-dusk-checker.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/checkers
%dir %attr(0755, serviceradar, serviceradar) /var/lib/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-dusk-checker.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/dusk-checker

%preun
%systemd_preun serviceradar-dusk-checker.service

%postun
%systemd_postun_with_restart serviceradar-dusk-checker.service