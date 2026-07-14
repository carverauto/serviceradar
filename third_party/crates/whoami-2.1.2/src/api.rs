use alloc::string::String;

use crate::{
    conversions,
    os::{Os, Target},
    CpuArchitecture, DesktopEnvironment, LanguagePreferences, OsString,
    Platform, Result,
};

macro_rules! report_message {
    () => {
        "Please report this issue at https://github.com/ardaku/whoami/issues"
    };
}

/// Get the CPU Architecture.
#[must_use]
#[inline(always)]
pub fn cpu_arch() -> CpuArchitecture {
    Target::arch(Os).expect(concat!("arch() failed.  ", report_message!()))
}

/// Get the user's account name; usually just the username, but may include an
/// account server hostname.
///
/// If you don't want the account server hostname, use [`username()`].
///
/// Example: `username@example.com`
#[inline(always)]
pub fn account() -> Result<String> {
    account_os().and_then(conversions::string_from_os)
}

/// Get the user's account name; usually just the username, but may
/// include an account server hostname.
///
/// If you don't want the account server hostname, use [`username()`].
///
/// Example: `username@example.com`
#[inline(always)]
pub fn account_os() -> Result<OsString> {
    Target::account(Os)
}

/// Get the user's username.
///
/// On unix-systems this differs from [`realname()`] most notably in that spaces
/// are not allowed in the username.
#[inline(always)]
pub fn username() -> Result<String> {
    username_os().and_then(conversions::string_from_os)
}

/// Get the user's username.
///
/// On unix-systems this differs from [`realname_os()`] most notably in that
/// spaces are not allowed in the username.
#[inline(always)]
pub fn username_os() -> Result<OsString> {
    Target::username(Os)
}

/// Get the user's real (full) name.
#[inline(always)]
pub fn realname() -> Result<String> {
    realname_os().and_then(conversions::string_from_os)
}

/// Get the user's real (full) name.
#[inline(always)]
pub fn realname_os() -> Result<OsString> {
    Target::realname(Os)
}

/// Get the host device's hostname.
///
/// Usually hostnames are case-insensitive, but it's not a hard requirement.
///
/// # Platform-Specific Character Limitations
///
/// ## Unix/Linux/BSD
/// - **Maximum length**: 255 bytes (excluding null terminator)
/// - **Encoding**: Must be valid UTF-8
/// - **Characters**: Typically follows RFC 952/1123 DNS hostname rules:
///   - Alphanumeric characters (a-z, A-Z, 0-9)
///   - Hyphens (-), but not at start or end
/// - Note: POSIX allows any character except null and newline, but network
///   hostnames should follow DNS rules for interoperability
///
/// ## Windows
/// - **Maximum length**: 63 characters for DNS hostname (per label)
/// - **Encoding**: UTF-16 (converted to UTF-8 String)
/// - **Characters**: Follows DNS hostname rules (RFC 1123):
///   - Alphanumeric characters (a-z, A-Z, 0-9)
///   - Hyphens (-), but not at start or end
///
/// ## Redox
/// - Reads from `/etc/hostname` file
/// - First line of file is used as hostname
/// - No inherent character limitations beyond file system
///
/// ## Web (WASM)
/// - Returns the document's domain name
/// - Follows DNS hostname rules as enforced by browsers
/// - Must be valid UTF-8
///
/// ## Other Platforms
/// - WASI: Returns system hostname or defaults to "localhost"
/// - Default: Returns "localhost" for unsupported platforms
///
/// # Notes
/// For maximum compatibility across all platforms and network protocols,
/// hostnames should:
/// - Be 63 characters or less
/// - Contain only ASCII alphanumeric characters and hyphens
/// - Not start or end with a hyphen
/// - Be case-insensitive (though case may be preserved)
#[inline(always)]
pub fn hostname() -> Result<String> {
    Target::hostname(Os)
}

/// Get the device name (also known as "Pretty Name").
///
/// Often used to identify device for bluetooth pairing.
#[inline(always)]
pub fn devicename() -> Result<String> {
    devicename_os().and_then(conversions::string_from_os)
}

/// Get the device name (also known as "Pretty Name").
///
/// Often used to identify device for bluetooth pairing.
#[inline(always)]
pub fn devicename_os() -> Result<OsString> {
    Target::devicename(Os)
}

/// Get the name of the operating system distribution and (possibly) version.
///
/// Example: "Windows 10" or "Fedora 26 (Workstation Edition)"
#[inline(always)]
pub fn distro() -> Result<String> {
    Target::distro(Os)
}

/// Get the desktop environment (if any).
///
/// Example: "gnome" or "windows"
///
/// Returns `None` if a desktop environment is not available (for example in a
/// TTY or over SSH)
#[must_use]
#[inline(always)]
pub fn desktop_env() -> Option<DesktopEnvironment> {
    #[cfg(feature = "std")]
    {
        if std::env::var_os("SSH_CLIENT").is_some()
            || std::env::var_os("SSH_TTY").is_some()
            || std::env::var_os("SSH_CONNECTION").is_some()
        {
            return None;
        }
    }

    Target::desktop_env(Os)
}

/// Get the platform.
#[must_use]
#[inline(always)]
pub fn platform() -> Platform {
    Target::platform(Os)
}

/// Get the user's preferred language(s).
///
/// Returned as an instance of [`LanguagePreferences`]
#[inline(always)]
pub fn lang_prefs() -> Result<LanguagePreferences> {
    Target::lang_prefs(Os).map(LanguagePreferences::add_stripped_fallbacks)
}
