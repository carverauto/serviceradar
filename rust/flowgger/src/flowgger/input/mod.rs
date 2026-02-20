#[cfg(feature = "file")]
mod file;
#[cfg(feature = "redis-input")]
mod redis_input;
mod stdin_input;
mod tcp;
#[cfg(feature = "tls")]
mod tls;
#[cfg(all(feature = "syslog", not(test)))]
mod udp_input;
#[cfg(test)]
pub mod udp_input;

#[cfg(feature = "file")]
pub use self::file::FileInput;
#[cfg(feature = "redis-input")]
pub use self::redis_input::RedisInput;
pub use self::stdin_input::StdinInput;
pub use self::tcp::tcp_input::TcpInput;
#[cfg(feature = "coroutines")]
pub use self::tcp::tcpco_input::TcpCoInput;
#[cfg(feature = "tls")]
pub use self::tls::tls_input::TlsInput;
#[cfg(feature = "coroutines")]
pub use self::tls::tlsco_input::TlsCoInput;
#[cfg(feature = "syslog")]
pub use self::udp_input::UdpInput;

use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use std::sync::mpsc::SyncSender;

pub trait Input {
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    );
}
