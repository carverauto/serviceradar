/// Reasons for closing an HTTP connection.
///
/// This enum represents the various reasons why an HTTP connection might need
/// to be closed after a request/response cycle is complete.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseReason {
    /// Client sent `connection: close`.
    ClientConnectionClose,

    /// Server sent `connection: close`.
    ServerConnectionClose,

    /// When doing expect-100 the server sent _some other response_.
    ///
    /// For expect-100, the only options for a server response are:
    ///
    /// * 100 continue, in which case we continue to send the body.
    /// * do nothing, in which case we continue to send the body after a timeout.
    /// * a 4xx or 5xx response indicating the server cannot receive the body.
    Not100Continue,

    /// Protocol upgrade via 101 Switching Protocols.
    ///
    /// The connection is still open but should NOT be returned to the pool
    /// because it's now using a different protocol (e.g., WebSocket, HTTP/2).
    ProtocolSwitch,

    /// Response body is close delimited.
    ///
    /// We do not know how much body data to receive. The socket will be closed
    /// when it's done. This is HTTP/1.0 semantics.
    CloseDelimitedBody,
}

impl CloseReason {
    pub(crate) fn explain(&self) -> &'static str {
        match self {
            CloseReason::ClientConnectionClose => "client sent Connection: close",
            CloseReason::ServerConnectionClose => "server sent Connection: close",
            CloseReason::Not100Continue => "non-100 response before body",
            CloseReason::ProtocolSwitch => "protocol switched via 101",
            CloseReason::CloseDelimitedBody => "response body is close delimited",
        }
    }
}
