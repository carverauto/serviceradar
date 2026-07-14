#![deny(missing_debug_implementations)]
#![deny(missing_docs)]
#![allow(clippy::needless_doctest_main)]
//! This project's goal is to provide a lightweight and simple HTTP client for the Rust ecosystem. The intended use is for
//! projects that have HTTP needs where performance is not critical or when HTTP is not the main purpose of the application.
//! Note that the project still tries to perform well and avoid allocation where possible, but stays away from Rust's
//! asynchronous stack to provide a crate that's as small as possible. Features are provided behind feature flags when
//! possible to allow users to get just what they need.
//!
//! Check out the [repository](https://github.com/sbstp/attohttpc) for more information and examples.
//!
//! # Quick start
//! ```no_run
//! # #[cfg(feature = "json")]
//! # use serde_json::json;
//! # #[cfg(feature = "json")]
//! # fn main() -> attohttpc::Result {
//! let obj = json!({
//!     "hello": "world",
//! });
//!
//! let resp = attohttpc::post("https://my-api.org/do/something")
//!     .header("X-My-Header", "foo")   // set a header for the request
//!     .param("qux", "baz")            // set a query parameter
//!     .json(&obj)?                    // set the request body (json feature required)
//!     .send()?;                       // send the request
//!
//! // Check if the status is a 2XX code.
//! if resp.is_success() {
//!     // Consume the response body as text and print it.
//!     println!("{}", resp.text()?);
//! }
//! # Ok(())
//! # }
//! # #[cfg(not(feature = "json"))]
//! # fn main() {
//! # }
//! ```
//!
//! # Features
//! * `basic-auth` support for basic auth
//! * `charsets` support for decoding more text encodings than just UTF-8
//! * `compress` support for decompressing response bodies using `miniz_oxide` (**default**)
//! * `compress-zlib` support for decompressing response bodies using `zlib` instead of `miniz_oxide`
//!   (see [flate2 backends](https://github.com/rust-lang/flate2-rs#backends))
//! * `compress-zlib-ng` support for decompressing response bodies using `zlib-ng` instead of `miniz_oxide`
//!   (see [flate2 backends](https://github.com/rust-lang/flate2-rs#backends))
//! * `json` support for serialization and deserialization
//! * `form` support for url encoded forms (does not include support for multipart)
//! * `multipart-form` support for multipart forms (does not include support for url encoding)
//! * `tls-native` support for tls connections using the `native-tls` crate (**default**)
//! * `tls-native-vendored` activate the `vendored` feature of `native-tls`
//! * `tls-rustls-webpki-roots` support for TLS connections using `rustls` instead of `native-tls` with Web PKI roots
//! * `tls-rustls-native-roots` support for TLS connections using `rustls` with root certificates loaded from the `rustls-native-certs` crate
//!
//! # Activating a feature
//! To activate a feature, specify it in your `Cargo.toml` file like so
//! ```toml
//! attohttpc = { version = "...", features = ["json", "form", ...] }
//! ```
//!

macro_rules! debug {
    ($($arg:tt)+) => { log::debug!(target: "attohttpc", $($arg)+) };
}

macro_rules! warn {
    ($($arg:tt)+) => { log::warn!(target: "attohttpc", $($arg)+) };
}

#[cfg(feature = "charsets")]
pub mod charsets;
mod error;
mod happy;
#[cfg(feature = "multipart-form")]
mod multipart;
#[cfg(feature = "multipart-form")]
mod multipart_crate;
mod parsing;
mod request;
mod streams;
mod tls;

pub use crate::error::{Error, ErrorKind, InvalidResponseKind, Result};
#[cfg(feature = "multipart-form")]
pub use crate::multipart::{Multipart, MultipartBuilder, MultipartFile};
pub use crate::parsing::{Response, ResponseReader};
pub use crate::request::proxy::{ProxySettings, ProxySettingsBuilder};
pub use crate::request::{body, PreparedRequest, RequestBuilder, RequestInspector, Session};
#[cfg(feature = "charsets")]
pub use crate::{charsets::Charset, parsing::TextReader};
pub use http::Method;
pub use http::StatusCode;

pub mod header {
    //! This module is a re-export of the `http` crate's `header` module.
    pub use http::header::*;
}

/// Create a new `RequestBuilder` with the GET method.
pub fn get<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::GET, base_url)
}

/// Create a new `RequestBuilder` with the POST method.
pub fn post<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::POST, base_url)
}

/// Create a new `RequestBuilder` with the PUT method.
pub fn put<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::PUT, base_url)
}

/// Create a new `RequestBuilder` with the DELETE method.
pub fn delete<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::DELETE, base_url)
}

/// Create a new `RequestBuilder` with the HEAD method.
pub fn head<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::HEAD, base_url)
}

/// Create a new `RequestBuilder` with the OPTIONS method.
pub fn options<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::OPTIONS, base_url)
}

/// Create a new `RequestBuilder` with the PATCH method.
pub fn patch<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::PATCH, base_url)
}

/// Create a new `RequestBuilder` with the TRACE method.
pub fn trace<U>(base_url: U) -> RequestBuilder
where
    U: AsRef<str>,
{
    RequestBuilder::new(Method::TRACE, base_url)
}

mod skip_debug {
    use std::fmt;

    #[derive(Clone)]
    pub struct SkipDebug<T>(pub T);

    impl<T> fmt::Debug for SkipDebug<T> {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "...")
        }
    }

    impl<T> From<T> for SkipDebug<T> {
        fn from(val: T) -> SkipDebug<T> {
            SkipDebug(val)
        }
    }
}
