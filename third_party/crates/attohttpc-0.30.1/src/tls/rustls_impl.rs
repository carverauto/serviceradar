use std::convert::TryFrom;
use std::fmt;
use std::io;
use std::io::prelude::*;
use std::sync::Arc;

use rustls::{
    client::{
        danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        WebPkiServerVerifier,
    },
    pki_types::{CertificateDer, ServerName, UnixTime},
    ClientConfig, ClientConnection, DigitallySignedStruct, RootCertStore, SignatureScheme, StreamOwned,
};
#[cfg(feature = "tls-rustls-native-roots")]
use rustls_native_certs::load_native_certs;
#[cfg(feature = "tls-rustls-webpki-roots")]
use webpki_roots::TLS_SERVER_ROOTS;

use crate::{Error, ErrorKind, Result};

pub type Certificate = CertificateDer<'static>;

pub struct TlsHandshaker {
    inner: Option<Arc<ClientConfig>>,
    accept_invalid_certs: bool,
    accept_invalid_hostnames: bool,
    additional_certs: Vec<Certificate>,
}

impl TlsHandshaker {
    pub fn new() -> TlsHandshaker {
        TlsHandshaker {
            inner: None,
            accept_invalid_hostnames: false,
            accept_invalid_certs: false,
            additional_certs: Vec::new(),
        }
    }

    pub fn danger_accept_invalid_certs(&mut self, accept_invalid_certs: bool) {
        self.accept_invalid_certs = accept_invalid_certs;
        self.inner = None;
    }

    pub fn danger_accept_invalid_hostnames(&mut self, accept_invalid_hostnames: bool) {
        self.accept_invalid_hostnames = accept_invalid_hostnames;
        self.inner = None;
    }

    pub fn add_root_certificate(&mut self, cert: Certificate) {
        self.additional_certs.push(cert);
        self.inner = None;
    }

    fn client_config(&mut self) -> Result<Arc<ClientConfig>> {
        match &self.inner {
            Some(inner) => Ok(Arc::clone(inner)),
            None => {
                let mut root_store = RootCertStore::empty();

                #[cfg(feature = "tls-rustls-webpki-roots")]
                root_store.extend(TLS_SERVER_ROOTS.iter().cloned());

                #[cfg(feature = "tls-rustls-native-roots")]
                for cert in load_native_certs().certs {
                    // Inspired by https://github.com/seanmonstar/reqwest/blob/231b18f83572836c674404b33cb1ca8b35ca3e36/src/async_impl/client.rs#L363-L365
                    // Native certificate stores often include certificates with invalid formats,
                    // but we don't want those invalid entries to invalidate the entire process of
                    // loading native root certificates
                    if let Err(e) = root_store.add(cert) {
                        warn!("Could not load native root certificate: {}", e);
                    }
                }

                for cert in self.additional_certs.iter().cloned() {
                    root_store.add(cert)?;
                }

                let config = ClientConfig::builder()
                    .dangerous()
                    .with_custom_certificate_verifier(Arc::new(CustomCertVerifier {
                        upstream: WebPkiServerVerifier::builder(root_store.into()).build()?,
                        accept_invalid_certs: self.accept_invalid_certs,
                        accept_invalid_hostnames: self.accept_invalid_hostnames,
                    }))
                    .with_no_client_auth()
                    .into();

                self.inner = Some(Arc::clone(&config));

                Ok(config)
            }
        }
    }

    pub fn handshake<S>(&mut self, domain: &str, mut stream: S) -> Result<TlsStream<S>>
    where
        S: Read + Write,
    {
        let domain = ServerName::try_from(domain)
            .map_err(|_| Error(Box::new(ErrorKind::InvalidDNSName(domain.to_owned()))))?
            .to_owned();
        let config = self.client_config()?;
        let mut session = ClientConnection::new(config, domain)?;

        while let Err(err) = session.complete_io(&mut stream) {
            if err.kind() != io::ErrorKind::WouldBlock || !session.is_handshaking() {
                return Err(err.into());
            }
        }

        Ok(TlsStream {
            inner: StreamOwned::new(session, stream),
        })
    }
}

pub struct TlsStream<S>
where
    S: Read + Write,
{
    inner: StreamOwned<ClientConnection, S>,
}

impl<S> TlsStream<S>
where
    S: Read + Write,
{
    fn handle_close_notify(&mut self, res: io::Result<usize>) -> io::Result<usize> {
        match res {
            Err(err) if err.kind() == io::ErrorKind::ConnectionAborted => {
                self.inner.conn.send_close_notify();
                self.inner.conn.complete_io(&mut self.inner.sock)?;

                Ok(0)
            }
            Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => {
                // In some cases the server does not terminate the connection cleanly
                // We just turn that error into EOF.
                Ok(0)
            }
            res => res,
        }
    }
}

impl<S> Read for TlsStream<S>
where
    S: Read + Write,
{
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let res = self.inner.read(buf);
        self.handle_close_notify(res)
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
        write!(f, "TlsStream[rustls]")
    }
}

struct CustomCertVerifier {
    upstream: Arc<WebPkiServerVerifier>,
    accept_invalid_certs: bool,
    accept_invalid_hostnames: bool,
}

impl fmt::Debug for CustomCertVerifier {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("CustomCertVerifier").finish()
    }
}

impl ServerCertVerifier for CustomCertVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer,
        intermediates: &[CertificateDer],
        server_name: &ServerName,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        match self
            .upstream
            .verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
        {
            Err(rustls::Error::NoCertificatesPresented | rustls::Error::InvalidCertificate(_))
                if self.accept_invalid_certs =>
            {
                Ok(ServerCertVerified::assertion())
            }

            Err(rustls::Error::InvalidCertificate(rustls::CertificateError::NotValidForName))
                if self.accept_invalid_hostnames =>
            {
                Ok(ServerCertVerified::assertion())
            }

            upstream => upstream,
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.upstream.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.upstream.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.upstream.supported_verify_schemes()
    }
}
