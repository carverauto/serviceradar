//! # Async
//!
//! This module contains the definition for all async implementation of suppaftp
#[cfg(feature = "async-std")]
mod async_std_ftp;
#[cfg(feature = "tokio")]
mod tokio_ftp;

#[cfg(feature = "async-std")]
#[cfg_attr(docsrs, doc(cfg(feature = "async-std")))]
pub mod async_std {
    #[cfg(feature = "async-std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-std")))]
    use crate::async_ftp::async_std_ftp::AsyncNoTlsStream;
    pub use crate::async_ftp::async_std_ftp::AsyncStdPassiveStreamBuilder;
    #[cfg(feature = "async-std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-std")))]
    pub use crate::async_ftp::async_std_ftp::{AsyncStdTlsStream, ImplAsyncFtpStream};

    #[cfg(feature = "async-std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-std")))]
    pub type AsyncFtpStream = ImplAsyncFtpStream<AsyncNoTlsStream>;

    // -- export async secure (native-tls)
    #[cfg(all(feature = "async-std", feature = "async-std-async-native-tls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "async-std", feature = "async-std-async-native-tls")))
    )]
    pub use crate::async_ftp::async_std_ftp::AsyncNativeTlsConnector;
    #[cfg(all(feature = "async-std", feature = "async-std-async-native-tls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "async-std", feature = "async-std-async-native-tls")))
    )]
    use crate::async_ftp::async_std_ftp::AsyncNativeTlsStream;
    #[cfg(feature = "async-std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-std")))]
    pub use crate::async_ftp::async_std_ftp::DataStream as AsyncDataStream;

    #[cfg(feature = "async-std-async-native-tls")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-std-async-native-tls")))]
    pub type AsyncNativeTlsFtpStream = ImplAsyncFtpStream<AsyncNativeTlsStream>;
    // -- export async secure (rustls)async-std-rustls
    #[cfg(all(feature = "async-std", feature = "async-std-rustls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "async-std-rustls", feature = "async-std-rustls")))
    )]
    pub use crate::async_ftp::async_std_ftp::AsyncRustlsConnector;
    #[cfg(all(feature = "async-std", feature = "async-std-rustls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "async-std", feature = "async-std-rustls")))
    )]
    use crate::async_ftp::async_std_ftp::AsyncRustlsStream;

    #[cfg(all(feature = "async-std", feature = "async-std-rustls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "async-std", feature = "async-std-rustls")))
    )]
    pub type AsyncRustlsFtpStream = ImplAsyncFtpStream<AsyncRustlsStream>;
}

#[cfg(feature = "tokio")]
#[cfg_attr(docsrs, doc(cfg(feature = "tokio")))]
pub mod tokio {
    pub use super::tokio_ftp::{AsyncNoTlsStream, ImplAsyncFtpStream};
    pub type AsyncFtpStream = ImplAsyncFtpStream<AsyncNoTlsStream>;

    #[cfg(all(feature = "tokio", feature = "tokio-async-native-tls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "tokio", feature = "tokio-async-native-tls")))
    )]
    pub use super::tokio_ftp::AsyncNativeTlsConnector;
    #[cfg(all(feature = "tokio", feature = "tokio-async-native-tls"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "tokio", feature = "tokio-async-native-tls")))
    )]
    pub use super::tokio_ftp::AsyncNativeTlsStream;
    pub use super::tokio_ftp::{
        DataStream as AsyncDataStream, TokioPassiveStreamBuilder, TokioTlsStream,
    };

    #[cfg(feature = "tokio-async-native-tls")]
    #[cfg_attr(docsrs, doc(cfg(feature = "tokio-async-native-tls")))]
    pub type AsyncNativeTlsFtpStream = ImplAsyncFtpStream<AsyncNativeTlsStream>;

    #[cfg(all(feature = "tokio", feature = "tokio-rustls"))]
    #[cfg_attr(docsrs, doc(cfg(all(feature = "tokio", feature = "tokio-rustls"))))]
    pub use super::tokio_ftp::AsyncRustlsConnector;
    #[cfg(all(feature = "tokio", feature = "tokio-rustls"))]
    #[cfg_attr(docsrs, doc(cfg(all(feature = "tokio", feature = "tokio-rustls"))))]
    pub use super::tokio_ftp::AsyncRustlsStream;

    #[cfg(all(feature = "tokio", feature = "tokio-rustls"))]
    #[cfg_attr(docsrs, doc(cfg(all(feature = "tokio", feature = "tokio-rustls"))))]
    pub type AsyncRustlsFtpStream = ImplAsyncFtpStream<AsyncRustlsStream>;
}
