#[cfg(all(feature = "rfc3164", feature = "rfc5424"))]
mod auto_decoder;
#[cfg(feature = "gelf")]
mod gelf_decoder;
mod invalid_decoder;
#[cfg(feature = "ltsv")]
mod ltsv_decoder;
#[cfg(feature = "rfc3164")]
mod rfc3164_decoder;
#[cfg(feature = "rfc5424")]
mod rfc5424_decoder;

#[cfg(all(feature = "rfc3164", feature = "rfc5424"))]
pub use self::auto_decoder::AutoDecoder;
#[cfg(feature = "gelf")]
pub use self::gelf_decoder::GelfDecoder;
pub use self::invalid_decoder::InvalidDecoder;
#[cfg(feature = "ltsv")]
pub use self::ltsv_decoder::LTSVDecoder;
#[cfg(feature = "rfc3164")]
pub use self::rfc3164_decoder::{ClearPassDecoder, RFC3164Decoder};
#[cfg(feature = "rfc5424")]
pub use self::rfc5424_decoder::RFC5424Decoder;

use crate::flowgger::record::Record;

pub trait CloneBoxedDecoder {
    fn clone_boxed<'a>(&self) -> Box<dyn Decoder + Send + 'a>
    where
        Self: 'a;
}

impl<T: Decoder + Clone + Send> CloneBoxedDecoder for T {
    fn clone_boxed<'a>(&self) -> Box<dyn Decoder + Send + 'a>
    where
        Self: 'a,
    {
        Box::new(self.clone())
    }
}

impl Clone for Box<dyn Decoder> {
    fn clone(&self) -> Box<dyn Decoder> {
        self.clone_boxed()
    }
}

pub trait Decoder: CloneBoxedDecoder + Send {
    fn decode(&self, line: &str) -> Result<Record, &'static str>;
}

/// Attach the transport-observed peer address to every decoded record.
///
/// UDP inputs set `remote_addr` while receiving each datagram. Stream inputs
/// use this wrapper because their splitter owns the read loop.
#[derive(Clone)]
pub(crate) struct RemoteAddrDecoder {
    inner: Box<dyn Decoder>,
    remote_addr: String,
}

impl RemoteAddrDecoder {
    pub(crate) fn new(inner: Box<dyn Decoder>, remote_addr: String) -> Self {
        Self { inner, remote_addr }
    }
}

impl Decoder for RemoteAddrDecoder {
    fn decode(&self, line: &str) -> Result<Record, &'static str> {
        let mut record = self.inner.decode(line)?;
        record.remote_addr = Some(self.remote_addr.clone());
        Ok(record)
    }
}
