Name:           serviceradar-sysmon-checker
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SysMon metrics checker plugin
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
%{?systemd_requires}

%description
This package provides the ServiceRadar SysMon checker plugin for monitoring system metrics (CPU, memory, disk, and optionally ZFS).

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar/checkers

# Install both binaries
install -m 755 %{_builddir}/serviceradar-sysmon-checker-zfs %{buildroot}/usr/local/bin/
install -m 755 %{_builddir}/serviceradar-sysmon-checker-nonzfs %{buildroot}/usr/local/bin/

# Install systemd service and config files
install -m 644 %{_sourcedir}/packaging/sysmon-checker/systemd/serviceradar-sysmon-checker.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/packaging/sysmon-checker/config/checkers/sysmon.json.example %{buildroot}/etc/serviceradar/checkers/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-sysmon-checker-zfs
%attr(0755, root, root) /usr/local/bin/serviceradar-sysmon-checker-nonzfs
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/checkers/sysmon.json.example
%attr(0644, root, root) /lib/systemd/system/serviceradar-sysmon-checker.service
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
%systemd_post serviceradar-sysmon-checker.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-sysmon-checker.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-sysmon-checker.service >/dev/null 2>&1 || :
fi

# Check for ZFS availability
ZFS_AVAILABLE=false
if command -v zfs >/dev/null; then
    ZFS_AVAILABLE=true
fi

# Select binary
if [ "$ZFS_AVAILABLE" = "true" ]; then
    cp /usr/local/bin/serviceradar-sysmon-checker-zfs /usr/local/bin/serviceradar-sysmon-checker
    echo "Using ZFS-enabled binary"
else
    cp /usr/local/bin/serviceradar-sysmon-checker-nonzfs /usr/local/bin/serviceradar-sysmon-checker
    echo "Using non-ZFS binary"
fi

# Configure sysmon.json
if [ ! -f /etc/serviceradar/checkers/sysmon.json ]; then
    if [ "$ZFS_AVAILABLE" = "true" ]; then
        ZFS_POOLS=$(zfs list -H -o name | grep -v "/" | tr '\n' ' ')
        POOLS_JSON=$(echo "$ZFS_POOLS" | awk '{printf "[\"%s\"]", $1}' | sed 's/ /","/g')
        cat > /etc/serviceradar/checkers/sysmon.json << EOF
{
    "listen_addr": "0.0.0.0:50060",
    "security": {"tls_enabled": false},
    "poll_interval": 30,
    "zfs": {
        "enabled": true,
        "pools": $POOLS_JSON,
        "include_datasets": true,
        "use_libzetta": true
    },
    "filesystems": [{"name": "/", "type": "ext4", "monitor": true}]
}
EOF
    else
        cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json
    fi
    chown serviceradar:serviceradar /etc/serviceradar/checkers/sysmon.json
    chmod 644 /etc/serviceradar/checkers/sysmon.json
fi

chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chmod 755 /usr/local/bin/serviceradar-sysmon-checker

%preun
%systemd_preun serviceradar-sysmon-checker.service

%postun
%systemd_postun_with_restart serviceradar-sysmon-checker.service
