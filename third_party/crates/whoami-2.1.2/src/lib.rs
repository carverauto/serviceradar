//! Rust library for getting information about the current user and environment.
//!
//! ## Getting Started
//!
//! Using the whoami crate is super easy!  All of the public items are simple
//! functions with no parameters that return [`String`]s or [`OsString`]s (with
//! the exception of [`desktop_env()`], [`platform()`], and [`cpu_arch()`],
//! which return enums, and [`lang_prefs()`] that returns
//! [`LanguagePreferences`]).  The following example shows how to use all of the
//! functions (except those that return [`OsString`]):
//!
//! ```rust
//! println!(
//!     "User's Language        whoami::lang_prefs():          {}",
//!     whoami::lang_prefs().unwrap_or_default(),
//! );
//! println!(
//!     "User's Name            whoami::realname():            {}",
//!     whoami::realname().unwrap_or_else(|_| "<unknown>".to_string()),
//! );
//! println!(
//!     "User's Username        whoami::username():            {}",
//!     whoami::username().unwrap_or_else(|_| "<unknown>".to_string()),
//! );
//! println!(
//!     "User's Username        whoami::account():             {}",
//!     whoami::account().unwrap_or_else(|_| "<unknown>".to_string()),
//! );
//! println!(
//!     "Device's Pretty Name   whoami::devicename():          {}",
//!     whoami::devicename().unwrap_or_else(|_| "<unknown>".to_string()),
//! );
//! println!(
//!     "Device's Hostname      whoami::hostname():            {}",
//!     whoami::hostname().unwrap_or_else(|_| "<unknown>".to_string()),
//! );
//! println!(
//!     "Device's Platform      whoami::platform():            {}",
//!     whoami::platform(),
//! );
//! println!(
//!     "Device's OS Distro     whoami::distro():              {}",
//!     whoami::distro().unwrap_or_else(|_| "<unknown>".to_string()),
//! );
//! println!(
//!     "Device's Desktop Env.  whoami::desktop_env():         {}",
//!     whoami::desktop_env()
//!         .map(|e| e.to_string())
//!         .unwrap_or_else(|| "<unknown>".to_string()),
//! );
//! println!(
//!     "Device's CPU Arch      whoami::cpu_arch():            {}",
//!     whoami::cpu_arch(),
//! );
//! ```
//!
//! [`OsString`]: std::ffi::OsString
//! [`String`]: std::string::String

#![no_std]
#![warn(
    anonymous_parameters,
    missing_copy_implementations,
    missing_debug_implementations,
    missing_docs,
    nonstandard_style,
    rust_2018_idioms,
    single_use_lifetimes,
    trivial_casts,
    trivial_numeric_casts,
    unreachable_pub,
    unused_extern_crates,
    unused_qualifications,
    variant_size_differences,
    unsafe_code
)]
#![deny(
    rustdoc::broken_intra_doc_links,
    rustdoc::private_intra_doc_links,
    rustdoc::missing_crate_level_docs,
    rustdoc::private_doc_tests,
    rustdoc::invalid_codeblock_attributes,
    rustdoc::invalid_html_tags,
    rustdoc::invalid_rust_codeblocks,
    rustdoc::bare_urls,
    rustdoc::unescaped_backticks,
    rustdoc::redundant_explicit_links
)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/ardaku/whoami/v2/res/icon.svg",
    html_favicon_url = "https://raw.githubusercontent.com/ardaku/whoami/v2/res/icon.svg"
)]

extern crate alloc;
#[cfg(feature = "std")]
extern crate std;

mod api;
mod arch;
mod conversions;
mod desktop_env;
mod error;
mod langs;
mod os;
mod platform;
mod result;

use self::conversions::OsString;
pub use self::{
    api::{
        account, account_os, cpu_arch, desktop_env, devicename, devicename_os,
        distro, hostname, lang_prefs, platform, realname, realname_os,
        username, username_os,
    },
    arch::{CpuArchitecture, Width},
    desktop_env::DesktopEnvironment,
    error::Error,
    langs::{Language, LanguagePreferences},
    platform::Platform,
    result::Result,
};
