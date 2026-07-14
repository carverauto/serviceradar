#[cfg(not(any(target_pointer_width = "32", target_pointer_width = "64")))]
compile_error!("Unexpected pointer width for target platform");

use alloc::{
    string::{String, ToString},
    vec::Vec,
};
use core::str::FromStr;

use crate::{
    os::{Os, Target},
    CpuArchitecture, DesktopEnvironment, Language, LanguagePreferences,
    OsString, Platform, Result,
};

impl Target for Os {
    fn lang_prefs(self) -> Result<LanguagePreferences> {
        let langs = wasite::environment().user.langs;
        let fallbacks = langs
            .other()
            .map(Language::from_str)
            .collect::<Result<Vec<Language>>>()?;
        let collation = langs
            .collation()
            .next()
            .map(Language::from_str)
            .transpose()?;
        let char_classes = langs
            .char_class()
            .next()
            .map(Language::from_str)
            .transpose()?;
        let monetary = langs
            .monetary()
            .next()
            .map(Language::from_str)
            .transpose()?;
        let messages =
            langs.message().next().map(Language::from_str).transpose()?;
        let numeric =
            langs.numeric().next().map(Language::from_str).transpose()?;
        let time = langs.time().next().map(Language::from_str).transpose()?;

        Ok(LanguagePreferences {
            fallbacks,
            collation,
            char_classes,
            monetary,
            messages,
            numeric,
            time,
        })
    }

    #[inline(always)]
    fn realname(self) -> Result<OsString> {
        self.username()
    }

    #[inline(always)]
    fn username(self) -> Result<OsString> {
        Ok(wasite::environment().user.username.into())
    }

    #[inline(always)]
    fn devicename(self) -> Result<OsString> {
        Ok(wasite::environment().host.name.into())
    }

    #[inline(always)]
    fn hostname(self) -> Result<String> {
        Ok(wasite::environment().host.hostname)
    }

    #[inline(always)]
    fn distro(self) -> Result<String> {
        Ok("Unknown WASI".to_string())
    }

    #[inline(always)]
    fn desktop_env(self) -> Option<DesktopEnvironment> {
        Some(DesktopEnvironment::Unknown("Nucleic".to_string()))
    }

    #[inline(always)]
    fn platform(self) -> Platform {
        Platform::Unknown("WASI".to_string())
    }

    #[inline(always)]
    fn arch(self) -> Result<CpuArchitecture> {
        Ok(if cfg!(target_pointer_width = "64") {
            CpuArchitecture::Wasm64
        } else {
            CpuArchitecture::Wasm32
        })
    }
}
