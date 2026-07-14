//! # Tls
//!
//! Tls wrappers

use std::fmt::Debug;

use async_std::io::{Read, Write};
use async_std::net::TcpStream;

#[cfg(feature = "async-std-async-native-tls")]
mod native_tls;
#[cfg(feature = "async-std-async-native-tls")]
pub use self::native_tls::{AsyncNativeTlsConnector, AsyncNativeTlsStream};

#[cfg(feature = "async-std-rustls")]
mod rustls;
#[cfg(feature = "async-std-rustls")]
pub use self::rustls::{AsyncRustlsConnector, AsyncRustlsStream};

#[cfg(feature = "async-secure")]
#[async_trait::async_trait]
pub trait AsyncTlsConnector: Debug {
    type Stream: AsyncStdTlsStream;

    async fn connect(&self, domain: &str, stream: TcpStream) -> crate::FtpResult<Self::Stream>;
}

/// A trait for a Async-std based TLS stream.
///
/// This kind of stream is returned when using a data connection in FTP.
pub trait AsyncStdTlsStream: Debug + Read + Write + Unpin {
    type InnerStream: Read + Write;

    /// Get underlying tcp stream
    fn tcp_stream(self) -> TcpStream;

    /// Get ref to underlying tcp stream
    fn get_ref(&self) -> &TcpStream;

    /// Get mutable reference to tls stream
    fn mut_ref(&mut self) -> &mut Self::InnerStream;
}

#[derive(Debug)]
pub struct AsyncNoTlsStream;

impl Read for AsyncNoTlsStream {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        _buf: &mut [u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        panic!()
    }
}

impl Write for AsyncNoTlsStream {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        _buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        panic!()
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        panic!()
    }

    fn poll_close(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        panic!()
    }
}

impl AsyncStdTlsStream for AsyncNoTlsStream {
    type InnerStream = TcpStream;

    fn tcp_stream(self) -> TcpStream {
        panic!()
    }

    fn get_ref(&self) -> &TcpStream {
        panic!()
    }

    fn mut_ref(&mut self) -> &mut Self::InnerStream {
        panic!()
    }
}
