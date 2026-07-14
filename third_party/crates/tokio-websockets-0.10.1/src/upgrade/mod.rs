//! HTTP upgrade request and response generation and validation helpers.

use std::fmt;
#[cfg(feature = "server")]
pub(crate) mod client_request;
#[cfg(feature = "client")]
pub(crate) mod server_response;

/// A parsed HTTP/1.1 101 Switching Protocols response.
/// These responses typically do not contain a body, therefore it is omitted.
#[cfg(feature = "client")]
pub type Response = http::Response<()>;

/// Errors that occur during the HTTP upgrade handshake between client and
/// server.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// Header required in the request or response is not present.
    MissingHeader(&'static str),
    /// `Upgrade` header sent by the client does not match "websocket".
    UpgradeNotWebSocket,
    /// `Connection` header sent by the client does not contain "Upgrade".
    ConnectionNotUpgrade,
    /// `Sec-WebSocket-Version` header sent by the client is not supported by
    /// the server.
    UnsupportedWebSocketVersion,
    /// Failed to parse client request or server response.
    Parsing(httparse::Error),
    /// Server did not return a HTTP Switching Protocols response.
    DidNotSwitchProtocols(u16),
    /// Server returned a `Sec-WebSocket-Accept` that is not compatible with the
    /// `Sec-WebSocket-Key` sent by the client.
    WrongWebSocketAccept,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::MissingHeader(header) => {
                f.write_str("missing required header: ")?;
                f.write_str(header)
            }
            Error::UpgradeNotWebSocket => f.write_str("upgrade header value was not websocket"),
            Error::ConnectionNotUpgrade => f.write_str("connection header value was not upgrade"),
            Error::UnsupportedWebSocketVersion => f.write_str("unsupported WebSocket version"),
            Error::Parsing(e) => e.fmt(f),
            Error::DidNotSwitchProtocols(status) => {
                f.write_str("expected HTTP 101 Switching Protocols, got status code ")?;
                f.write_fmt(format_args!("{status}"))
            }
            Error::WrongWebSocketAccept => f.write_str("mismatching Sec-WebSocket-Accept header"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::MissingHeader(_)
            | Error::UpgradeNotWebSocket
            | Error::ConnectionNotUpgrade
            | Error::UnsupportedWebSocketVersion
            | Error::DidNotSwitchProtocols(_)
            | Error::WrongWebSocketAccept => None,
            Error::Parsing(e) => Some(e),
        }
    }
}

impl From<httparse::Error> for Error {
    fn from(err: httparse::Error) -> Self {
        Self::Parsing(err)
    }
}
