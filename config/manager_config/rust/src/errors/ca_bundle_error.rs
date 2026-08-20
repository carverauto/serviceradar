//! Why a published CA bundle could not be read.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaBundleError {
    /// The request never produced a response.
    Unreachable { url: String, detail: String },
    /// A response arrived but its body could not be read as text.
    Unreadable { url: String, detail: String },
    /// A response arrived and is not a certificate.
    NotPem { url: String, bytes: usize },
}

impl fmt::Display for CaBundleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unreachable { url, detail } => {
                write!(f, "fetching the CA bundle at {url} failed: {detail}")
            }
            Self::Unreadable { url, detail } => {
                write!(f, "reading the CA bundle at {url} failed: {detail}")
            }
            // A bundle that is not a certificate is a MISROUTED REQUEST -- a proxy error page,
            // a login redirect, a 404 body -- and handing those bytes to rustls produces
            // "invalid certificate" a long way from the cause. Saying it here keeps the
            // diagnosis at the fetch.
            Self::NotPem { url, bytes } => write!(
                f,
                "{url} returned {bytes} bytes that are not PEM: no BEGIN CERTIFICATE marker. \
                 The URL is most likely being intercepted -- a proxy error page or a redirect \
                 to a login form -- rather than serving the bundle."
            ),
        }
    }
}

impl std::error::Error for CaBundleError {}
