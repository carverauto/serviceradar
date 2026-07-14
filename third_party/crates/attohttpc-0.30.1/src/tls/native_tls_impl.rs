use std::fmt;
use std::io;
use std::io::prelude::*;

use native_tls::HandshakeError;

use crate::Result;

pub type Certificate = native_tls::Certificate;

pub struct TlsHandshaker {
    inner: native_tls::TlsConnectorBuilder,
}

impl TlsHandshaker {
    pub fn new() -> TlsHandshaker {
        TlsHandshaker {
            inner: native_tls::TlsConnector::builder(),
        }
    }

    pub fn danger_accept_invalid_certs(&mut self, accept_invalid_certs: bool) {
        self.inner.danger_accept_invalid_certs(accept_invalid_certs);
    }

    pub fn danger_accept_invalid_hostnames(&mut self, accept_invalid_hostnames: bool) {
        self.inner.danger_accept_invalid_hostnames(accept_invalid_hostnames);
    }

    pub fn add_root_certificate(&mut self, cert: Certificate) {
        self.inner.add_root_certificate(cert);
    }

    pub fn handshake<S>(&self, domain: &str, stream: S) -> Result<TlsStream<S>>
    where
        S: Read + Write,
    {
        let connector = self.inner.build()?;
        let stream = match connector.connect(domain, stream) {
            Ok(stream) => stream,
            Err(HandshakeError::Failure(err)) => return Err(err.into()),
            Err(HandshakeError::WouldBlock(mut stream)) => loop {
                match stream.handshake() {
                    Ok(stream) => break stream,
                    Err(HandshakeError::Failure(err)) => return Err(err.into()),
                    Err(HandshakeError::WouldBlock(mid_stream)) => stream = mid_stream,
                }
            },
        };
        Ok(TlsStream { inner: stream })
    }
}

pub struct TlsStream<S>
where
    S: Read + Write,
{
    inner: native_tls::TlsStream<S>,
}

impl<S> Read for TlsStream<S>
where
    S: Read + Write,
{
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.read(buf)
    }
}

impl<S> Write for TlsStream<S>
where
    S: Read + Write,
{
    #[inline]
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.inner.write(buf)
    }

    #[inline]
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

impl<S> fmt::Debug for TlsStream<S>
where
    S: Read + Write,
{
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "TlsStream[native_tls]")
    }
}
