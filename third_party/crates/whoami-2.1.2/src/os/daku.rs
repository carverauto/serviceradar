//! Daku - mostly the same as stub.rs for now.

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
        Ok("localhost".to_string())
    }

    #[inline(always)]
    fn distro(self) -> Result<String> {
        Ok(alloc::format!("Daku {}", self.platform()))
    }

    #[inline(always)]
    fn desktop_env(self) -> Option<DesktopEnvironment> {
        None
    }

    #[inline(always)]
    fn platform(self) -> Platform {
        Platform::Unknown("Emulated".to_string())
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
