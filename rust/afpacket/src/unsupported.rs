//! The non-Linux path.
//!
//! Every constructor errors. It deliberately does NOT return an empty success
//! the way this repository's AF_XDP stub does (`af_xdp.rs` returns
//! `Ok(Self { streams: Vec::new() })` off Linux, with no warning): a capture
//! path that reports success and yields zero packets is indistinguishable from
//! a working one on a quiet interface, which is the exact failure shape the
//! project's rules forbid.
//!
//! The types exist so callers compile on macOS. Anything that would actually
//! capture fails loudly at run time instead.

use crate::{Error, Frame, RingConfig, Stats};

#[derive(Debug)]
pub struct Socket {
    _private: (),
}

impl Socket {
    pub fn open(_interface: &str) -> Result<Self, Error> {
        Err(Error::Unsupported)
    }

    // Present so callers compile off Linux. `open` is the only constructor and
    // it always errors, so these are unreachable by construction; without them
    // the "callers compile on macOS" claim was false for anything touching a
    // Socket's accessors.
    pub fn interface(&self) -> &str {
        unreachable!("a Socket cannot be constructed off Linux")
    }

    pub fn ifindex(&self) -> u32 {
        unreachable!("a Socket cannot be constructed off Linux")
    }

    /// Mirrors the Linux signature exactly, including handing the descriptor
    /// back in the error. A shim whose whole purpose is "callers compile off
    /// Linux" fails at that the moment its signature differs, and the
    /// difference shows up as a confusing type error in the caller rather than
    /// here.
    pub fn activate(
        self,
        _config: RingConfig,
        _filter: &[(u16, u8, u8, u32)],
    ) -> Result<Ring, ActivateError> {
        Err(ActivateError {
            socket: self,
            error: Error::Unsupported,
        })
    }
}

/// Mirrors the Linux type so callers compile off Linux.
#[derive(Debug)]
pub struct ActivateError {
    pub socket: Socket,
    pub error: Error,
}

impl std::fmt::Display for ActivateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(f)
    }
}

impl std::error::Error for ActivateError {}

#[derive(Debug)]
pub struct Ring {
    _private: (),
}

impl Ring {
    pub fn interface(&self) -> &str {
        unreachable!("a Ring cannot be constructed off Linux")
    }

    pub fn ifindex(&self) -> u32 {
        unreachable!("a Ring cannot be constructed off Linux")
    }

    pub fn stats(&self) -> Stats {
        unreachable!("a Ring cannot be constructed off Linux")
    }

    pub fn refresh_stats(&mut self) -> Result<Stats, Error> {
        Err(Error::Unsupported)
    }

    pub fn wait(&self, _timeout: std::time::Duration) -> bool {
        unreachable!("a Ring cannot be constructed off Linux")
    }

    pub fn drain_block<F>(&mut self, _visit: F) -> Option<usize>
    where
        F: FnMut(Frame<'_>),
    {
        unreachable!("a Ring cannot be constructed off Linux")
    }

    pub fn into_socket(self) -> Socket {
        unreachable!("a Ring cannot be constructed off Linux")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opening_a_socket_fails_loudly_rather_than_returning_an_empty_success() {
        assert!(matches!(Socket::open("lo"), Err(Error::Unsupported)));
    }
}
