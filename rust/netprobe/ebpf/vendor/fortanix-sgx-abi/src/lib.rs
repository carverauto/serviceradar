/* Copyright (c) Fortanix, Inc.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
#![cfg_attr(
    not(feature = "docs"),
    doc = "**You are viewing the internals documentation."
)]
#![cfg_attr(
    not(feature = "docs"),
    doc = "You probably want to compile the documentation with the “docs” feature.**"
)]
#![cfg_attr(not(feature = "docs"), doc = "---")]
//! The Fortanix SGX ABI (compiler target `x86_64-fortanix-unknown-sgx`) is an
//! interface for Intel SGX enclaves. It is a small yet functional interface
//! suitable for writing larger enclaves. In contrast to other enclave
//! interfaces, this interface is primarily designed for running entire
//! applications in an enclave.
//!
//! The Fortanix SGX ABI specification consists of two parts:
//!
//! 1. The calling convention (see FORTANIX-SGX-ABI.md)
//! 2. The execution environment and [usercalls](struct.Usercalls.html) (this document)
//!
//! Whereas the calling convention describes how information is passed to and
//! from the enclave, this document ascribes meaning to those values.
//!
//! The execution environment and usercalls have been designed with the
//! following goals in mind:
//!
//! 1. *Compatible with most Rust code:* Rust code that doesn't link to other C
//!    libraries and that doesn't use files (see no. 5) should compile out of
//!    the box.
//! 2. *Designed for SGX:* The SGX environment is unique and not compatible
//!    with other application environments out there. The primitives specified
//!    in this document are designed to work well with SGX, not to be similar
//!    to or compatible with primitives known from other environments.
//! 3. *Designed for network services:* The most interesting usecase for SGX is
//!    to run applications remotely in an untrusted environment, e.g. the
//!    cloud. Therefore, there is a primary focus on supporting functionality
//!    needed in those situations.
//! 4. *No filesystem:* Encrypted filesystems are hard. Especially in SGX,
//!    consistency and freshness are big concerns. In this initial version,
//!    there is no filesystem support, which is fine for most network services,
//!    which would want to keep their state with a database service anyway.
//!    Support might be added in the future.
//! 5. *Not POSIX:* The POSIX API is huge and contains many elements that are
//!    not directly supported by the SGX instruction set, such as fork and
//!    mmap. It is explicitly a non-goal of this specification to support all
//!    of POSIX.
//! 6. *Designed to be portable:* Enclaves don't interact directly with the OS,
//!    so there should be no need to recompile an enclave when running it with
//!    a different OS. This specification does not require any particular
//!    primitives or behavior from the OS.
//!
//! Like on regular operating systems, there are two types of enclaves:
//! *executable*-type and *library*-type. The main difference between the two
//! different types is how the enclave may be entered. Once an enclave TCS is
//! entered, the different types act virtually identically. More information on
//! the two different types, TCSs, and enclave entry may be found in the
//! [`entry`](entry/index.html) module.
//!
//! Once an enclave TCS is entered, it may performs *synchronous usercalls* as
//! described in the calling convention. The TCS maintains its execution state
//! between doing a usercall and returning from the usercall. Only when the TCS
//! exits, either through a non-usercall exit or through the
//! [`exit`](struct.Usercalls.html#method.exit) usercall, is the TCS state
//! destroyed. This is depicted in the following diagram.
//!
//! ![Enclave execution lifecycle](https://edp.fortanix.com/img/docs/enclave-execution-lifecycle.png)
//!
//! Enclaves may also perform *asynchronous usercalls*. This is detailed in the
//! [`async`](async/index.html) module. Most usercalls can be submitted either
//! synchronously or asynchronously.
#![allow(unused)]
#![no_std]
#![cfg_attr(feature = "rustc-dep-of-std", allow(internal_features))]
#![cfg_attr(feature = "rustc-dep-of-std", feature(staged_api))]
#![cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
#![doc(html_logo_url = "https://edp.fortanix.com/img/docs/edp-logo.svg",
       html_favicon_url = "https://edp.fortanix.com/favicon.ico",
       html_root_url = "https://edp.fortanix.com/docs/api/")]

use core::ptr::NonNull;
use core::sync::atomic::{AtomicU64, AtomicUsize};

macro_rules! invoke_with_abi_spec [
    ( $m:ident ) => [ $m![

/// Specification of TCS and entry function requirements.
///
/// Once an enclave has called the
/// [`exit`](../../struct.Usercalls.html#method.exit) usercall, if userspace
/// enters a TCS normally, the enclave must panic. If userspace returns a
/// usercall on a TCS, the enclave may decide whether to handle it normally or
/// to panic.
pub mod entry {
    /// Specifies the entry points for libraries.
    ///
    /// The specification for library support is **experimental** and is
    /// subject to change.
    ///
    /// When a user application wishes to call into the enclave library,
    /// userspace may use any available TCS. Libraries may keep state between
    /// invocations, but the library must not assume that subsequent calls will
    /// go to the same TCS.
    ///
    /// The use of asynchronous usercalls with libraries is not recommended, as
    /// userspace will not be able to wake up the appropriate thread in a
    /// multi-threaded library scenario.
    ///
    /// Automatically launching threads using the
    /// [`launch_thread`](../../struct.Usercalls.html#method.launch_thread)
    /// usercall is not supported. Libraries that want to leverage
    /// multi-threading must rely on application support to call into the
    /// enclave from different threads.
    pub mod library {
        /// The entry point of every TCS.
        ///
        /// If a library wishes to expose multiple different functions, it must
        /// implement this by multiplexing on one of the input parameters. It
        /// is recommended to use `p1` for this purpose.
        ///
        /// The `_ignore` parameter may be set to any value by userspace. The
        /// value observed by the enclave may be different from the value
        /// passed by userspace and must therefore be ignored by the enclave.
        pub fn entry(p1: u64, p2: u64, p3: u64, _ignore: u64, p4: u64, p5: u64) -> (u64, u64) { unimplemented!() }
    }

    /// Specifies the entry points for executables.
    pub mod executable {
        use ByteBuffer;

        /// The main entry point of the enclave. This will be the entry point
        /// of the first TCS.
        ///
        /// The enclave must not return from this entry. Instead, it must call
        /// the [`exit`](../../struct.Usercalls.html#method.exit) usercall. If
        /// the enclave does return from this TCS, and userspace subsequently
        /// re-enters this TCS, the enclave must panic.
        ///
        /// Arbitrary “command-line arguments” may be passed in from userspace.
        /// The enclave must ensure that the all buffers pointed to are
        /// outside the enclave. The enclave should deallocate each
        /// [`ByteBuffer`] as specified by the type. The enclave should
        /// deallocate the main buffer by calling
        /// [`free`]`(args, len * size_of::<ByteBuffer>, 1)`.
        ///
        /// [`free`]: ../../struct.Usercalls.html#method.free
        /// [`ByteBuffer`]: ../../struct.ByteBuffer.html
        pub fn main_entry(args: *const ByteBuffer, len: usize) -> ! { unimplemented!() }

        /// The entry point of additional threads of the enclave, for non-first
        /// TCSs.
        ///
        /// When returning from this TCS, userspace may re-enter this TCS after
        /// another call to [`launch_thread`].
        ///
        /// The enclave must keep track of whether it expects another thread to
        /// be launched, e.g. by keeping track of how many times it called
        /// [`launch_thread`]. If a TCS with this entry point is entered even
        /// though the enclave didn't request it, the enclave must panic.
        ///
        /// [`launch_thread`]: ../../struct.Usercalls.html#method.launch_thread
        pub fn thread_entry() { unimplemented!() }
    }
}

/// An arbitrary-sized buffer of bytes in userspace, allocated by userspace.
///
/// This type is used when userspace may return arbitrary-sized data from a
/// usercall. When reading from the buffer, if `len` is not `0`, the enclave
/// must ensure the entire buffer is in the user memory range. Once the enclave
/// is done with the buffer, it should deallocate the buffer buffer by calling
/// [`free`]`(data, len, 1)`.
///
/// If `len` is `0`, the enclave should ignore `data`. It should not call
/// `free`.
///
/// [`free`]: ./struct.Usercalls.html#method.launch_thread
#[repr(C)]
#[derive(Copy, Clone)]
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub struct ByteBuffer {
    pub data: *const u8,
    pub len: usize
}

#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
unsafe impl Send for ByteBuffer {}

/// Error code definitions and space allocation.
///
/// Only non-zero positive values are valid errors. The variants are designed
/// to map to [std::io::ErrorKind]. See the source for the value mapping.
///
/// [std::io::ErrorKind]: https://doc.rust-lang.org/std/io/enum.ErrorKind.html
#[repr(i32)]
#[derive(Copy, Clone, Eq, PartialEq)]
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub enum Error {
    PermissionDenied  =        0x01,
    NotFound          =        0x02,
    Interrupted       =        0x04,
    WouldBlock        =        0x0b,
    AlreadyExists     =        0x11,
    InvalidInput      =        0x16,
    BrokenPipe        =        0x20,
    AddrInUse         =        0x62,
    AddrNotAvailable  =        0x63,
    ConnectionAborted =        0x67,
    ConnectionReset   =        0x68,
    NotConnected      =        0x6b,
    TimedOut          =        0x6e,
    ConnectionRefused =        0x6f,
    InvalidData       = 0x2000_0000,
    WriteZero         = 0x2000_0001,
    UnexpectedEof     = 0x2000_0002,
    /// This value is reserved for `Other`, but all undefined values also map
    /// to `Other`.
    Other             = 0x3fff_ffff,
    /// Start of the range of values reserved for user-defined errors.
    UserRangeStart    = 0x4000_0000,
    /// End (inclusive) of the range of values reserved for user-defined errors.
    UserRangeEnd      = 0x7fff_ffff,
}

/// A value indicating that the operation was successful.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const RESULT_SUCCESS: Result = 0;

/// The first return value of usercalls that might fail.
///
/// [`RESULT_SUCCESS`](constant.RESULT_SUCCESS.html) or an error code from the
/// [`Error`](enum.Error.html) type.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub type Result = i32;

/// The list of all usercalls.
///
/// *This is not a real structure, it's just a convenient way to group
/// functions with `rustdoc`.*
///
/// The usercall number is passed in the first register. Up to 4 arguments may
/// be passed in the remaining registers. Unspecified arguments and return
/// values must be 0. Userspace must check the arguments and the enclave must
/// check the return value.
///
/// The usercall number may be one of the predefined numbers associated with
/// one of the usercalls defined below, or, if bit
/// [`USERCALL_USER_DEFINED`](constant.USERCALL_USER_DEFINED.html) is set, an
/// otherwise arbitrary number with an application-defined meaning.
///
/// Raw pointers must always point to user memory. When receiving raw pointers
/// from userspace, the enclave must verify that the entire pointed-to memory
/// space is outside the enclave memory range. It must then copy all data in
/// user memory to enclave memory before operating on it.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub struct Usercalls;

/// Usercall numbers with this bit set will never be defined by this specification.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const USERCALL_USER_DEFINED: u64 = 0x8000_0000;

/// A file descriptor.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub type Fd = u64;

/// Standard input file descriptor. Input read this way is not secure.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const FD_STDIN: Fd = 0;
/// Standard output file descriptor. This is not a secure output channel.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const FD_STDOUT: Fd = 1;
/// Standard error file descriptor. This is not a secure output channel.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const FD_STDERR: Fd = 2;

/// # Streams
///
/// The enclave must not assume anything about data read or written using these
/// calls. Data written may be piped directly to `/dev/null` by userspace, or
/// it may be published in the local newspaper. Similarly, data read may be
/// arbitrarily deleted, inserted, or changed. The enclave must use additional
/// security primitives such as sealing or TLS to obtain stronger guarantees.
///
/// When a stream is read from by multiple threads simultaneously, the read
/// calls may be serialized in any order. This means the data returned by a
/// read call appeared that way in the stream, and every single byte in the
/// stream will be read and be read only once. However, the order in which all
/// stream data is returned is not defined. The same applies when
/// simultaneously submitting multiple read calls for the same stream
/// asynchronously. This all applies similarly to writing to a stream.
///
/// To make sure to be able to re-assemble the stream, the enclave can take one
/// of the following approaches:
///
/// 1. Submit all read calls to a single stream on a single thread.
/// 2. Serializing read calls by synchronizing access to a single stream.
///
/// In addition, the enclave should use cryptographic integrity protection of
/// the stream data to ensure the stream data has not been tampered with.
impl Usercalls {
    /// Read up to `len` bytes from stream `fd`.
    ///
    /// `buf` must point to a buffer in userspace with a size of at least
    /// `len`. On a successful return, the number of bytes written is returned.
    /// The enclave must check that the returned length is no more than `len`.
    /// If `len` is `0`, this call should block until the stream is ready for
    /// reading. If `len` is `0` or end of stream is reached, `0` may be
    /// returned.
    ///
    /// The enclave may mix calls to [`read`](#method.read) and
    /// [`read_alloc`](#method.read_alloc).
    pub fn read(fd: Fd, buf: *mut u8, len: usize) -> (Result, usize) { unimplemented!() }

    /// Read some data from stream `fd`, letting the callee choose the amount.
    ///
    /// `buf` must point to a [`ByteBuffer`] in userspace, and `buf.data` must
    /// contain `null`. On success, userspace will allocate memory for the read
    /// data and populate `ByteBuffer` appropriately. The enclave must handle
    /// and deallocate the buffer according to the `ByteBuffer` documentation.
    ///
    /// Since every read operation using this usercall requires two usercalls,
    /// it is recommended to only call this usercall asynchronously.
    ///
    /// The enclave may mix calls to [`read`](#method.read) and
    /// [`read_alloc`](#method.read_alloc).
    ///
    /// [`ByteBuffer`]: ./struct.ByteBuffer.html
    pub fn read_alloc(fd: Fd, buf: *mut ByteBuffer) -> Result { unimplemented!() }

    /// Write up to `len` bytes to stream `fd`.
    ///
    /// `buf` must point to a buffer in userspace with a size of at least
    /// `len`. On a successful return, the number of bytes written is returned.
    /// The enclave must check that the returned length is no more than `len`.
    /// If `len` is `0`, this call should block until the stream is ready for
    /// writing. If `len` is `0` or the stream is closed, `0` may be returned.
    pub fn write(fd: Fd, buf: *const u8, len: usize) -> (Result, usize) { unimplemented!() }

    /// Flush stream `fd`, ensuring that all intermediately buffered contents
    /// reach their destination.
    pub fn flush(fd: Fd) -> Result { unimplemented!() }

    /// Close stream `fd`.
    ///
    /// Once the stream is closed, no further data may be read or written.
    /// Userspace may reuse the `fd` in the future for a different stream.
    pub fn close(fd: Fd) { unimplemented!() }
}

/// # Networking
///
/// In keeping with the design goals for this specification, the
/// networking/socket interface doesn't use `sockaddr` types and doesn't
/// have a separate API for name resolution. Userspace can't be trusted to
/// do name resolution correctly, and even if it did, *userspace can't be
/// trusted to actually connect streams to the correct address* specified by
/// the enclave. Therefore, addresses specified should merely be treated as a
/// suggestion, and additional measures must be taken by an enclave to verify
/// the stream is connected to the correct peer, e.g. TLS.
///
/// The networking API works with strings as addresses. All byte buffers
/// representing network addresses should contain a valid UTF-8 string. The
/// enclave should panic if it is passed an invalid string by userspace. It is
/// suggested that userspace supports at least the following notations:
///
/// * `hostname:port-number` (e.g. `example.com:123`)
/// * `dotted-octet-ipv4-address:port-number` (e.g. `192.0.2.1:123`)
/// * `[ipv6-address]:port-number` (e.g. `[2001:db8::1]:123`)
///
/// Additionally, other forms may be accepted, for example service names:
///
/// * `fully-qualified-service-name` (e.g. `_example._tcp.example.com`)
/// * `address:service-name` (e.g. `address:example`)
///
/// # Errors
///
/// Networking calls taking an address may return the [`InvalidInput`] error if
/// the address could not be interpreted by userspace.
///
/// [`InvalidInput`]: enum.Error.html#variant.InvalidInput
impl Usercalls {
    /// Setup a listening socket.
    ///
    /// The socket is bound to the address specified in `addr`. `addr` must be
    /// a buffer in user memory with a size of at least `len`.
    ///
    /// On success, a file descriptor is returned which may be passed to
    /// [`accept_stream`](#method.accept_stream) or [`close`](#method.close).
    ///
    /// The enclave may optionally request the local socket address be returned
    /// in `local_addr`. On success, if `local_addr` is not NULL, userspace
    /// will allocate memory for the address and populate [`ByteBuffer`]
    /// appropriately. The enclave must handle and deallocate the buffer
    /// according to the `ByteBuffer` documentation.
    ///
    /// The enclave must not make any security decisions based on the local
    /// address received.
    ///
    /// [`ByteBuffer`]: ./struct.ByteBuffer.html
    pub fn bind_stream(addr: *const u8, len: usize, local_addr: *mut ByteBuffer) -> (Result, Fd) { unimplemented!() }

    /// Accept a new connection from a listening socket.
    ///
    /// `fd` should be a file descriptor previously returned from
    /// [`bind_stream`](#method.bind_stream).
    ///
    /// The enclave may optionally request the local or peer socket addresses
    /// be returned in `local_addr` or `peer_addr`, respectively. On success,
    /// if `local_addr` and/or `peer_addr` is not NULL, userspace will allocate
    /// memory for the address and populate the respective [`ByteBuffer`]
    /// appropriately.
    ///
    /// The enclave must handle and deallocate each buffer according to the
    /// `ByteBuffer` documentation.
    ///
    /// The enclave must not make any security decisions based on the local or
    /// peer address received.
    ///
    /// [`ByteBuffer`]: ./struct.ByteBuffer.html
    pub fn accept_stream(fd: Fd, local_addr: *mut ByteBuffer, peer_addr: *mut ByteBuffer) -> (Result, Fd) { unimplemented!() }

    /// Create a new stream connection to the specified address.
    ///
    /// The enclave may optionally request the local or peer socket addresses
    /// be returned in `local_addr` or `peer_addr`, respectively. On success,
    /// if `local_addr` and/or `peer_addr` is not NULL, userspace will allocate
    /// memory for the address and populate the respective [`ByteBuffer`]
    /// appropriately.
    ///
    /// The enclave must handle and deallocate each buffer according to the
    /// `ByteBuffer` documentation.
    ///
    /// The enclave must not make any security decisions based on the local or
    /// peer address received.
    ///
    /// [`ByteBuffer`]: ./struct.ByteBuffer.html
    pub fn connect_stream(addr: *const u8, len: usize, local_addr: *mut ByteBuffer, peer_addr: *mut ByteBuffer) -> (Result, Fd) { unimplemented!() }
}

/// The absolute address of a TCS in the current enclave.
///
/// To ensure a TCS struct will never be located at address 0, a TCS struct should not be located
/// at the beginning of an enclave.
// FIXME: `u8` should be some `extern type` instead.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub type Tcs = NonNull<u8>;

/// An event that will be triggered by userspace when the usercall queue is not
/// or no longer full.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const EV_USERCALLQ_NOT_FULL: u64 = 0b0000_0000_0000_0001;
/// An event that will be triggered by userspace when the return queue is not
/// or no longer empty.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const EV_RETURNQ_NOT_EMPTY: u64 = 0b0000_0000_0000_0010;
/// An event that enclaves can use for synchronization.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const EV_UNPARK: u64 = 0b0000_0000_0000_0100;
/// An event that will be triggered by userspace when the cancel queue is not
/// or no longer full.
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const EV_CANCELQ_NOT_FULL: u64 = 0b0000_0000_0000_1000;

#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const WAIT_NO: u64 = 0;
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
pub const WAIT_INDEFINITE: u64 = !0;

/// # Execution control
///
/// ## TCS event queues
///
/// Userspace will maintain a queue for each running TCS with events to be
/// delivered. Each event is characterized by a bitset with at least one bit
/// set. Userspace or the enclave (using the `send` usercall) can put events on
/// this queue.
/// If the enclave isn't waiting for an event when an event is queued, the event
/// remains on the queue until it delivered to the enclave in a later `wait`
/// usercall. If an enclave is waiting for an event, and the queue contains an
/// event that is a subset of the waited-for event mask, that event is removed
/// from the queue and execution control is returned to the enclave.
///
/// Events not defined in this specification should not be generated.
impl Usercalls {
    /// In [executables](entry/executable/index.html), this will instruct
    /// userspace to enter another TCS in another thread. This TCS should have
    /// the [`thread_entry`] entrypoint. As documented in [`thread_entry`], the
    /// enclave should keep track of how many threads it launched and reconcile
    /// this with the number of entries into [`thread_entry`]. If no free TCSes
    /// are immediately available, this may return an error.
    ///
    /// This function will never be successful in [libraries]. See the
    /// [`library`] documentation on how to use threads with libraries.
    ///
    /// [`thread_entry`]: entry/executable/fn.thread_entry.html
    /// [libraries]: entry/library/index.html
    /// [`library`]: entry/library/index.html
    pub fn launch_thread() -> Result { unimplemented!() }

    /// Signals to userspace that this enclave needs to be destroyed.
    ///
    /// The enclave must not rely on userspace to terminate other threads still
    /// running. Similarly, the enclave must not trust that it will no longer
    /// be entered by userspace, and it must safeguard against that in the
    /// entrypoints.
    ///
    /// If `panic` is set to `true`, the enclave has exited due to a panic
    /// condition. If the enclave was running in debug mode, the enclave may
    /// have output a debug message according to the calling convention.
    pub fn exit(panic: bool) -> ! { unimplemented!() }

    /// Wait for an event to occur, or check if an event is currently pending.
    ///
    /// `timeout` must be [`WAIT_NO`] or [`WAIT_INDEFINITE`] or a positive
    /// value smaller than u64::MAX specifying number of nanoseconds to wait.
    ///
    /// If `timeout` is [`WAIT_INDEFINITE`], this call will block and return
    /// once a matching event is queued on this TCS. If `timeout` is
    /// [`WAIT_NO`], this call will return immediately, and the return value
    /// will indicate if an event was pending. If it was, it has been dequeued.
    /// If not, the [`WouldBlock`] error value will be returned. If `timeout`
    /// is a value other than [`WAIT_NO`] and [`WAIT_INDEFINITE`], this call
    /// will block until either a matching event is queued in which case the
    /// return value will indicate the event, or the timeout is reached in
    /// which case the [`TimedOut`] error value will be returned.
    ///
    /// A matching event is one whose bits are equal to or a subset of
    /// `event_mask`. If `event_mask` is `0`, this call will never return due
    /// to an event. If `timeout` is also [`WAIT_INDEFINITE`], this call will
    /// simply never return.
    ///
    /// Enclaves must not assume that this call only returns in response to
    /// valid events generated by the enclave. This call may return for invalid
    /// event sets, or before `timeout` has expired even though no event is
    /// pending.
    ///
    /// When executed synchronously, this gives userspace an opportunity to
    /// schedule something else in a cooperative multitasking environment.
    ///
    /// When executed asynchronously, this may trigger an
    /// [`EV_RETURNQ_NOT_EMPTY`] event on this or other TCSes. It is not
    /// recommended to execute this call asynchronously with a `timeout` value
    /// other than [`WAIT_NO`].
    ///
    /// [`WAIT_NO`]: constant.WAIT_NO.html
    /// [`WAIT_INDEFINITE`]: constant.WAIT_INDEFINITE.html
    /// [`EV_RETURNQ_NOT_EMPTY`]: constant.EV_RETURNQ_NOT_EMPTY.html
    /// [`WouldBlock`]: enum.Error.html#variant.WouldBlock
    /// [`TimedOut`]: enum.Error.html#variant.TimedOut
    pub fn wait(event_mask: u64, timeout: u64) -> (Result, u64) { unimplemented!() }

    /// Send an event to one or all TCSes.
    ///
    /// If `tcs` is `None`, send the event `event_set` to all TCSes of this
    /// enclave, otherwise, send it to the TCS specified in `tcs`.
    ///
    /// # Error
    ///
    /// This will return the [`InvalidInput`] error if `tcs` is set but doesn't
    /// specify a valid TCS address.
    ///
    /// [`InvalidInput`]: enum.Error.html#variant.InvalidInput
    pub fn send(event_set: u64, tcs: Option<Tcs>) -> Result { unimplemented!() }
}

#[repr(C)]
#[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
#[derive(Copy, Clone, Debug, Default)]
pub struct InsecureTimeInfo {
    pub version: u64,
    pub frequency: u64,
}

/// # Miscellaneous
impl Usercalls {
    /// This returns the number of nanoseconds since midnight UTC on January 1,
    /// 1970\. The enclave must not rely on the accuracy of this time for
    /// security purposes, such as checking credential expiry or preventing
    /// rollback.
    pub fn insecure_time() -> (u64, *const InsecureTimeInfo) { unimplemented!() }
}

/// # Memory
///
/// The enclave must not use any memory outside the enclave, except for memory
/// explicitly returned from usercalls. You can obtain arbitrary memory in
/// userspace using [`alloc`](#method.alloc).
impl Usercalls {
    /// Request user memory.
    ///
    /// Request an allocation in user memory of size `size` and with alignment
    /// `align`. If successful, a pointer to this memory will be returned. The
    /// enclave must check the pointer is correctly aligned and that the entire
    /// range of memory pointed to is outside the enclave.
    ///
    /// It is an error to call this function with `size` equal to `0`.
    pub fn alloc(size: usize, alignment: usize) -> (Result, *mut u8) { unimplemented!() }

    /// Free user memory.
    ///
    /// This must be called to deallocate memory in userspace. The pointer
    /// `ptr` must have previously been returned by a usercall. The `size` and
    /// `alignment` specified must exactly match what was allocated. This
    /// function must be called exactly once for each user memory buffer.
    ///
    /// Calling this function with `size` equal to `0` is a no-op.
    pub fn free(ptr: *mut u8, size: usize, alignment: usize) { unimplemented!() }
}

/// Asynchronous usercall specification.
///
/// An asynchronous usercall allows an enclave to submit a usercall without
/// exiting the enclave. This is necessary since enclave entries and exits are
/// slow (see academic work on [SCONE], [HotCalls]). In addition, the enclave
/// can perform other tasks while it waits for the usercall to complete. Those
/// tasks may include issuing other usercalls, either synchronously or
/// asynchronously.
///
/// Two [MPSC queues] are [allocated per enclave]. One queue is used by any
/// enclave thread to submit usercalls to userspace. Userspace will read the
/// calls from this queue and handle them. Another queue is used by userspace
/// to return completed usercalls to the enclave.
///
/// Each call is identified by an enclave-specified `id`. Userspace must
/// provide the same `id` when returning. The enclave must not submit multiple
/// concurrent usercalls with the same `id`, but it may reuse an `id` once the
/// original usercall with that `id` has returned.
///
/// An optional third queue can be used to cancel usercalls. To cancel an async
/// usercall, the enclave should send the usercall's id and number on this
/// queue. If the usercall has already been processed, the enclave may still
/// receive a successful result for the usercall. Otherwise, the userspace will
/// cancel the usercall's execution and return an [`Interrupted`] error on the
/// return queue to notify the enclave of the cancellation. Note that usercalls
/// that do not return [`Result`] cannot be cancelled and if the enclave sends
/// a cancellation for such a usercall, the userspace should simply ignore it.
/// Additionally, userspace may choose to ignore cancellations for non-blocking
/// usercalls. Userspace should be able to cancel a usercall that has been sent
/// by the enclave but not yet received by the userspace, i.e. if cancellation
/// is received before the usercall itself. To avoid keeping such cancellations
/// forever and preventing the enclave from re-using usercall ids, userspace
/// should synchronize cancel queue with the usercall queue such that the
/// following invariant is maintained: whenever the enclave writes an id to the
/// usercall or cancel queue, the enclave will not reuse that id until the
/// usercall queue's read pointer has advanced to the write pointer at the time
/// the id was written.
///
/// *TODO*: Add diagram.
///
/// [MPSC queues]: struct.FifoDescriptor.html
/// [allocated per enclave]: ../struct.Usercalls.html#method.async_queues
/// [SCONE]: https://www.usenix.org/conference/osdi16/technical-sessions/presentation/arnautov
/// [HotCalls]: http://www.ofirweisse.com/ISCA17_Ofir_Weisse.pdf
/// [`Interrupted`]: enum.Error.html#variant.Interrupted
/// [`Result`]: type.Result.html
///
/// # Enclave/userspace synchronization
///
/// When the enclave needs to wait on a queue, it executes the [`wait()`]
/// usercall synchronously, specifying [`EV_USERCALLQ_NOT_FULL`],
/// [`EV_RETURNQ_NOT_EMPTY`], [`EV_CANCELQ_NOT_FULL`], or any combination
/// thereof in the `event_mask`. Userspace will wake
/// any or all threads waiting on the appropriate event when it is triggered.
///
/// When userspace needs to wait on a queue, it will park the current thread
/// (or do whatever else is appropriate for the synchronization model currently
/// in use by userspace). Any synchronous usercall will wake the blocked thread
/// (or otherwise signal that either queue is ready).
///
/// [`wait()`]: ../struct.Usercalls.html#method.wait
/// [`EV_USERCALLQ_NOT_FULL`]: ../constant.EV_USERCALLQ_NOT_FULL.html
/// [`EV_RETURNQ_NOT_EMPTY`]: ../constant.EV_RETURNQ_NOT_EMPTY.html
/// [`EV_CANCELQ_NOT_FULL`]: ../constant.EV_CANCELQ_NOT_FULL.html
pub mod async {
    use super::*;
    use core::sync::atomic::{AtomicU64, AtomicUsize};

    #[repr(C)]
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    pub struct WithId<T> {
        pub id: AtomicU64,
        pub data: T,
    }

    /// A usercall.
    /// The elements correspond to the RDI, RSI, RDX, R8, and R9 registers
    /// in the synchronous calling convention.
    #[repr(C)]
    #[derive(Copy, Clone, Default)]
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    pub struct Usercall(pub u64, pub u64, pub u64, pub u64, pub u64);

    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    impl From<Usercall> for (u64, u64, u64, u64, u64) {
        fn from(u: Usercall) -> Self {
            let Usercall(p1, p2, p3, p4, p5) = u;
            (p1, p2, p3, p4, p5)
        }
    }

    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    impl From<(u64, u64, u64, u64, u64)> for Usercall {
        fn from(p: (u64, u64, u64, u64, u64)) -> Self {
            Usercall(p.0, p.1, p.2, p.3, p.4)
        }
    }

    /// The return value of a usercall.
    /// The elements correspond to the RSI and RDX registers in the
    /// synchronous calling convention.
    #[repr(C)]
    #[derive(Copy, Clone, Default)]
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    pub struct Return(pub u64, pub u64);

    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    impl From<Return> for (u64, u64) {
        fn from(r: Return) -> Self {
            let Return(r1, r2) = r;
            (r1, r2)
        }
    }

    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    impl From<(u64, u64)> for Return {
        fn from(r: (u64, u64)) -> Self {
            Return(r.0, r.1)
        }
    }

    /// Cancel a usercall previously sent to userspace.
    #[repr(C)]
    #[derive(Copy, Clone, Default)]
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    pub struct Cancel;

    /// A circular buffer used as a FIFO queue with atomic reads and writes.
    ///
    /// The read offset is the element that was most recently read by the
    /// receiving end of the queue. The write offset is the element that was
    /// most recently written by the sending end. If the two offsets are equal,
    /// the queue is either empty or full.
    ///
    /// The size of the buffer is such that not all the bits of the offset are
    /// necessary to encode the current offset. The next highest unused bit is
    /// used to keep track of the number of times the offset has wrapped
    /// around. If the offsets are the same and the bit is the same in the read
    /// and write offsets, the queue is empty. If the bit is different in the
    /// read and write offsets, the queue is full.
    ///
    /// The following procedures will operate the queues in a multiple producer
    /// single consumer (MPSC) fashion.
    ///
    /// ## Push operation
    ///
    /// To push an element onto the queue:
    ///
    /// 1. Load the current offsets.
    /// 2. If the queue is full, wait, then go to step 1.
    /// 3. Add 1 to the write offset and do an atomic compare-and-swap (CAS)
    ///    with the current offsets. If the CAS was not successful, go to step
    ///    1\.
    /// 4. Write the data, then the `id`.
    /// 5. If the queue was empty in step 1, signal the reader to wake up.
    ///
    /// ## Pop operation
    ///
    /// To pop an element off the queue:
    ///
    /// 1. Load the current offsets.
    /// 2. If the queue is empty, wait, then go to step 1.
    /// 3. Add 1 to the read offset.
    /// 4. Read the `id` at the new read offset.
    /// 5. If `id` is `0`, go to step 4 (spin). Spinning is OK because data is
    ///    expected to be written imminently.
    /// 6. Read the data, then store `0` in the `id`.
    /// 7. Store the new read offset, retrieving the old offsets.
    /// 8. If the queue was full before step 7, signal the writer to wake up.
    #[repr(C)]
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    pub struct FifoDescriptor<T> {
        /// Pointer to the queue memory. Must have a size of
        /// `len * size_of::<WithId<T>>()` bytes and have alignment
        /// `align_of::<WithId<T>>`.
        pub data: *mut WithId<T>,
        /// The number of elements pointed to by `data`. Must be a power of two
        /// less than or equal to 2³¹.
        pub len: usize,
        /// Actually a `(u32, u32)` tuple, aligned to allow atomic operations
        /// on both halves simultaneously. The first element (low dword) is
        /// the read offset and the second element (high dword) is the write
        /// offset.
        pub offsets: *const AtomicUsize,
    }

    // not using `#[derive]` because that would require T: Clone
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    impl<T> Clone for FifoDescriptor<T> {
        fn clone(&self) -> Self {
            *self
        }
    }

    // not using `#[derive]` because that would require T: Copy
    #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
    impl<T> Copy for FifoDescriptor<T> {}

    /// # Asynchronous usercalls
    ///
    /// *Due to `rustdoc`, this section may appear at the top of the
    /// `Usercalls` documentation. You might want to read the other sections
    /// first and then come back to this one.*
    ///
    /// See also the [`async` module](async/index.html) documentation.
    impl Usercalls {
        /// Request FIFO queues for asynchronous usercalls. `usercall_queue`
        /// and `return_queue` must point to valid user memory with the correct
        /// size and alignment for their types. `cancel_queue` is optional, but
        /// if specified (not null) it must point to valid user memory with
        /// correct size and alignment.
        /// On return, userspace will have filled these structures with
        /// information about the queues. A single set of queues will be
        /// allocated per enclave. Once this usercall has returned successfully,
        /// calling this usercall again is equivalent to calling `exit(true)`.
        ///
        /// May fail if the platform does not support asynchronous usercalls.
        ///
        /// The enclave must ensure that the data pointed to in the fields of
        /// [`FifoDescriptor`] is outside the enclave.
        ///
        /// [`FifoDescriptor`]: async/struct.FifoDescriptor.html
        pub fn async_queues(
            usercall_queue: *mut FifoDescriptor<Usercall>,
            return_queue: *mut FifoDescriptor<Return>,
            cancel_queue: *mut FifoDescriptor<Cancel>
        ) -> Result { unimplemented!() }
    }
}

]; ] ];

// docs: Just render the docs verbatim
macro_rules! docs {
    ($($tt:tt)*) => ($($tt)*)
}

#[cfg(feature = "docs")]
invoke_with_abi_spec!(docs);

// types: flatten the module structure and ignore any items that are not types.
macro_rules! types {
    // flatten modules
    ($(#[$meta:meta])* pub mod $modname:ident { $($contents:tt)* } $($remainder:tt)*) =>
        { types!($($contents)*); types!($($remainder)*); };
    // ignore impls
    ($(#[$meta:meta])* impl Usercalls { $($contents:tt)* } $($remainder:tt)* ) =>
        { types!($($remainder)*); };
    // ignore `struct Usercalls`
    ($(#[$meta:meta])* pub struct Usercalls; $($remainder:tt)* ) =>
        { types!($($remainder)*); };
    // ignore free functions
    ($(#[$meta:meta])* pub fn $f:ident($($n:ident: $t:ty),*) $(-> $r:ty)* { unimplemented!() } $($remainder:tt)* ) =>
        { types!($($remainder)*); };
    // ignore use statements
    (use $($tt:tt)::*; $($remainder:tt)* ) =>
        { types!($($remainder)*); };
    // copy all other items verbatim
    ($item:item $($remainder:tt)*) =>
        { $item types!($($remainder)*);  };
    () => {};
}

#[cfg(not(feature = "docs"))]
invoke_with_abi_spec!(types);

// Define a macro that will call a second macro providing the list of all
// function declarations inside all `impl Usercalls` blocks.
macro_rules! define_invoke_with_usercalls {
    // collect all usercall function declarations in a list
    (@ [$($accumulated:tt)*] $(#[$meta1:meta])* impl Usercalls { $($(#[$meta2:meta])* pub fn $f:ident($($n:ident: $t:ty),*) $(-> $r:tt)* { unimplemented!() } )* } $($remainder:tt)* ) =>
        { define_invoke_with_usercalls!(@ [$($accumulated)* $(fn $f($($n: $t),*) $(-> $r)*;)*] $($remainder)*); };
    // visit modules
    (@ $accumulated:tt $(#[$meta:meta])* pub mod $modname:ident { $($contents:tt)* } $($remainder:tt)*) =>
        { define_invoke_with_usercalls!(@ $accumulated $($contents)* $($remainder)*); };
    // ignore all other items
    (@ $accumulated:tt $item:item $($remainder:tt)*) =>
        { define_invoke_with_usercalls!(@ $accumulated $($remainder)*);  };
    // Define the macro
    (@ $accumulated:tt) => {
        /// Call the macro `$m`, passing a semicolon-separated list of usercall
        /// function declarations.
        ///
        /// The passed in macro could for example use the following pattern:
        ///
        /// ```text
        /// ($(fn $f:ident($($n:ident: $t:ty),*) $(-> $r:tt)*; )*)
        /// ```
        #[macro_export]
        #[cfg_attr(feature = "rustc-dep-of-std", unstable(feature = "sgx_platform", issue = "56975"))]
        macro_rules! invoke_with_usercalls {
            ($m:ident) => { $m! $accumulated; }
        }
    };
    // start collection with an empty list
    ($($tt:tt)*) => {
        define_invoke_with_usercalls!(@ [] $($tt)*);
    }
}

#[cfg(not(feature = "docs"))]
invoke_with_abi_spec!(define_invoke_with_usercalls);
