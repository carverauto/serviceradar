Name:           serviceradar-snmp-checker
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SNMP poller
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
This package provides the serviceradar SNMP checker plugin for monitoring services.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/etc/serviceradar/checkers
mkdir -p %{buildroot}/lib/systemd/system

# Install the binary
install -m 755 %{_builddir}/serviceradar-snmp-checker %{buildroot}/usr/local/bin/

# Install systemd service and config files
install -m 644 %{_sourcedir}/packaging/snmp-checker/systemd/serviceradar-snmp-checker.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/packaging/snmp-checker/config/checkers/snmp.json %{buildroot}/etc/serviceradar/checkers/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-snmp-checker
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/snmp.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-snmp-checker.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/checkers

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
%systemd_post serviceradar-snmp-checker.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-snmp-checker.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-snmp-checker.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-snmp-checker

%preun
%systemd_preun serviceradar-snmp-checker.service

%postun
%systemd_postun_with_restart serviceradar-snmp-checker.service
