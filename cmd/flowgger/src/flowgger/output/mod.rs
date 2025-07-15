mod debug_output;
#[cfg(feature = "file")]
mod file_output;
#[cfg(feature = "kafka-output")]
mod kafka_output;
#[cfg(feature = "tls")]
mod tls_output;
#[cfg(feature = "nats-output")]
mod nats_output;

#[cfg(feature = "nats-output")]
pub use self::nats_output::NATSOutput;

pub use self::debug_output::DebugOutput;
#[cfg(feature = "file")]
pub use self::file_output::FileOutput;
#[cfg(feature = "kafka-output")]
pub use self::kafka_output::KafkaOutput;
#[cfg(feature = "tls")]
pub use self::tls_output::TlsOutput;

use crate::flowgger::merger::Merger;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};

pub trait Output {
    /// Start the output processor
    ///
    /// # Parameters
    /// - 'arx':    Synchronized data receiver
    /// - 'merger': Optional merger, specifying how to frame the data.
    ///   i.e. adding an EOL or split after specified size
    ///
    fn start(&self, arx: Arc<Mutex<Receiver<Vec<u8>>>>, merger: Option<Box<dyn Merger>>);
}
