//! # Tls
//!
//! Tls wrappers

use std::fmt::Debug;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

#[cfg(feature = "tokio-async-native-tls")]
mod native_tls;
#[cfg(feature = "tokio-async-native-tls")]
pub use self::native_tls::{AsyncNativeTlsConnector, AsyncNativeTlsStream};

#[cfg(feature = "tokio-rustls")]
mod rustls;
#[cfg(feature = "tokio-rustls")]
pub use self::rustls::{AsyncRustlsConnector, AsyncRustlsStream};

#[cfg(feature = "async-secure")]
#[async_trait::async_trait]
pub trait AsyncTlsConnector: Debug {
    type Stream: TokioTlsStream;

    async fn connect(&self, domain: &str, stream: TcpStream) -> crate::FtpResult<Self::Stream>;
}

/// A trait for a Tokio based TLS stream.
///
/// This kind of stream is returned when using a data connection in FTP.
pub trait TokioTlsStream: Debug + AsyncRead + AsyncWrite + Unpin {
    type InnerStream: AsyncRead + AsyncWrite;

    /// Get underlying tcp stream
    fn tcp_stream(self) -> TcpStream;

    /// Get ref to underlying tcp stream
    fn get_ref(&self) -> &TcpStream;

    /// Get mutable reference to tls stream
    fn mut_ref(&mut self) -> &mut Self::InnerStream;
}

#[derive(Debug)]
pub struct AsyncNoTlsStream;

impl AsyncRead for AsyncNoTlsStream {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        _buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        panic!()
    }
}

impl AsyncWrite for AsyncNoTlsStream {
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

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        panic!()
    }
}

impl TokioTlsStream for AsyncNoTlsStream {
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
