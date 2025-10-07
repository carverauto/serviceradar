Name:           serviceradar-trapd
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SNMP trap receiver service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       serviceradar-trapd
%{?systemd_requires}

%description
This package provides the ServiceRadar trapd service, which is responsible for receiving SNMP traps and forwarding them to the ServiceRadar platform.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

# Install the binary (assumes binary is built at /src/cmd/trapd/target/release/serviceradar-trapd)
install -m 755 %{_builddir}/serviceradar-trapd %{buildroot}/usr/local/bin/

# Install systemd service and config files from packaging directory
install -m 644 %{_sourcedir}/packaging/trapd/systemd/serviceradar-trapd.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/packaging/trapd/config/trapd.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-trapd
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/trapd.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-trapd.service
%dir %attr(0755, root, root) /etc/serviceradar

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
%systemd_post serviceradar-trapd.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-trapd.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-trapd.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-trapd

%preun
%systemd_preun serviceradar-trapd.service

%postun
%systemd_postun_with_restart serviceradar-trapd.service
