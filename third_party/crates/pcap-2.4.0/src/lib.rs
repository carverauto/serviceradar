//! pcap is a packet capture library available on Linux, Windows and Mac. This
//! crate supports creating and configuring capture contexts, sniffing packets,
//! sending packets to interfaces, listing devices, and recording packet captures
//! to pcap-format dump files.
//!
//! # Capturing packets
//! The easiest way to open an active capture handle and begin sniffing is to
//! use `.open()` on a `Device`. You can obtain the "default" device using
//! `Device::lookup()`, or you can obtain the device(s) you need via `Device::list()`.
//!
//! ```no_run
//! use pcap::Device;
//!
//! let mut cap = Device::lookup().unwrap().unwrap().open().unwrap();
//!
//! while let Ok(packet) = cap.next_packet() {
//!     println!("received packet! {:?}", packet);
//! }
//!
//! ```
//!
//! `Capture`'s `.next_packet()` will produce a `Packet` which can be dereferenced to access the
//! `&[u8]` packet contents.
//!
//! # Custom configuration
//!
//! You may want to configure the `timeout`, `snaplen` or other parameters for the capture
//! handle. In this case, use `Capture::from_device()` to obtain a `Capture<Inactive>`, and
//! proceed to configure the capture handle. When you're finished, run `.open()` on it to
//! turn it into a `Capture<Active>`.
//!
//! ```no_run
//! use pcap::{Device, Capture};
//!
//! let main_device = Device::lookup().unwrap().unwrap();
//! let mut cap = Capture::from_device(main_device).unwrap()
//!                   .promisc(true)
//!                   .snaplen(5000)
//!                   .open().unwrap();
//!
//! while let Ok(packet) = cap.next_packet() {
//!     println!("received packet! {:?}", packet);
//! }
//! ```
//!
//! # Abstracting over different capture types
//!
//! You can abstract over live captures (`Capture<Active>`) and file captures
//! (`Capture<Offline>`) using generics and the [`Activated`] trait, for example:
//!
//! ```
//! use pcap::{Activated, Capture};
//!
//! fn read_packets<T: Activated>(mut capture: Capture<T>) {
//!     while let Ok(packet) = capture.next_packet() {
//!         println!("received packet! {:?}", packet);
//!     }
//! }
//! ```

#![cfg_attr(docsrs, feature(doc_cfg))]

use std::ffi::{self, CStr};
use std::fmt;

use self::Error::*;

mod capture;
mod codec;
mod device;
mod linktype;
mod packet;

#[cfg(not(windows))]
pub use capture::activated::open_raw_fd;
pub use capture::{
    activated::{
        iterator::PacketIter, BpfInstruction, BpfProgram, BreakLoop, Direction, Savefile, Stat,
    },
    inactive::TimestampType,
    {Activated, Active, Capture, Dead, Inactive, Offline, Precision, State},
};
pub use codec::PacketCodec;
pub use device::{Address, ConnectionStatus, Device, DeviceFlags, IfFlags};
pub use linktype::Linktype;
pub use packet::{Packet, PacketHeader};

#[deprecated(note = "Renamed to TimestampType")]
/// An old name for `TimestampType`, kept around for backward-compatibility.
pub type TstampType = TimestampType;

mod raw;

#[cfg(windows)]
#[cfg_attr(docsrs, doc(cfg(windows)))]
pub mod sendqueue;

#[cfg(feature = "capture-stream")]
mod stream;
#[cfg(feature = "capture-stream")]
#[cfg_attr(docsrs, doc(cfg(feature = "capture-stream")))]
pub use stream::PacketStream;

/// An error received from pcap
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// The underlying library returned invalid UTF-8
    MalformedError(std::str::Utf8Error),
    /// The underlying library returned a null string
    InvalidString,
    /// The unerlying library returned an error
    PcapError(String),
    /// The linktype was invalid or unknown
    InvalidLinktype,
    /// The timeout expired while reading from a live capture
    TimeoutExpired,
    /// No more packets to read from the file
    NoMorePackets,
    /// Must be in non-blocking mode to function
    NonNonBlock,
    /// There is not sufficent memory to create a dead capture
    InsufficientMemory,
    /// An invalid input string (internal null)
    InvalidInputString,
    /// An IO error occurred
    IoError(std::io::ErrorKind),
    #[cfg(not(windows))]
    /// An invalid raw file descriptor was provided
    InvalidRawFd,
    /// Errno error
    ErrnoError(errno::Errno),
    /// Buffer size overflows capacity
    BufferOverflow,
}

impl Error {
    unsafe fn new(ptr: *const libc::c_char) -> Error {
        match cstr_to_string(ptr) {
            Err(e) => e as Error,
            Ok(string) => PcapError(string.unwrap_or_default()),
        }
    }

    fn with_errbuf<T, F>(func: F) -> Result<T, Error>
    where
        F: FnOnce(*mut libc::c_char) -> Result<T, Error>,
    {
        let mut errbuf = [0i8; 256];
        func(errbuf.as_mut_ptr() as _)
    }
}

unsafe fn cstr_to_string(ptr: *const libc::c_char) -> Result<Option<String>, Error> {
    let string = if ptr.is_null() {
        None
    } else {
        Some(CStr::from_ptr(ptr as _).to_str()?.to_owned())
    };
    Ok(string)
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            MalformedError(ref e) => write!(f, "libpcap returned invalid UTF-8: {e}"),
            InvalidString => write!(f, "libpcap returned a null string"),
            PcapError(ref e) => write!(f, "libpcap error: {e}"),
            InvalidLinktype => write!(f, "invalid or unknown linktype"),
            TimeoutExpired => write!(f, "timeout expired while reading from a live capture"),
            NonNonBlock => write!(f, "must be in non-blocking mode to function"),
            NoMorePackets => write!(f, "no more packets to read from the file"),
            InsufficientMemory => write!(f, "insufficient memory"),
            InvalidInputString => write!(f, "invalid input string (internal null)"),
            IoError(ref e) => write!(f, "io error occurred: {e:?}"),
            #[cfg(not(windows))]
            InvalidRawFd => write!(f, "invalid raw file descriptor provided"),
            ErrnoError(ref e) => write!(f, "libpcap os errno: {e}"),
            BufferOverflow => write!(f, "buffer size too large"),
        }
    }
}

// Using description is deprecated. Remove in next version.
impl std::error::Error for Error {
    fn description(&self) -> &str {
        match *self {
            MalformedError(..) => "libpcap returned invalid UTF-8",
            PcapError(..) => "libpcap FFI error",
            InvalidString => "libpcap returned a null string",
            InvalidLinktype => "invalid or unknown linktype",
            TimeoutExpired => "timeout expired while reading from a live capture",
            NonNonBlock => "must be in non-blocking mode to function",
            NoMorePackets => "no more packets to read from the file",
            InsufficientMemory => "insufficient memory",
            InvalidInputString => "invalid input string (internal null)",
            IoError(..) => "io error occurred",
            #[cfg(not(windows))]
            InvalidRawFd => "invalid raw file descriptor provided",
            ErrnoError(..) => "internal error, providing errno",
            BufferOverflow => "buffer size too large",
        }
    }

    fn cause(&self) -> Option<&dyn std::error::Error> {
        match *self {
            MalformedError(ref e) => Some(e),
            _ => None,
        }
    }
}

impl From<ffi::NulError> for Error {
    fn from(_: ffi::NulError) -> Error {
        InvalidInputString
    }
}

impl From<std::str::Utf8Error> for Error {
    fn from(obj: std::str::Utf8Error) -> Error {
        MalformedError(obj)
    }
}

impl From<std::io::Error> for Error {
    fn from(obj: std::io::Error) -> Error {
        obj.kind().into()
    }
}

impl From<std::io::ErrorKind> for Error {
    fn from(obj: std::io::ErrorKind) -> Error {
        IoError(obj)
    }
}

/// Return size of a commonly used packet header.
///
/// On Windows this packet header is implicitly added to send queues, so this size must be known
/// if an application needs to precalculate the exact send queue buffer size.
pub const fn packet_header_size() -> usize {
    std::mem::size_of::<raw::pcap_pkthdr>()
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::{ffi::CString, io};

    use super::*;

    #[test]
    fn test_error_invalid_utf8() {
        let bytes: [u8; 8] = [0x78, 0xfe, 0xe9, 0x89, 0x00, 0x00, 0xed, 0x4f];
        let error = unsafe { Error::new(&bytes as *const _ as _) };
        assert!(matches!(error, Error::MalformedError(_)));
    }

    #[test]
    fn test_error_null() {
        let error = unsafe { Error::new(std::ptr::null()) };
        assert_eq!(error, Error::PcapError("".to_string()));
    }

    #[test]
    #[allow(deprecated)]
    fn test_errors() {
        let mut errors: Vec<Error> = vec![];

        let bytes: [u8; 8] = [0x78, 0xfe, 0xe9, 0x89, 0x00, 0x00, 0xed, 0x4f];
        let cstr = unsafe { CStr::from_ptr(&bytes as *const _ as _) };

        errors.push(cstr.to_str().unwrap_err().into());
        errors.push(Error::InvalidString);
        errors.push(Error::PcapError("git rekt".to_string()));
        errors.push(Error::InvalidLinktype);
        errors.push(Error::TimeoutExpired);
        errors.push(Error::NoMorePackets);
        errors.push(Error::NonNonBlock);
        errors.push(Error::InsufficientMemory);
        errors.push(CString::new(b"f\0oo".to_vec()).unwrap_err().into());
        errors.push(io::Error::new(io::ErrorKind::Interrupted, "error").into());
        #[cfg(not(windows))]
        errors.push(Error::InvalidRawFd);
        errors.push(Error::ErrnoError(errno::Errno(125)));
        errors.push(Error::BufferOverflow);

        for error in errors.iter() {
            assert!(!error.to_string().is_empty());
            assert!(!error.description().is_empty());
            match error {
                Error::MalformedError(_) => assert!(error.cause().is_some()),
                _ => assert!(error.cause().is_none()),
            }
        }
    }

    #[test]
    fn test_packet_size() {
        assert_eq!(
            packet_header_size(),
            std::mem::size_of::<raw::pcap_pkthdr>()
        );
    }
}
