use std::fmt;
use std::io;
use std::io::prelude::*;
use std::marker::PhantomData;

use crate::{ErrorKind, Result};

pub type Certificate = ();

pub struct TlsHandshaker {}

impl TlsHandshaker {
    pub fn new() -> TlsHandshaker {
        TlsHandshaker {}
    }

    pub fn danger_accept_invalid_certs(&mut self, _accept_invalid_certs: bool) {}

    pub fn danger_accept_invalid_hostnames(&mut self, _accept_invalid_hostnames: bool) {}

    pub fn add_root_certificate(&mut self, _cert: Certificate) {}

    pub fn handshake<S>(&self, _domain: &str, _stream: S) -> Result<TlsStream<S>>
    where
        S: Read + Write,
    {
        Err(ErrorKind::TlsDisabled.into())
    }
}

pub struct TlsStream<S>
where
    S: Read + Write,
{
    dummy: PhantomData<S>,
}

impl<S> Read for TlsStream<S>
where
    S: Read + Write,
{
    #[inline]
    fn read(&mut self, _buf: &mut [u8]) -> io::Result<usize> {
        Ok(0)
    }
}

impl<S> Write for TlsStream<S>
where
    S: Read + Write,
{
    #[inline]
    fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
        Ok(0)
    }

    #[inline]
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<S> fmt::Debug for TlsStream<S>
where
    S: Read + Write,
{
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "TlsStream[no_tls]")
    }
}
