Name:           serviceradar-zen
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Zen Consumer Service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       serviceradar-zen
%{?systemd_requires}

%description
This package provides the ServiceRadar Zen consumer service, which is responsible for consuming messages from the NATS JetStream and processing them.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar/consumers
mkdir -p %{buildroot}/etc/serviceradar/zen/rules

# Install the binary (assumes binary is built at /src/cmd/zen/target/release/serviceradar-zen)
install -m 755 %{_builddir}/serviceradar-zen %{buildroot}/usr/local/bin/
install -m 755 %{_builddir}/zen-put-rule %{buildroot}/usr/local/bin/

# Install systemd service and config files from packaging directory
install -m 644 %{_sourcedir}/zen/systemd/serviceradar-zen.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/zen/config/zen-consumer.json %{buildroot}/etc/serviceradar/consumers/
install -m 644 %{_sourcedir}/zen/rules/*.json %{buildroot}/etc/serviceradar/zen/rules/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-zen
%attr(0755, root, root) /usr/local/bin/zen-put-rule
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/consumers/zen-consumer.json
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/zen/rules/*.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-zen.service
%dir %attr(0755, root, root) /etc/serviceradar
%dir %attr(0755, root, root) /etc/serviceradar/zen
%dir %attr(0755, root, root) /etc/serviceradar/zen/rules

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-zen.service
if [ $1 -eq 1 ]; then
    systemctl enable --now serviceradar-zen.service >/dev/null 2>&1 || :
else
    systemctl try-restart serviceradar-zen.service >/dev/null 2>&1 || :
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-zen
chmod 755 /usr/local/bin/zen-put-rule

%preun
%systemd_preun serviceradar-zen.service

%postun
%systemd_postun_with_restart serviceradar-zen.service
