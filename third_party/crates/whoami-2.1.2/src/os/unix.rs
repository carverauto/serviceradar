use std::{
    borrow::Cow,
    ffi::{CStr, OsString},
    fs, io, mem,
    os::unix::ffi::OsStringExt,
    prelude::rust_2021::*,
    slice,
};

use crate::{
    os::{Os, Target},
    CpuArchitecture, DesktopEnvironment, Error, LanguagePreferences, Platform,
    Result,
};

enum Name {
    User,
    Real,
}

trait Terminators {
    const CHARS: &'static [u8];
}

struct Nul;

struct NulOrComma;

impl Terminators for Nul {
    const CHARS: &'static [u8] = b"\0";
}

impl Terminators for NulOrComma {
    const CHARS: &'static [u8] = b"\0,";
}

unsafe fn strlen<T>(mut cs: *const u8) -> usize
where
    T: Terminators,
{
    let mut len = 0;

    while !T::CHARS.contains(&*cs) {
        len += 1;
        cs = cs.offset(1);
    }

    len
}

fn os_from_cstring<T>(string: *const u8) -> Result<OsString>
where
    T: Terminators,
{
    if string.is_null() {
        return Err(Error::null_record());
    }

    // Get a byte slice of the c string.
    let slice = unsafe {
        let length = strlen::<T>(string);

        if length == 0 {
            return Err(Error::empty_record());
        }

        slice::from_raw_parts(string, length)
    };

    // Turn byte slice into Rust String.
    Ok(OsString::from_vec(slice.to_vec()))
}

// This function must allocate, because a slice or `Cow<OsStr>` would still
// reference `passwd` which is dropped when this function returns.
#[inline(always)]
fn getpwuid(name: Name) -> Result<OsString> {
    const BUF_SIZE: usize = 16_384; // size from the man page
    let mut buffer = mem::MaybeUninit::<[u8; BUF_SIZE]>::uninit();
    let mut passwd = mem::MaybeUninit::<libc::passwd>::uninit();

    // Get passwd `struct`.
    let passwd = unsafe {
        let mut _passwd = mem::MaybeUninit::<*mut libc::passwd>::uninit();
        let ret = libc::getpwuid_r(
            libc::geteuid(),
            passwd.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            BUF_SIZE,
            _passwd.as_mut_ptr(),
        );

        if ret != 0 {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        let _passwd = _passwd.assume_init();

        if _passwd.is_null() {
            return Err(Error::null_record());
        }

        passwd.assume_init()
    };

    // Extract names.
    if let Name::Real = name {
        os_from_cstring::<NulOrComma>(passwd.pw_gecos.cast())
    } else {
        os_from_cstring::<Nul>(passwd.pw_name.cast())
    }
}

impl Target for Os {
    fn lang_prefs(self) -> Result<LanguagePreferences> {
        super::unix_lang()
    }

    fn realname(self) -> Result<OsString> {
        getpwuid(Name::Real)
    }

    fn username(self) -> Result<OsString> {
        getpwuid(Name::User)
    }

    fn devicename(self) -> Result<OsString> {
        #[cfg(target_vendor = "apple")]
        {
            use std::ptr::null_mut;

            use objc2_system_configuration::SCDynamicStore;

            let Some(name) =
                (unsafe { SCDynamicStore::computer_name(None, null_mut()) })
            else {
                return Err(Error::missing_record());
            };
            // this should be able to convert whichever encoding is being used
            // to UTF-8, so we shouldn't have to worry about invalid codepoints.
            let name = name.to_string();

            if name.is_empty() {
                return Err(Error::empty_record());
            }

            Ok(name.into())
        }

        #[cfg(target_os = "illumos")]
        {
            let mut nodename =
                fs::read("/etc/nodename").map_err(Error::from_io)?;

            // Remove all at and after the first newline (before end of file)
            if let Some(slice) = nodename.split(|x| *x == b'\n').next() {
                nodename.drain(slice.len()..);
            }

            if nodename.is_empty() {
                return Err(Error::empty_record());
            }

            Ok(OsString::from_vec(nodename))
        }

        #[cfg(any(
            target_os = "linux",
            target_os = "dragonfly",
            target_os = "freebsd",
            target_os = "netbsd",
            target_os = "openbsd",
            target_os = "hurd",
        ))]
        {
            let machine_info =
                fs::read("/etc/machine-info").map_err(Error::from_io)?;

            for i in machine_info.split(|b| *b == b'\n') {
                let mut j = i.split(|b| *b == b'=');

                if j.next() == Some(b"PRETTY_HOSTNAME") {
                    let pretty_hostname = j
                        .next()
                        .ok_or(Error::with_invalid_data("parsing failed"))?;
                    let pretty_hostname = pretty_hostname
                        .strip_prefix(b"\"")
                        .unwrap_or(pretty_hostname)
                        .strip_suffix(b"\"")
                        .unwrap_or(pretty_hostname);
                    let pretty_hostname = {
                        let mut vec = Vec::with_capacity(pretty_hostname.len());
                        let mut pretty_hostname = pretty_hostname.iter();

                        while let Some(&c) = pretty_hostname.next() {
                            if c == b'\\' {
                                vec.push(match pretty_hostname.next() {
                                    Some(b'\\') => b'\\',
                                    Some(b't') => b'\t',
                                    Some(b'r') => b'\r',
                                    Some(b'n') => b'\n',
                                    Some(b'\'') => b'\'',
                                    Some(b'"') => b'"',
                                    _ => {
                                        return Err(Error::with_invalid_data(
                                            "parsing failed",
                                        ));
                                    }
                                });
                            } else {
                                vec.push(c);
                            }
                        }

                        vec
                    };

                    return Ok(OsString::from_vec(pretty_hostname));
                }
            }

            Err(Error::missing_record())
        }
    }

    fn hostname(self) -> Result<String> {
        // Maximum hostname length = 255, plus a NULL byte.
        let mut string = Vec::<u8>::with_capacity(256);

        unsafe {
            if libc::gethostname(string.as_mut_ptr().cast(), 255) == -1 {
                return Err(Error::from_io(io::Error::last_os_error()));
            }

            string.set_len(strlen::<Nul>(string.as_ptr().cast()));
        };

        String::from_utf8(string)
            .map_err(|_| Error::with_invalid_data("Hostname not valid UTF-8"))
    }

    fn distro(self) -> Result<String> {
        #[cfg(target_vendor = "apple")]
        {
            fn distro_xml(data: String) -> Result<String> {
                let mut product_name = None;
                let mut user_visible_version = None;

                if let Some(start) = data.find("<dict>") {
                    if let Some(end) = data.find("</dict>") {
                        let mut set_product_name = false;
                        let mut set_user_visible_version = false;

                        for line in data[start + "<dict>".len()..end].lines() {
                            let line = line.trim();

                            if let Some(key) = line.strip_prefix("<key>") {
                                match key.trim_end_matches("</key>") {
                                    "ProductName" => set_product_name = true,
                                    "ProductUserVisibleVersion" => {
                                        set_user_visible_version = true
                                    }
                                    "ProductVersion"
                                        if user_visible_version.is_none() =>
                                    {
                                        set_user_visible_version = true
                                    }
                                    _ => {}
                                }
                            } else if let Some(value) =
                                line.strip_prefix("<string>")
                            {
                                if set_product_name {
                                    product_name = Some(
                                        value.trim_end_matches("</string>"),
                                    );
                                    set_product_name = false;
                                } else if set_user_visible_version {
                                    user_visible_version = Some(
                                        value.trim_end_matches("</string>"),
                                    );
                                    set_user_visible_version = false;
                                }
                            }
                        }
                    }
                }

                Ok(if let Some(product_name) = product_name {
                    if let Some(user_visible_version) = user_visible_version {
                        std::format!("{product_name} {user_visible_version}")
                    } else {
                        product_name.to_string()
                    }
                } else {
                    user_visible_version
                        .map(|v| std::format!("Mac OS (Unknown) {v}"))
                        .ok_or_else(|| {
                            Error::with_invalid_data("Parsing failed")
                        })?
                })
            }

            if let Ok(data) = fs::read_to_string(
                "/System/Library/CoreServices/ServerVersion.plist",
            ) {
                distro_xml(data)
            } else if let Ok(data) = fs::read_to_string(
                "/System/Library/CoreServices/SystemVersion.plist",
            ) {
                distro_xml(data)
            } else {
                Err(Error::missing_record())
            }
        }

        #[cfg(not(target_vendor = "apple"))]
        {
            let program =
                fs::read("/etc/os-release").map_err(Error::from_io)?;
            let distro = String::from_utf8_lossy(&program);
            let err = || Error::with_invalid_data("Parsing failed");
            let mut fallback = None;

            for i in distro.split('\n') {
                let mut j = i.split('=');

                match j.next().ok_or_else(err)? {
                    "PRETTY_NAME" => {
                        return Ok(j
                            .next()
                            .ok_or_else(err)?
                            .trim_matches('"')
                            .to_string());
                    }
                    "NAME" => {
                        fallback = Some(
                            j.next()
                                .ok_or_else(err)?
                                .trim_matches('"')
                                .to_string(),
                        )
                    }
                    _ => {}
                }
            }

            fallback.ok_or_else(err)
        }
    }

    fn desktop_env(self) -> Option<DesktopEnvironment> {
        #[cfg(target_vendor = "apple")]
        let env: Cow<'static, str> = "Aqua".into();

        #[cfg(not(target_vendor = "apple"))]
        let env: Cow<'static, str> = std::env::var_os("XDG_SESSION_DESKTOP")
            .or_else(|| std::env::var_os("DESKTOP_SESSION"))
            .or_else(|| std::env::var_os("XDG_CURRENT_DESKTOP"))?
            .into_string()
            .unwrap_or_else(|e| e.to_string_lossy().into_owned())
            .into();

        Some(if env.eq_ignore_ascii_case("AQUA") {
            DesktopEnvironment::Aqua
        } else if env.eq_ignore_ascii_case("GNOME") {
            DesktopEnvironment::Gnome
        } else if env.eq_ignore_ascii_case("LXDE") {
            DesktopEnvironment::Lxde
        } else if env.eq_ignore_ascii_case("OPENBOX") {
            DesktopEnvironment::Openbox
        } else if env.eq_ignore_ascii_case("I3") {
            DesktopEnvironment::I3
        } else if env.eq_ignore_ascii_case("UBUNTU") {
            DesktopEnvironment::Ubuntu
        } else if env.eq_ignore_ascii_case("PLASMA5") {
            DesktopEnvironment::Plasma
        } else if env.eq_ignore_ascii_case("XFCE") {
            DesktopEnvironment::Xfce
        } else if env.eq_ignore_ascii_case("NIRI") {
            DesktopEnvironment::Niri
        } else if env.eq_ignore_ascii_case("HYPRLAND") {
            DesktopEnvironment::Hyprland
        } else if env.eq_ignore_ascii_case("COSMIC") {
            DesktopEnvironment::Cosmic
        } else {
            DesktopEnvironment::Unknown(env.to_string())
        })
    }

    #[inline(always)]
    fn platform(self) -> Platform {
        #[cfg(target_os = "linux")]
        {
            Platform::Linux
        }

        #[cfg(target_vendor = "apple")]
        {
            Platform::Mac
        }

        #[cfg(any(
            target_os = "dragonfly",
            target_os = "freebsd",
            target_os = "netbsd",
            target_os = "openbsd",
        ))]
        {
            Platform::Bsd
        }

        #[cfg(target_os = "illumos")]
        {
            Platform::Illumos
        }

        #[cfg(target_os = "hurd")]
        {
            Platform::Hurd
        }
    }

    #[inline(always)]
    fn arch(self) -> Result<CpuArchitecture> {
        let mut buf: libc::utsname = unsafe { mem::zeroed() };

        if unsafe { libc::uname(&mut buf) } == -1 {
            return Err(Error::from_io(io::Error::last_os_error()));
        }

        let arch_str =
            unsafe { CStr::from_ptr(buf.machine.as_ptr()) }.to_string_lossy();

        Ok(match arch_str.as_ref() {
            "aarch64" | "arm64" | "aarch64_be" | "armv8b" | "armv8l" => {
                CpuArchitecture::Arm64
            }
            "armv5" => CpuArchitecture::ArmV5,
            "armv6" | "arm" => CpuArchitecture::ArmV6,
            "armv7" => CpuArchitecture::ArmV7,
            "i386" => CpuArchitecture::I386,
            "i586" => CpuArchitecture::I586,
            "i686" | "i686-AT386" => CpuArchitecture::I686,
            "mips" => CpuArchitecture::Mips,
            "mipsel" => CpuArchitecture::MipsEl,
            "mips64" => CpuArchitecture::Mips64,
            "mips64el" => CpuArchitecture::Mips64El,
            "powerpc" | "ppc" | "ppcle" => CpuArchitecture::PowerPc,
            "powerpc64" | "ppc64" | "ppc64le" => CpuArchitecture::PowerPc64,
            "powerpc64le" => CpuArchitecture::PowerPc64Le,
            "riscv32" => CpuArchitecture::Riscv32,
            "riscv64" => CpuArchitecture::Riscv64,
            "s390x" => CpuArchitecture::S390x,
            "sparc" => CpuArchitecture::Sparc,
            "sparc64" => CpuArchitecture::Sparc64,
            "x86_64" | "amd64" | "i86pc" => CpuArchitecture::X64,
            _ => CpuArchitecture::Unknown(arch_str.into_owned()),
        })
    }
}
