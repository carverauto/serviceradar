//! Utilities for sending batches of packets.

#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
pub use windows::{SendQueue, SendSync};
