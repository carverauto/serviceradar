//! # Native tls
//!
//! Native tls implementation of TLS types

use std::io::Write;
use std::net::TcpStream;

use native_tls_crate::{TlsConnector, TlsStream};

use super::{TlsConnector as TlsConnectorTrait, TlsStream as TlsStreamTrait};
use crate::{FtpError, FtpResult};

#[derive(Debug)]
/// A Wrapper for the tls connector
pub struct NativeTlsConnector {
    connector: TlsConnector,
}

impl From<TlsConnector> for NativeTlsConnector {
    fn from(connector: TlsConnector) -> Self {
        Self { connector }
    }
}

impl TlsConnectorTrait for NativeTlsConnector {
    type Stream = NativeTlsStream;

    fn connect(&self, domain: &str, stream: TcpStream) -> FtpResult<Self::Stream> {
        self.connector
            .connect(domain, stream)
            .map(NativeTlsStream::from)
            .map_err(|e| FtpError::SecureError(e.to_string()))
    }
}

// -- tls stream wrapper to implement drop...

/// Tls stream wrapper. This type is a garbage data type used to impl the drop trait for the tls stream.
/// This allows me to keep returning `Read` and `Write` traits in stream methods
#[derive(Debug)]
pub struct NativeTlsStream {
    stream: TlsStream<TcpStream>,
    ssl_shutdown: bool,
}

impl TlsStreamTrait for NativeTlsStream {
    type InnerStream = TlsStream<TcpStream>;

    /// Get underlying tcp stream
    fn tcp_stream(mut self) -> TcpStream {
        let mut stream = self.stream.get_ref().try_clone().unwrap();
        // Don't perform shutdown later
        self.ssl_shutdown = false;
        // flush stream (otherwise can cause bad chars on channel)
        if let Err(err) = stream.flush() {
            error!("Error in flushing tcp stream: {}", err);
        }
        trace!("TLS stream terminated");
        stream
    }

    /// Get ref to underlying tcp stream
    fn get_ref(&self) -> &TcpStream {
        self.stream.get_ref()
    }

    /// Get mutable reference to tls stream
    fn mut_ref(&mut self) -> &mut TlsStream<TcpStream> {
        &mut self.stream
    }
}

impl From<TlsStream<TcpStream>> for NativeTlsStream {
    fn from(stream: TlsStream<TcpStream>) -> Self {
        Self {
            stream,
            ssl_shutdown: true,
        }
    }
}

impl Drop for NativeTlsStream {
    fn drop(&mut self) {
        if self.ssl_shutdown {
            if let Err(err) = self.stream.shutdown() {
                error!("Failed to shutdown stream: {}", err);
            } else {
                debug!("TLS Stream shut down");
            }
        }
    }
}
