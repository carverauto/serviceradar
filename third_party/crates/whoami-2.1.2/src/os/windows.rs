use std::{
    ffi::{c_char, c_int, c_uchar, c_ulong, c_ushort, c_void, OsString},
    io::{self, ErrorKind},
    mem::{self, MaybeUninit},
    os::windows::ffi::OsStringExt,
    prelude::rust_2021::*,
    ptr,
    str::FromStr,
};

use crate::{
    conversions,
    os::{Os, Target},
    CpuArchitecture, DesktopEnvironment, Error, Language, LanguagePreferences,
    Platform, Result,
};

#[repr(C)]
struct OsVersionInfoEx {
    os_version_info_size: c_ulong,
    major_version: c_ulong,
    minor_version: c_ulong,
    build_number: c_ulong,
    platform_id: c_ulong,
    sz_csd_version: [u16; 128],
    service_pack_major: c_ushort,
    service_pack_minor: c_ushort,
    suite_mask: c_ushort,
    product_type: c_uchar,
    reserved: c_uchar,
}

// Source:
// https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-system_info#syntax
#[repr(C)]
struct SystemInfo {
    processor_architecture: c_ushort,
    reserved: c_ushort,
    dw_page_size: c_ulong,
    minimum_application_address: *mut c_void,
    maximum_application_address: *mut c_void,
    active_processor_mask: usize,
    number_of_processors: c_ulong,
    processor_type: c_ulong,
    allocation_granularity: c_ulong,
    processor_level: c_ushort,
    processor_revision: c_ushort,
}

#[allow(unused)]
#[repr(C)]
#[derive(Copy, Clone)]
enum ExtendedNameFormat {
    Unknown = 0,           // Nothing
    FullyQualifiedDN = 1,  // Nothing
    SamCompatible = 2,     // Hostname Followed By Username
    Display = 3,           // Full Name
    UniqueId = 6,          // Nothing
    Canonical = 7,         // Nothing
    UserPrincipal = 8,     // Nothing
    CanonicalEx = 9,       // Nothing
    ServicePrincipal = 10, // Nothing
    DnsDomain = 12,        // Nothing
    GivenName = 13,        // Nothing
    Surname = 14,          // Nothing
}

#[allow(unused)]
#[repr(C)]
enum ComputerNameFormat {
    NetBIOS,                   // All caps hostname
    DnsHostname,               // Hostname
    DnsDomain,                 // Nothing or domain
    DnsFullyQualified,         // Hostname with, for example, .com
    PhysicalNetBIOS,           // All caps name
    PhysicalDnsHostname,       // Hostname
    PhysicalDnsDomain,         // Nothing or domain
    PhysicalDnsFullyQualified, // Hostname with, for example, .com
    Max,
}

const ERR_MORE_DATA: i32 = 0xEA;
const ERR_INSUFFICIENT_BUFFER: i32 = 0x7A;
const ERR_NONE_MAPPED: i32 = 0x534;

#[link(name = "secur32")]
extern "system" {
    fn GetUserNameExW(
        a: ExtendedNameFormat,
        b: *mut c_char,
        c: *mut c_ulong,
    ) -> c_uchar;
}

#[link(name = "advapi32")]
extern "system" {
    fn GetUserNameW(a: *mut c_char, b: *mut c_ulong) -> c_int;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetUserPreferredUILanguages(
        dw_flags: c_ulong,
        pul_num_languages: *mut c_ulong,
        pwsz_languages_buffer: *mut u16,
        pcch_languages_buffer: *mut c_ulong,
    ) -> c_int;
    fn GetNativeSystemInfo(system_info: *mut SystemInfo);
    fn GetComputerNameExW(
        a: ComputerNameFormat,
        b: *mut c_char,
        c: *mut c_ulong,
    ) -> c_int;
}

fn username() -> Result<OsString> {
    // Step 1. Retreive the entire length of the username
    let mut size = 0;
    let fail = unsafe { GetUserNameW(ptr::null_mut(), &mut size) == 0 };
    assert!(fail);

    if io::Error::last_os_error().raw_os_error()
        != Some(ERR_INSUFFICIENT_BUFFER)
    {
        return Err(Error::from_io(io::Error::last_os_error()));
    }

    // Step 2. Allocate memory to put the Windows (UTF-16) string.
    let mut name: Vec<u16> =
        Vec::with_capacity(size.try_into().unwrap_or(usize::MAX));
    size = name.capacity().try_into().unwrap_or(u32::MAX);
    let orig_size = size;
    let fail =
        unsafe { GetUserNameW(name.as_mut_ptr().cast(), &mut size) == 0 };
    if fail {
        return Err(Error::from_io(io::Error::last_os_error()));
    }
    debug_assert_eq!(orig_size, size);
    unsafe {
        name.set_len(size.try_into().unwrap_or(usize::MAX));
    }
    let terminator = name.pop(); // Remove Trailing Null
    debug_assert_eq!(terminator, Some(0u16));

    // Step 3. Convert to Rust String
    Ok(OsString::from_wide(&name))
}

fn extended_name(format: ExtendedNameFormat) -> Result<OsString> {
    // Step 1. Retrieve the entire length of the username
    let mut buf_size = 0;
    let fail =
        unsafe { GetUserNameExW(format, ptr::null_mut(), &mut buf_size) == 0 };

    assert!(fail);

    let last_err = io::Error::last_os_error().raw_os_error();

    if last_err == Some(ERR_NONE_MAPPED) {
        return Err(Error::missing_record());
    }

    if last_err != Some(ERR_MORE_DATA) {
        return Err(Error::from_io(io::Error::last_os_error()));
    }

    // Step 2. Allocate memory to put the Windows (UTF-16) string.
    let mut name: Vec<u16> =
        Vec::with_capacity(buf_size.try_into().unwrap_or(usize::MAX));
    let mut name_len = name.capacity().try_into().unwrap_or(u32::MAX);
    let fail = unsafe {
        GetUserNameExW(format, name.as_mut_ptr().cast(), &mut name_len) == 0
    };
    if fail {
        return Err(Error::from_io(io::Error::last_os_error()));
    }

    assert_eq!(buf_size, name_len + 1);

    unsafe { name.set_len(name_len.try_into().unwrap_or(usize::MAX)) };

    // Step 3. Convert to Rust String
    Ok(OsString::from_wide(&name))
}

impl Target for Os {
    #[inline(always)]
    fn lang_prefs(self) -> Result<LanguagePreferences> {
        let mut num_languages = 0;
        let mut buffer_size = 0;
        let mut buffer;

        unsafe {
            assert_ne!(
                GetUserPreferredUILanguages(
                    0x08, /* MUI_LANGUAGE_NAME */
                    &mut num_languages,
                    ptr::null_mut(), // List of languages.
                    &mut buffer_size,
                ),
                0
            );

            buffer = Vec::with_capacity(buffer_size as usize);

            assert_ne!(
                GetUserPreferredUILanguages(
                    0x08, /* MUI_LANGUAGE_NAME */
                    &mut num_languages,
                    buffer.as_mut_ptr(), // List of languages.
                    &mut buffer_size,
                ),
                0
            );

            buffer.set_len(buffer_size as usize);
        }

        // We know it ends in two null characters.
        buffer.pop();
        buffer.pop();

        // Combine into a single string
        Ok(LanguagePreferences {
            fallbacks: String::from_utf16_lossy(&buffer)
                .split('\0')
                .map(Language::from_str)
                .collect::<Result<Vec<Language>>>()?,
            ..Default::default()
        })
    }

    fn realname(self) -> Result<OsString> {
        extended_name(ExtendedNameFormat::Display)
    }

    fn username(self) -> Result<OsString> {
        username()
    }

    fn devicename(self) -> Result<OsString> {
        // Step 1. Retreive the entire length of the device name
        let mut size = 0;
        let fail = unsafe {
            // Ignore error, we know that it will be ERROR_INSUFFICIENT_BUFFER
            GetComputerNameExW(
                ComputerNameFormat::DnsHostname,
                ptr::null_mut(),
                &mut size,
            ) == 0
        };

        assert!(fail);

        if io::Error::last_os_error().raw_os_error() != Some(ERR_MORE_DATA) {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        // Step 2. Allocate memory to put the Windows (UTF-16) string.
        let mut name: Vec<u16> =
            Vec::with_capacity(size.try_into().unwrap_or(usize::MAX));
        let mut size = name.capacity().try_into().unwrap_or(u32::MAX);

        if unsafe {
            GetComputerNameExW(
                ComputerNameFormat::DnsHostname,
                name.as_mut_ptr().cast(),
                &mut size,
            ) == 0
        } {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        unsafe {
            name.set_len(size.try_into().unwrap_or(usize::MAX));
        }

        // Step 3. Convert to Rust String
        Ok(OsString::from_wide(&name))
    }

    fn hostname(self) -> Result<String> {
        // Step 1. Retreive the entire length of the username
        let mut size = 0;
        let fail = unsafe {
            // Ignore error, we know that it will be ERROR_INSUFFICIENT_BUFFER
            GetComputerNameExW(
                ComputerNameFormat::PhysicalDnsHostname,
                ptr::null_mut(),
                &mut size,
            ) == 0
        };

        assert!(fail);

        if io::Error::last_os_error().raw_os_error() != Some(ERR_MORE_DATA) {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        // Step 2. Allocate memory to put the Windows (UTF-16) string.
        let mut name: Vec<u16> =
            Vec::with_capacity(size.try_into().unwrap_or(usize::MAX));
        let mut size = name.capacity().try_into().unwrap_or(u32::MAX);

        if unsafe {
            GetComputerNameExW(
                ComputerNameFormat::PhysicalDnsHostname,
                name.as_mut_ptr().cast(),
                &mut size,
            ) == 0
        } {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        unsafe {
            name.set_len(size.try_into().unwrap_or(usize::MAX));
        }

        // Step 3. Convert to Rust String
        conversions::string_from_os(OsString::from_wide(&name))
    }

    fn distro(self) -> Result<String> {
        // Due to MingW Limitations, we must dynamically load ntdll.dll
        extern "system" {
            fn LoadLibraryExW(
                filename: *const u16,
                hfile: *mut c_void,
                dwflags: c_ulong,
            ) -> *mut c_void;
            fn FreeLibrary(hmodule: *mut c_void) -> i32;
            fn GetProcAddress(
                hmodule: *mut c_void,
                procname: *const c_char,
            ) -> *mut c_void;
        }

        let mut path = "ntdll.dll\0".encode_utf16().collect::<Vec<u16>>();
        let path = path.as_mut_ptr();

        let inst =
            unsafe { LoadLibraryExW(path, ptr::null_mut(), 0x0000_0800) };

        if inst.is_null() {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        let mut path = "RtlGetVersion\0".bytes().collect::<Vec<u8>>();
        let path = path.as_mut_ptr().cast();
        let func = unsafe { GetProcAddress(inst, path) };

        if func.is_null() {
            if unsafe { FreeLibrary(inst) } == 0 {
                return Err(Error::from_io(io::Error::last_os_error()));
            }

            return Err(Error::from_io(io::Error::last_os_error()));
        }

        let get_version: unsafe extern "system" fn(
            a: *mut OsVersionInfoEx,
        ) -> u32 = unsafe { mem::transmute(func) };

        let mut version = MaybeUninit::<OsVersionInfoEx>::zeroed();

        // FIXME `mem::size_of` seemingly false positive for lint
        #[allow(unused_qualifications)]
        let version = unsafe {
            (*version.as_mut_ptr()).os_version_info_size =
                mem::size_of::<OsVersionInfoEx>() as u32;
            get_version(version.as_mut_ptr());

            if FreeLibrary(inst) == 0 {
                return Err(Error::from_io(io::Error::last_os_error()));
            }

            version.assume_init()
        };

        let product = match version.product_type {
            1 => "Workstation",
            2 => "Domain Controller",
            3 => "Server",
            _ => "Unknown",
        };

        if version.major_version >= 10 && version.build_number > 22000 {
            Ok(alloc::format!(
                "Windows 11 ({}.{}.{}) ({})",
                version.major_version,
                version.minor_version,
                version.build_number,
                product,
            ))
        } else {
            Ok(alloc::format!(
                "Windows {}.{}.{} ({})",
                version.major_version,
                version.minor_version,
                version.build_number,
                product,
            ))
        }
    }

    #[inline(always)]
    fn desktop_env(self) -> Option<DesktopEnvironment> {
        Some(DesktopEnvironment::Windows)
    }

    #[inline(always)]
    fn platform(self) -> Platform {
        Platform::Windows
    }

    #[inline(always)]
    fn arch(self) -> Result<CpuArchitecture> {
        fn proc(processor_type: c_ulong) -> Result<CpuArchitecture, c_ulong> {
            Ok(match processor_type {
                // PROCESSOR_INTEL_386
                386 => CpuArchitecture::I386,
                // PROCESSOR_INTEL_486
                486 => CpuArchitecture::Unknown("I486".to_string()),
                // PROCESSOR_INTEL_PENTIUM
                586 => CpuArchitecture::I586,
                // PROCESSOR_INTEL_IA64
                2200 => CpuArchitecture::Unknown("IA64".to_string()),
                // PROCESSOR_AMD_X8664
                8664 => CpuArchitecture::X64,
                v => return Err(v),
            })
        }

        let buf: SystemInfo = unsafe {
            let mut buf = MaybeUninit::uninit();
            GetNativeSystemInfo(buf.as_mut_ptr());
            buf.assume_init()
        };

        // Supported architectures, source:
        // https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-system_info#members
        Ok(match buf.processor_architecture {
            // PROCESSOR_ARCHITECTURE_INTEL
            0 => CpuArchitecture::I686,
            // PROCESSOR_ARCHITECTURE_ARM
            5 => CpuArchitecture::ArmV6,
            // PROCESSOR_ARCHITECTURE_IA64
            6 => CpuArchitecture::Unknown("IA64".to_string()),
            // PROCESSOR_ARCHITECTURE_AMD64
            9 => CpuArchitecture::X64,
            // PROCESSOR_ARCHITECTURE_ARM64
            12 => CpuArchitecture::Arm64,
            // PROCESSOR_ARCHITECTURE_UNKNOWN
            0xFFFF => proc(buf.processor_type).map_err(|e| {
                Error::from_io(io::Error::new(
                    ErrorKind::InvalidData,
                    alloc::format!("Unknown arch: {e}"),
                ))
            })?,
            invalid => proc(buf.processor_type).map_err(|e| {
                Error::from_io(io::Error::new(
                    ErrorKind::InvalidData,
                    alloc::format!("Invalid arch: {invalid}/{e}"),
                ))
            })?,
        })
    }

    #[inline(always)]
    fn account(self) -> Result<OsString> {
        match extended_name(ExtendedNameFormat::UserPrincipal)
            .map_err(io::Error::from)
        {
            Ok(name) => Ok(name),
            Err(e) if e.kind() == ErrorKind::NotFound => username(),
            Err(e) => Err(Error::from_io(e)),
        }
    }
}
