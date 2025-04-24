Name:           serviceradar-cli
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar CLI tool
License:        Proprietary

%description
ServiceRadar CLI tool, used to manage local-auth.

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/lib/systemd/system
mkdir -p %{buildroot}/etc/serviceradar

install -m 755 %{_builddir}/serviceradar-cli %{buildroot}/usr/local/bin/

%files
%attr(0755, root, root) /usr/local/bin/serviceradar-cli

%pre
# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

%post
chown -R serviceradar:serviceradar /usr/local/bin/serviceradar-cli
chmod 755 /usr/local/bin/serviceradar-cli