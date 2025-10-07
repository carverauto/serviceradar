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
chown -R serviceradar:serviceradar /usr/local/bin/serviceradar-cli
chmod 755 /usr/local/bin/serviceradar-cli