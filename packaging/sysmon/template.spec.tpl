# -*- rpm-spec -*-

# This comprises the entirety of the preamble
%include %build_rpm_options

# Disable automatic dependency detection for the ZFS binary
# The -zfs binary has optional runtime dependencies on libzfs_core and libnvpair
# which are only needed if ZFS is installed on the target system
AutoReq: no
AutoProv: no

%description
%include %build_rpm_description

%install
%include %build_rpm_install

%files -f %build_rpm_files

${PRE_SCRIPTLET}

${POST_SCRIPTLET}

${PREUN_SCRIPTLET}

${POSTUN_SCRIPTLET}

${POSTTRANS_SCRIPTLET}

${SUBRPMS}

${CHANGELOG}
