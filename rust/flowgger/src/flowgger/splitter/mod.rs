#[cfg(feature = "capnp-recompile")]
mod capnp_splitter;
mod line_splitter;
mod nul_splitter;
mod syslen_splitter;

#[cfg(feature = "capnp-recompile")]
pub use self::capnp_splitter::CapnpSplitter;
pub use self::line_splitter::LineSplitter;
pub use self::nul_splitter::NulSplitter;
pub use self::syslen_splitter::SyslenSplitter;

use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use std::io::BufReader;
use std::sync::mpsc::SyncSender;

pub trait Splitter<T> {
    fn run(
        &self,
        buf_reader: BufReader<T>,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder>,
        encoder: Box<dyn Encoder>,
    );
}
