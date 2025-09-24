Name:           serviceradar-kong
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ServiceRadar Kong Gateway bundle
License:        Proprietary

BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       ca-certificates
Requires:       serviceradar-cli
%{?systemd_requires}

%description
Distributes Kong Gateway Enterprise artifacts and helpers for ServiceRadar air-gapped deployments.
Installs bundled Kong packages into a vendor directory and runs a post-install script to install the
appropriate Kong RPM on target systems, alongside default DB-less configuration.

%prep
# No sources to untar

%install
mkdir -p %{buildroot}/usr/share/serviceradar-kong/vendor
mkdir -p %{buildroot}/usr/share/serviceradar-kong/scripts
mkdir -p %{buildroot}/etc/kong

# Copy optional configuration if provided
if [ -f %{_sourcedir}/packaging/kong/config/kong.conf ]; then
  install -m 644 %{_sourcedir}/packaging/kong/config/kong.conf %{buildroot}/etc/kong/kong.conf
fi

# Install helper scripts
install -m 755 %{_sourcedir}/packaging/kong/scripts/postinstall.sh \
  %{buildroot}/usr/share/serviceradar-kong/scripts/postinstall.sh
install -m 755 %{_sourcedir}/packaging/kong/scripts/preremove.sh \
  %{buildroot}/usr/share/serviceradar-kong/scripts/preremove.sh

# Copy any bundled vendor artifacts that are present
for artifact in \
  %{_sourcedir}/packaging/kong/vendor/kong-enterprise-edition-*.rpm \
  %{_sourcedir}/packaging/kong/vendor/kong-enterprise-edition_*.deb \
  %{_sourcedir}/packaging/kong/vendor/kong-*.rpm \
  %{_sourcedir}/packaging/kong/vendor/kong-*.deb; do
  if [ -f "$artifact" ]; then
    install -m 644 "$artifact" %{buildroot}/usr/share/serviceradar-kong/vendor/
  fi
done

touch %{buildroot}/usr/share/serviceradar-kong/vendor/.keep

# Track vendor artifacts dynamically for %files
find %{buildroot}/usr/share/serviceradar-kong/vendor -type f \
  | sed "s|%{buildroot}||" > %{_builddir}/vendor-files.lst
if [ ! -s %{_builddir}/vendor-files.lst ]; then
  : > %{_builddir}/vendor-files.lst
fi

%files -f %{_builddir}/vendor-files.lst
%attr(0755, root, root) /usr/share/serviceradar-kong/scripts/postinstall.sh
%attr(0755, root, root) /usr/share/serviceradar-kong/scripts/preremove.sh
%dir %attr(0755, root, root) /usr/share/serviceradar-kong
%dir %attr(0755, root, root) /usr/share/serviceradar-kong/scripts
%dir %attr(0755, root, root) /usr/share/serviceradar-kong/vendor
%dir %attr(0755, root, root) /etc/kong
%config(noreplace) %attr(0644, root, root) /etc/kong/kong.conf

%post
/usr/share/serviceradar-kong/scripts/postinstall.sh || true

%preun
if [ $1 -eq 0 ]; then
  /usr/share/serviceradar-kong/scripts/preremove.sh || true
fi

%postun
# Nothing additional
:
