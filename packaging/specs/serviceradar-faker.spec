Name:           serviceradar-faker
Version:        %{version}
Release:        1%{?dist}
Summary:        ServiceRadar Fake Armis API Service
License:        Apache-2.0
URL:            https://serviceradar.io
Group:          Applications/System

%description
ServiceRadar Fake Armis API Service simulates the Armis API for testing
ServiceRadar integrations. It includes IP address change simulation to test
duplicate device handling and other edge cases in device discovery.

%prep
# Nothing to prep, binary is already built

%build
# Nothing to build, binary is already built

%install
# Copy files from buildroot
cp -a %{buildroot}/* %{buildroot}/

%files
%defattr(-,root,root,-)
/usr/local/bin/serviceradar-faker
/usr/share/serviceradar/faker/config/faker.json
/usr/share/serviceradar/faker/systemd/serviceradar-faker.service
/usr/share/serviceradar/faker/scripts/postinstall.sh
/usr/share/serviceradar/faker/scripts/preremove.sh
%dir /var/lib/serviceradar/faker
%dir /var/log/serviceradar
%dir /etc/serviceradar

%post
/usr/share/serviceradar/faker/scripts/postinstall.sh

%preun
if [ $1 -eq 0 ]; then
    # This is an uninstall
    /usr/share/serviceradar/faker/scripts/preremove.sh
fi

%postun
if [ $1 -eq 0 ]; then
    # This is an uninstall
    # Clean up any remaining files
    rm -rf /var/lib/serviceradar/faker
    # Don't remove logs - preserve for auditing
fi

%changelog
* Mon Aug 25 2025 ServiceRadar Team <support@serviceradar.io> - 1.0.0-1
- Initial release of ServiceRadar Faker service
- IP address shuffle simulation for testing duplicate device scenarios
- Thread-safe operations with concurrent access support
- Persistent device data storage
- Configurable shuffle interval and percentage