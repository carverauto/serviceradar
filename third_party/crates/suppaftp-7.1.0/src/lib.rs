#![crate_name = "suppaftp"]
#![crate_type = "lib"]
#![cfg_attr(docsrs, feature(doc_cfg))]

//! # SuppaFTP
//!
//! SuppaFTP is an FTP client library written in Rust with optional FTPS support.
//! You can choose whether to use **sync** or **async** version of this library using cargo.toml *features*.
//! SuppaFTP is a library derived from [rust-ftp](https://github.com/mattnenterprise/rust-ftp), which has many additional features though, such as:
//!
//! - New methods to work with streams when transferring files, to give you complete freedom when you work with file transfers
//! - Method to retrieve the welcome message
//! - Supports for both sync and **async** rust
//! - Some extra features, such as the parser for the **LIST** command output
//! - Replaced openssl with rustls or native-tls as you prefer
//! - All the old statements have been replaced with modern rust
//! - Better error handling and possibility to retrieve error codes
//! - Test units and high code coverage to provide the community with a reliable library
//!
//! ## Get started
//!
//! To get started, first add **suppaftp** to your dependencies:
//!
//! ```toml
//! suppaftp = "^7"
//! ```
//!
//! ### Features
//!
//! #### SSL/TLS Support
//!
//! If you want to enable **support for FTPS**, you must enable the `native-tls` or `rustls` feature in your cargo dependencies, based on the TLS provider you prefer.
//!
//! ```toml
//! suppaftp = { version = "^7", features = ["native-tls"] }
//! # or
//! suppaftp = { version = "^7", features = ["rustls"] }
//! ```
//!
//! > 💡 If you don't know what to choose, `native-tls` should be preferred for compatibility reasons.
//!
//! #### Async support
//!
//! If you want to enable **async** support, you must enable either `async-std` feature,
//! to use [async-std](https://crates.io/crates/async-std)
//! or `tokio` feature, to use [tokio](https://crates.io/crates/tokio) as backend, in your cargo dependencies.
//!
//! ```toml
//! suppaftp = { version = "^7", features = ["tokio"] }
//! ```
//!
//! > ⚠️ If you want to enable both **native-tls** and **async-std** you must use the **async-std-async-native-tls** feature ⚠️  
//! > ⚠️ If you want to enable both **native-tls** and **tokio** you must use the **tokio-async-native-tls** feature ⚠️
//! > ⚠️ If you want to enable both **rustls** and **async** you must use the **async-std-rustls** feature ⚠️  
//! > ❗ If you want to link libssl statically with `async-std`, enable feature `async-std-async-native-tls-vendored`
//! > ❗ If you want to link libssl statically with `tokio`, enable feature `tokio-async-native-tls-vendored`
//!
//! #### Deprecated methods
//!
//! If you want to enable deprecated methods of FTPS, please enable the `deprecated` feature in your cargo dependencies.
//!
//! This feature enables these methods:
//!
//! - `connect_secure_implicit()`: used to connect via implicit FTPS
//!
//! ## Usage
//!
//! Here is a basic usage example:
//!
//! ```rust,ignore
//! use suppaftp::FtpStream;
//! let mut ftp_stream = FtpStream::connect("127.0.0.1:10021").unwrap_or_else(|err|
//!     panic!("{}", err)
//! );
//! assert!(ftp_stream.login("test", "test").is_ok());
//!
//! // Disconnect from server
//! assert!(ftp_stream.quit().is_ok());
//! ```
//!
//! ## FTPS
//!
//! The client supports FTPS on demand. To enable it the client should be
//! compiled with feature `secure` enabled which requires
//! [rust-native-tls](https://github.com/sfackler/rust-native-tls).
//!
//! The client uses explicit mode for connecting FTPS what means you should
//! connect the server as usually and then switch to the secure mode (TLS is used).
//! For better security it's the good practice to switch to the secure mode
//! before authentication.
//!
//! ### FTPS Usage
//!
//! ```rust,ignore
//! use suppaftp::{NativeTlsFtpStream, NativeTlsConnector};
//! use suppaftp::native_tls::{TlsConnector, TlsStream};
//!
//! let ftp_stream = NativeTlsFtpStream::connect("test.rebex.net:21").unwrap();
//! // Switch to the secure mode
//! let mut ftp_stream = ftp_stream.into_secure(NativeTlsConnector::from(TlsConnector::new().unwrap()), "test.rebex.net").unwrap();
//! ftp_stream.login("demo", "password").unwrap();
//! // Do other secret stuff
//! assert!(ftp_stream.quit().is_ok());
//! ```
//!
//! ## Going async
//!
//! SuppaFTP also supports **async** execution as said before, through the **async** feature.
//! Basically there's no difference in the function you can use when using the async version of suppaftp.
//! Let's quickly see in the example how it works
//!
//! ```rust,ignore
//! use suppaftp::{AsyncFtpStream, AsyncNativeTlsConnector};
//! use suppaftp::async_native_tls::{TlsConnector, TlsStream};
//!
//! let ftp_stream = AsyncFtpStream::connect("test.rebex.net:21").await.unwrap();
//! // Switch to the secure mode
//! let mut ftp_stream = ftp_stream.into_secure(AsyncNativeTlsConnector::from(TlsConnector::new()), "test.rebex.net").await.unwrap();
//! ftp_stream.login("demo", "password").await.unwrap();
//! // Do other secret stuff
//! assert!(ftp_stream.quit().await.is_ok());
//! ```
//!

#![doc(html_playground_url = "https://play.rust-lang.org")]
#![doc(
    html_favicon_url = "https://raw.githubusercontent.com/veeso/suppaftp/main/assets/images/cargo/suppaftp-128.png"
)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/veeso/suppaftp/main/assets/images/cargo/suppaftp-512.png"
)]

// Give compile error if both `async-std-async-native-tls` and `tokio-async-native-tls` are enabled
#[cfg(all(
    feature = "async-std-async-native-tls",
    feature = "tokio-async-native-tls"
))]
compile_error!("async-std-async-native-tls and tokio-async-native-tls are mutually exclusive");

// -- common deps
#[macro_use]
extern crate lazy_regex;
#[macro_use]
extern crate log;

// -- private
#[cfg(any(feature = "async-std", feature = "tokio", feature = "async-std"))]
mod async_ftp;

pub(crate) mod command;
mod regex;
mod status;
mod sync_ftp;

// -- public
pub mod list;
pub mod types;

#[cfg(test)]
mod test_container;

// -- secure deps
#[cfg(feature = "native-tls")]
#[cfg_attr(docsrs, doc(cfg(feature = "native-tls")))]
pub extern crate native_tls_crate as native_tls;
#[cfg(feature = "rustls")]
#[cfg_attr(docsrs, doc(cfg(feature = "rustls")))]
pub extern crate rustls_crate as rustls;
// -- async deps
#[cfg(any(
    feature = "tokio-async-native-tls",
    feature = "async-std-async-native-tls"
))]
#[cfg_attr(
    docsrs,
    doc(cfg(any(
        feature = "tokio-async-native-tls",
        feature = "async-std-async-native-tls"
    )))
)]
pub extern crate async_native_tls_crate as async_native_tls;

// -- export (common)
pub use status::Status;
use sync_ftp::NoTlsStream;
// -- export sync
pub use sync_ftp::{ImplFtpStream, PassiveStreamBuilder, TlsStream};
pub use types::{FtpError, FtpResult, Mode};
pub type FtpStream = ImplFtpStream<NoTlsStream>;
pub use sync_ftp::DataStream;
// -- export secure (native-tls)
#[cfg(feature = "native-tls")]
#[cfg_attr(docsrs, doc(cfg(feature = "native-tls")))]
pub use sync_ftp::NativeTlsConnector;
#[cfg(feature = "native-tls")]
#[cfg_attr(docsrs, doc(cfg(feature = "native-tls")))]
use sync_ftp::NativeTlsStream;
#[cfg(feature = "native-tls")]
#[cfg_attr(docsrs, doc(cfg(feature = "native-tls")))]
pub type NativeTlsFtpStream = ImplFtpStream<NativeTlsStream>;
// -- export secure (rustls)
#[cfg(feature = "rustls")]
#[cfg_attr(docsrs, doc(cfg(feature = "rustls")))]
pub use sync_ftp::RustlsConnector;
#[cfg(feature = "rustls")]
#[cfg_attr(docsrs, doc(cfg(feature = "rustls")))]
use sync_ftp::RustlsStream;
#[cfg(feature = "rustls")]
#[cfg_attr(docsrs, doc(cfg(feature = "rustls")))]
pub type RustlsFtpStream = ImplFtpStream<RustlsStream>;

#[cfg(any(feature = "tokio", feature = "async-std"))]
pub use crate::async_ftp::*;

// -- test logging
#[cfg(test)]
pub fn log_init() {
    use std::sync::Once;

    static INIT: Once = Once::new();

    INIT.call_once(|| {
        let _ = env_logger::builder()
            .filter_level(log::LevelFilter::Trace)
            .is_test(true)
            .try_init();
    });
}
