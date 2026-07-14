//! # Native TLS
//!
//! Native tls types for suppaftp

use std::pin::Pin;

use async_native_tls_crate::{TlsConnector, TlsStream};
use async_trait::async_trait;
use pin_project::pin_project;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

use super::{AsyncTlsConnector, TokioTlsStream};
use crate::{FtpError, FtpResult};

#[derive(Debug)]
/// A Wrapper for the tls connector
pub struct AsyncNativeTlsConnector {
    connector: TlsConnector,
}

impl From<TlsConnector> for AsyncNativeTlsConnector {
    fn from(connector: TlsConnector) -> Self {
        Self { connector }
    }
}

#[async_trait]
impl AsyncTlsConnector for AsyncNativeTlsConnector {
    type Stream = AsyncNativeTlsStream;

    async fn connect(&self, domain: &str, stream: TcpStream) -> FtpResult<Self::Stream> {
        self.connector
            .connect(domain, stream)
            .await
            .map(AsyncNativeTlsStream::from)
            .map_err(|e| FtpError::SecureError(e.to_string()))
    }
}

#[derive(Debug)]
#[pin_project(project = AsyncNativeTlsStreamProj)]
pub struct AsyncNativeTlsStream {
    #[pin]
    stream: TlsStream<TcpStream>,
}

impl From<TlsStream<TcpStream>> for AsyncNativeTlsStream {
    fn from(stream: TlsStream<TcpStream>) -> Self {
        Self { stream }
    }
}

impl AsyncRead for AsyncNativeTlsStream {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        self.project().stream.poll_read(cx, buf)
    }
}

impl AsyncWrite for AsyncNativeTlsStream {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        self.project().stream.poll_write(cx, buf)
    }

    fn poll_flush(
        self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        self.project().stream.poll_flush(cx)
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        self.project().stream.poll_shutdown(cx)
    }
}

impl TokioTlsStream for AsyncNativeTlsStream {
    type InnerStream = TlsStream<TcpStream>;

    fn get_ref(&self) -> &TcpStream {
        self.stream.get_ref()
    }

    fn mut_ref(&mut self) -> &mut Self::InnerStream {
        &mut self.stream
    }

    fn tcp_stream(self) -> TcpStream {
        // Obtain a raw pointer to the underlying TcpStream
        let ptr: *const TcpStream = self.stream.get_ref() as *const _;
        // Prevent the original object from being deallocated
        std::mem::forget(self.stream);
        // Reconstruct ownership from the raw pointer
        unsafe {
            // Convert *const to *mut
            let mut_ptr = ptr as *mut TcpStream;
            // Rebuild ownership from the raw pointer
            *Box::from_raw(mut_ptr)
        }
    }
}
