//! Unknown target, fake implementation.
//!
//! This can be used as a template when adding new target support.

use alloc::string::{String, ToString};

use crate::{
    os::{Os, Target},
    CpuArchitecture, DesktopEnvironment, Language, LanguagePreferences,
    OsString, Platform, Result,
};

impl Target for Os {
    #[inline(always)]
    fn lang_prefs(self) -> Result<LanguagePreferences> {
        Ok(LanguagePreferences {
            fallbacks: [Language::default()].to_vec(),
            ..Default::default()
        })
    }

    #[inline(always)]
    fn realname(self) -> Result<OsString> {
        Ok(OsString::from("Anonymous"))
    }

    #[inline(always)]
    fn username(self) -> Result<OsString> {
        Ok(OsString::from("anonymous"))
    }

    #[inline(always)]
    fn devicename(self) -> Result<OsString> {
        Ok(OsString::from("Unknown"))
    }

    #[inline(always)]
    fn hostname(self) -> Result<String> {
        Ok(String::from("localhost"))
    }

    #[inline(always)]
    fn distro(self) -> Result<String> {
        Ok(alloc::format!("Unknown {}", self.platform()))
    }

    #[inline(always)]
    fn desktop_env(self) -> Option<DesktopEnvironment> {
        None
    }

    #[inline(always)]
    fn platform(self) -> Platform {
        if cfg!(daku) {
            Platform::Unknown("Daku".to_string())
        } else if cfg!(target_os = "wasi") {
            Platform::Unknown("WASI".to_string())
        } else if cfg!(target_os = "windows") {
            Platform::Windows
        } else if cfg!(target_os = "macos") {
            Platform::Mac
        } else if cfg!(target_os = "redox") {
            Platform::Redox
        } else if cfg!(target_os = "linux") {
            Platform::Linux
        } else if cfg!(target_os = "android") {
            Platform::Android
        } else if cfg!(target_os = "tvos") {
            Platform::Unknown("tvOS".to_string())
        } else if cfg!(target_os = "watchos") {
            Platform::Unknown("watchOS".to_string())
        } else if cfg!(target_os = "ios") {
            Platform::Unknown("iOS".to_string())
        } else if cfg!(target_os = "fuchsia") {
            Platform::Fuchsia
        } else if cfg!(target_os = "illumos") {
            Platform::Illumos
        } else if cfg!(any(
            target_os = "dragonfly",
            target_os = "freebsd",
            target_os = "netbsd",
            target_os = "openbsd",
        )) {
            Platform::Bsd
        } else if cfg!(target_os = "haiku") {
            Platform::Unknown("Haiku".to_string())
        } else if cfg!(target_os = "vxworks") {
            Platform::Unknown("VxWorks".to_string())
        } else if cfg!(target_os = "nto") {
            Platform::Unknown("QNX Neutrino".to_string())
        } else if cfg!(target_os = "horizon") {
            Platform::Nintendo3ds
        } else if cfg!(target_os = "vita") {
            Platform::PlayStation
        } else if cfg!(target_os = "hurd") {
            Platform::Hurd
        } else if cfg!(target_os = "aix") {
            Platform::Unknown("AIX OS".to_string())
        } else if cfg!(target_os = "espidf") {
            Platform::Unknown("ESP-IDF".to_string())
        } else if cfg!(target_os = "emscripten") {
            Platform::Unknown("Emscripten".to_string())
        } else if cfg!(target_os = "solaris") {
            Platform::Unknown("Solaris".to_string())
        } else if cfg!(target_os = "l4re") {
            Platform::Unknown("L4 Runtime Environment".to_string())
        } else {
            Platform::Unknown("Unknown".to_string())
        }
    }

    #[inline(always)]
    fn arch(self) -> Result<CpuArchitecture> {
        #[cfg(target_pointer_width = "32")]
        {
            Ok(CpuArchitecture::Wasm32)
        }

        #[cfg(target_pointer_width = "64")]
        {
            Ok(CpuArchitecture::Wasm64)
        }
    }
}
