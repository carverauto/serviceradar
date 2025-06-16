Name:           serviceradar-trapd
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar SNMP trap receiver service
License:        Proprietary

BuildRequires:  systemd
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
install -m 644 %{_sourcedir}/trapd/systemd/serviceradar-trapd.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/trapd/config/trapd.json %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-trapd
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/trapd.json
%attr(0644, root, root) /lib/systemd/system/serviceradar-trapd.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-trapd.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-trapd

%preun
%systemd_preun serviceradar-trapd.service

%postun
%systemd_postun_with_restart serviceradar-trapd.service
