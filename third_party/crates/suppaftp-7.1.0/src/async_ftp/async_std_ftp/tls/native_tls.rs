//! # Native TLS
//!
//! Native tls types for suppaftp

use std::pin::Pin;

use async_native_tls_crate::{TlsConnector, TlsStream};
use async_std::io::{Read, Write};
use async_std::net::TcpStream;
use async_trait::async_trait;
use pin_project::pin_project;

use super::{AsyncStdTlsStream, AsyncTlsConnector};
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

impl Read for AsyncNativeTlsStream {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut [u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        self.project().stream.poll_read(cx, buf)
    }
}

impl Write for AsyncNativeTlsStream {
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

    fn poll_close(
        self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        self.project().stream.poll_close(cx)
    }
}

impl AsyncStdTlsStream for AsyncNativeTlsStream {
    type InnerStream = TlsStream<TcpStream>;

    fn get_ref(&self) -> &TcpStream {
        self.stream.get_ref()
    }

    fn mut_ref(&mut self) -> &mut Self::InnerStream {
        &mut self.stream
    }

    fn tcp_stream(self) -> TcpStream {
        self.stream.get_ref().clone()
    }
}
