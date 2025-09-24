Name:           serviceradar-flowgger
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Flowgger logging ingestion service
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       serviceradar-flowgger
%{?systemd_requires}

%description
This package provides the ServiceRadar flowgger service, which is responsible for ingesting logs from various sources and forwarding them to the ServiceRadar platform.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

# Install the binary (assumes binary is built at /src/cmd/flowgger/target/release/serviceradar-flowgger)
install -m 755 %{_builddir}/serviceradar-flowgger %{buildroot}/usr/local/bin/

# Install systemd service and config files from packaging directory
install -m 644 %{_sourcedir}/flowgger/systemd/serviceradar-flowgger.service %{buildroot}/lib/systemd/system/
install -m 644 %{_sourcedir}/flowgger/config/flowgger.toml %{buildroot}/etc/serviceradar/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-flowgger
%config(noreplace) %attr(0644, serviceradar, serviceradar) /etc/serviceradar/flowgger.toml
%attr(0644, root, root) /lib/systemd/system/serviceradar-flowgger.service
%dir %attr(0755, root, root) /etc/serviceradar

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
%systemd_post serviceradar-flowgger.service
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-flowgger

%preun
%systemd_preun serviceradar-flowgger.service

%postun
%systemd_postun_with_restart serviceradar-flowgger.service
