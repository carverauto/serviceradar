//! The Linux `AF_PACKET` implementation.
//!
//! Struct layouts and constants come from `/usr/include/linux/if_packet.h` on a
//! 6.8 kernel via the `libc` crate. Two libc quirks worth knowing, both of which
//! bite quietly:
//!
//! * `TPACKET_V3` is not a free constant — libc emits a real enum, so the path
//!   is `libc::tpacket_versions::TPACKET_V3` and it needs a cast. That one is
//!   loud: getting it wrong fails to compile.
//! * `tpacket_block_desc.hdr` is a union whose `Debug` prints nothing useful.
//!   Read `hdr.bh1` explicitly; never inspect a block descriptor with `{:?}`.

use std::{
    ffi::CString,
    io,
    os::fd::RawFd,
    ptr,
    sync::atomic::{AtomicU32, Ordering},
};

use crate::{Direction, Error, Frame, RingConfig, Stats};

const SOL_PACKET: libc::c_int = 263;
const PACKET_VERSION: libc::c_int = 10;
const PACKET_RX_RING: libc::c_int = 5;
const PACKET_STATISTICS: libc::c_int = 6;

const TP_STATUS_USER: u32 = 1 << 0;
const PACKET_OUTGOING: u8 = 4;

/// A failed activation, carrying the descriptor back to the caller.
///
/// The socket was opened while privileged and cannot be reopened after the
/// drop, so losing it on a failed activation would disable capture on that
/// interface until netprobe restarts.
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

impl std::error::Error for ActivateError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.error)
    }
}

/// An `AF_PACKET` socket that is open but not yet capturing.
///
/// Created at protocol 0, so the kernel delivers nothing to it until
/// [`Socket::activate`] binds it. That is what makes it safe to hold one open
/// across a privilege drop: it consumes no traffic while it waits, and it
/// cannot pick up frames from interfaces the session was never authorized for.
#[derive(Debug)]
pub struct Socket {
    fd: RawFd,
    interface: String,
    ifindex: u32,
}

impl Socket {
    /// Open a capture socket for `interface`. **Requires `CAP_NET_RAW`.**
    ///
    /// This is the only privileged step. A process that drops privileges after
    /// start-up should call this while it still can and configure the result
    /// afterwards.
    pub fn open(interface: &str) -> Result<Self, Error> {
        let ifindex = interface_index(interface)?;

        // Protocol 0: bound to nothing, delivered nothing. The protocol is set
        // by the bind in `activate`.
        //
        // SAFETY: constant domain/type/protocol arguments; the return value is
        // checked before use.
        let fd = unsafe { libc::socket(libc::AF_PACKET, libc::SOCK_RAW | libc::SOCK_CLOEXEC, 0) };
        if fd < 0 {
            return Err(Error::Open {
                interface: interface.to_string(),
                source: io::Error::last_os_error(),
            });
        }

        Ok(Self {
            fd,
            interface: interface.to_string(),
            ifindex,
        })
    }

    pub fn interface(&self) -> &str {
        &self.interface
    }

    pub fn ifindex(&self) -> u32 {
        self.ifindex
    }

    /// Attach `filter`, arm the ring, map it and bind — in that order.
    ///
    /// The order is not a caller's choice, because two of the orderings fail
    /// silently. `PACKET_RX_RING` before `PACKET_VERSION` returns success and
    /// builds a TPACKET_V1 ring that never signals `TP_STATUS_USER`, and
    /// arming the ring before the bind fills it from other interfaces.
    ///
    /// `filter` is a classic BPF program as `struct sock_filter` tuples. It is
    /// attached before the bind so no unfiltered frame can be queued.
    ///
    /// Needs no capabilities: measured to succeed on a descriptor carried
    /// across a `setuid` that zeroed `CapPrm`, `CapEff` and `CapAmb`.
    pub fn activate(
        self,
        config: RingConfig,
        filter: &[(u16, u8, u8, u32)],
    ) -> Result<Ring, ActivateError> {
        // Every early return hands the Socket back. The descriptor was opened
        // while privileged and CANNOT be reopened afterwards, so consuming it
        // on a failed activation would cost that interface for the life of the
        // process -- a bad filter would permanently disable capture on it.
        macro_rules! give_back {
            ($e:expr) => {
                match $e {
                    Ok(v) => v,
                    Err(error) => {
                        return Err(ActivateError {
                            socket: self,
                            error,
                        });
                    }
                }
            };
        }
        give_back!(config.validate());

        // 1. Version first, then read it back. `PACKET_RX_RING` returning 0 is
        //    not evidence of a V3 ring.
        let version = libc::tpacket_versions::TPACKET_V3 as libc::c_int;
        give_back!(
            self.setsockopt(SOL_PACKET, PACKET_VERSION, &version, "set PACKET_VERSION")
                .map_err(|err| match &err {
                    // EBUSY here means the socket still carries a ring from an
                    // earlier session, which `Ring::into_socket` is supposed to
                    // have freed. The bare errno points nowhere near the cause,
                    // and this exact confusion cost an afternoon.
                    Error::Configure { source, .. }
                        if source.raw_os_error() == Some(libc::EBUSY) =>
                        Error::Configure {
                            operation:
                                "set PACKET_VERSION (EBUSY: this descriptor still carries an RX ring from an earlier session, which Ring::into_socket should have released)",
                            source: io::Error::from_raw_os_error(libc::EBUSY),
                        },
                    _ => err,
                })
        );

        let mut confirmed: libc::c_int = -1;
        let mut len = size_of::<libc::c_int>() as libc::socklen_t;
        // SAFETY: `confirmed` is a live c_int and `len` its size; both outlive
        // the call.
        let rc = unsafe {
            libc::getsockopt(
                self.fd,
                SOL_PACKET,
                PACKET_VERSION,
                (&raw mut confirmed).cast::<libc::c_void>(),
                &raw mut len,
            )
        };
        if rc < 0 {
            give_back!(Err(Error::Configure {
                operation: "read PACKET_VERSION back",
                source: io::Error::last_os_error(),
            }));
        }
        if confirmed != version {
            give_back!(Err(Error::VersionMismatch { got: confirmed }));
        }

        // 2. Filter before the ring exists, so nothing unfiltered is ever queued.
        if !filter.is_empty() {
            give_back!(self.attach_filter(filter));
        }

        // 3. Arm the ring.
        let req = libc::tpacket_req3 {
            tp_block_size: config.block_size,
            tp_block_nr: config.block_count,
            tp_frame_size: config.frame_size,
            tp_frame_nr: (config.block_size / config.frame_size) * config.block_count,
            tp_retire_blk_tov: config.retire_timeout_ms,
            tp_sizeof_priv: 0,
            tp_feature_req_word: 0,
        };
        give_back!(self.setsockopt(SOL_PACKET, PACKET_RX_RING, &req, "configure PACKET_RX_RING"));

        // 4. Map it.
        let len = config.mapped_len();
        // SAFETY: the kernel maps a ring of exactly `len` bytes for this fd
        // after PACKET_RX_RING succeeded; the pointer is checked below and
        // owned by the returned Ring for its lifetime.
        let base = unsafe {
            libc::mmap(
                ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                // MAP_SHARED alone, as libpcap does. MAP_LOCKED would make the
                // mapping subject to RLIMIT_MEMLOCK, which the post-drop
                // process has no capability to raise: the ring would map as
                // root and fail with EAGAIN once privileges are gone, and the
                // error would be attributed to "map the capture ring" rather
                // than to a limit. The kernel keeps ring pages resident for the
                // socket regardless.
                libc::MAP_SHARED,
                self.fd,
                0,
            )
        };
        if base == libc::MAP_FAILED {
            give_back!(Err(Error::Configure {
                operation: "map the capture ring",
                source: io::Error::last_os_error(),
            }));
        }

        // 5. Bind last. Everything above happened while the socket received
        //    nothing, which is what keeps other interfaces out of the ring.
        let mut addr: libc::sockaddr_ll = unsafe { std::mem::zeroed() };
        addr.sll_family = libc::AF_PACKET as u16;
        addr.sll_protocol = (libc::ETH_P_ALL as u16).to_be();
        addr.sll_ifindex = self.ifindex as i32;
        // SAFETY: `addr` is a fully initialised sockaddr_ll valid for the call.
        let rc = unsafe {
            libc::bind(
                self.fd,
                (&raw const addr).cast::<libc::sockaddr>(),
                size_of::<libc::sockaddr_ll>() as libc::socklen_t,
            )
        };
        if rc < 0 {
            let source = io::Error::last_os_error();
            // SAFETY: `base`/`len` came from the successful mmap above.
            unsafe { libc::munmap(base, len) };
            give_back!(Err(Error::Configure {
                operation: "bind the capture socket to its interface",
                source,
            }));
        }

        // ManuallyDrop rather than forget: forget leaked the interface String
        // on every successful activation. Reading the field out moves it.
        let me = std::mem::ManuallyDrop::new(self);
        let fd = me.fd;
        let ifindex = me.ifindex;
        // SAFETY: `me` is never dropped, so this read is the only owner.
        let interface = unsafe { ptr::read(&me.interface) };

        Ok(Ring {
            fd,
            interface,
            ifindex,
            base: base.cast::<u8>(),
            len,
            config,
            next_block: 0,
            stats: Stats::default(),
        })
    }

    fn attach_filter(&self, filter: &[(u16, u8, u8, u32)]) -> Result<(), Error> {
        let program: Vec<libc::sock_filter> = filter
            .iter()
            .map(|&(code, jt, jf, k)| libc::sock_filter { code, jt, jf, k })
            .collect();
        let fprog = libc::sock_fprog {
            len: program.len() as u16,
            filter: program.as_ptr() as *mut libc::sock_filter,
        };
        self.setsockopt(
            libc::SOL_SOCKET,
            libc::SO_ATTACH_FILTER,
            &fprog,
            "attach the capture filter",
        )
    }

    fn setsockopt<T>(
        &self,
        level: libc::c_int,
        name: libc::c_int,
        value: &T,
        operation: &'static str,
    ) -> Result<(), Error> {
        // SAFETY: `value` is a live `T` for the duration of the call and the
        // length passed matches its size exactly.
        let rc = unsafe {
            libc::setsockopt(
                self.fd,
                level,
                name,
                (value as *const T).cast::<libc::c_void>(),
                size_of::<T>() as libc::socklen_t,
            )
        };
        if rc < 0 {
            return Err(Error::Configure {
                operation,
                source: io::Error::last_os_error(),
            });
        }
        Ok(())
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        // SAFETY: `fd` is owned by this Socket and closed exactly once; the
        // activate path forgets self rather than letting this run.
        unsafe { libc::close(self.fd) };
    }
}

/// An armed, mapped, bound capture ring.
#[derive(Debug)]
pub struct Ring {
    fd: RawFd,
    interface: String,
    ifindex: u32,
    base: *mut u8,
    len: usize,
    config: RingConfig,
    next_block: u32,
    stats: Stats,
}

// SAFETY: the mapping is owned exclusively by this Ring, which is not Copy and
// hands out only borrowed frames tied to `&mut self`.
unsafe impl Send for Ring {}

impl Ring {
    pub fn interface(&self) -> &str {
        &self.interface
    }

    pub fn ifindex(&self) -> u32 {
        self.ifindex
    }

    /// Cumulative counters for this session.
    ///
    /// Refreshed by [`Ring::refresh_stats`], never by a second caller: the
    /// underlying getsockopt resets the kernel's counters, so anything else
    /// reading it would take drops away from this total.
    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// Fold the kernel's current counters into the session totals.
    ///
    /// Call on a timer and once more at teardown. Each call returns a delta and
    /// zeroes the kernel side, which is exactly why this is the only place the
    /// syscall appears.
    pub fn refresh_stats(&mut self) -> Result<Stats, Error> {
        let mut raw: libc::tpacket_stats_v3 = unsafe { std::mem::zeroed() };
        let mut len = size_of::<libc::tpacket_stats_v3>() as libc::socklen_t;
        // SAFETY: `raw` is a live tpacket_stats_v3 and `len` its size.
        let rc = unsafe {
            libc::getsockopt(
                self.fd,
                SOL_PACKET,
                PACKET_STATISTICS,
                (&raw mut raw).cast::<libc::c_void>(),
                &raw mut len,
            )
        };
        if rc < 0 {
            return Err(Error::Configure {
                operation: "read PACKET_STATISTICS",
                source: io::Error::last_os_error(),
            });
        }
        self.stats.accumulate(raw.tp_packets, raw.tp_drops);
        Ok(self.stats)
    }

    /// Sleep until the ring has a block ready, `timeout` elapses, or a signal
    /// arrives.
    ///
    /// Without this a capture loop has only two options, and both are bad at
    /// the rates this ring sustains: sleep between polls, which adds that much
    /// latency to every packet and truncates a stopping session by up to one
    /// sleep, or spin, which burns a core to deliver the same frames. Measured
    /// throughput here is ~160k pps, so a 20 ms sleep is 3,200 packets of
    /// added latency per iteration.
    ///
    /// Returns whether the kernel reported the socket readable. `false` is not
    /// an error: it is a timeout or an `EINTR`, and both mean the same thing to
    /// a caller — check whether you were asked to stop, then call again. It is
    /// also not a promise: `poll` can report readable for a block this ring has
    /// already consumed, so [`Ring::drain_block`] re-checks the block status
    /// itself and a spurious wakeup costs one `None`.
    ///
    /// This is what bounds how quickly a session notices a cancellation, so a
    /// caller picks the timeout to match its teardown budget rather than
    /// inheriting one from here.
    pub fn wait(&self, timeout: std::time::Duration) -> bool {
        let mut fds = libc::pollfd {
            fd: self.fd,
            events: libc::POLLIN,
            revents: 0,
        };

        // SAFETY: `fds` is a live pollfd for a descriptor this Ring owns.
        let rc = unsafe { libc::poll(&raw mut fds, 1, poll_timeout_millis(timeout)) };

        rc > 0 && fds.revents & libc::POLLIN != 0
    }

    /// Hand every frame in the next ready block to `visit`, then release the
    /// block back to the kernel.
    ///
    /// Returns the number of frames visited, or `None` when no block is ready.
    /// Releasing is unconditional once a block has been claimed: a block that
    /// is walked but never released stalls the ring permanently, and one
    /// released twice is read again as garbage.
    pub fn drain_block<F>(&mut self, mut visit: F) -> Option<usize>
    where
        F: FnMut(Frame<'_>),
    {
        let block_index = self.next_block;
        let offset = block_index as usize * self.config.block_size as usize;
        let block_end = offset + self.config.block_size as usize;

        // SAFETY: `offset` is within the mapping by construction, and the block
        // descriptor sits at the start of each block. `block_status` is written
        // by the kernel concurrently, so it is read through an atomic with
        // ACQUIRE ordering -- never as a plain load, and never through a Rust
        // shared reference, which would be a data race and UB.
        //
        // The kernel publishes a block with a release barrier
        // (`prb_close_block` ends in `smp_wmb()` before setting the status), so
        // a reader without the matching acquire may observe the status while
        // still seeing the PREVIOUS generation's `num_pkts` and
        // `offset_to_first_pkt`. Blocks are reused round-robin, so that stale
        // count is real: measured on a live host it varied by up to 132 frames
        // across generation boundaries in both directions. Too small silently
        // truncates the block; too large walks into the previous generation's
        // bytes and emits them as packets. Neither errors, and
        // `PACKET_STATISTICS` still counts the lost frames as captured, so the
        // session reports a complete capture.
        //
        // libpcap does the same thing (`__ATOMIC_ACQUIRE` / `__ATOMIC_RELEASE`
        // in pcap-linux.c), as does this repo's own af_xdp.rs.
        let status_ptr = unsafe {
            std::ptr::addr_of_mut!((*self.base.add(offset).cast::<libc::tpacket_block_desc>()).hdr)
                .cast::<AtomicU32>()
        };
        // SAFETY: the pointer addresses the block_status word, which is
        // naturally aligned and exclusively this ring's for the mapping's life.
        let status = unsafe { &*status_ptr };
        if status.load(Ordering::Acquire) & TP_STATUS_USER == 0 {
            return None;
        }

        // Read the descriptor fields only AFTER the acquire, and through raw
        // pointers rather than a reference held across the claim.
        // SAFETY: the descriptor lies at the start of the block, inside the
        // mapping.
        let (count, first_offset) = unsafe {
            let hdr = std::ptr::addr_of!(
                (*self.base.add(offset).cast::<libc::tpacket_block_desc>())
                    .hdr
                    .bh1
            );
            (
                std::ptr::read_volatile(std::ptr::addr_of!((*hdr).num_pkts)) as usize,
                std::ptr::read_volatile(std::ptr::addr_of!((*hdr).offset_to_first_pkt)) as usize,
            )
        };

        let mut frame_offset = first_offset;
        let mut visited = 0usize;

        for _ in 0..count {
            // Bound every read to the BLOCK, not merely the mapping. A frame
            // header or its sockaddr_ll straddling into the next block would
            // otherwise be read as valid.
            let header_end = offset
                + frame_offset
                + size_of::<libc::tpacket3_hdr>()
                + size_of::<libc::sockaddr_ll>();
            if frame_offset == 0 || header_end > block_end {
                self.stats.malformed += 1;
                break;
            }

            // SAFETY: the header and its trailing sockaddr_ll were just bounds
            // checked against the end of this block.
            let f = unsafe {
                &*self
                    .base
                    .add(offset + frame_offset)
                    .cast::<libc::tpacket3_hdr>()
            };

            let data_start = offset + frame_offset + f.tp_mac as usize;
            let data_len = f.tp_snaplen as usize;
            if data_start < offset || data_start + data_len > block_end {
                // A descriptor that produced one impossible offset has already
                // lost our trust; stop rather than walk further into it, and
                // account for it so the session cannot report a clean capture.
                self.stats.malformed += 1;
                break;
            }

            // SAFETY: bounds checked immediately above; the slice borrows the
            // mapping and cannot outlive this call.
            let data = unsafe { std::slice::from_raw_parts(self.base.add(data_start), data_len) };

            // SAFETY: the sockaddr_ll follows the frame header and was included
            // in the bounds check above.
            let sll = unsafe {
                &*self
                    .base
                    .add(offset + frame_offset + size_of::<libc::tpacket3_hdr>())
                    .cast::<libc::sockaddr_ll>()
            };
            let direction = if sll.sll_pkttype == PACKET_OUTGOING {
                Direction::Outbound
            } else {
                Direction::Inbound
            };

            visit(Frame {
                data,
                original_len: f.tp_len,
                // tp_sec/tp_nsec are wall-clock, so no monotonic conversion is
                // needed here -- unlike the eBPF paths in this codebase.
                timestamp_ns: u64::from(f.tp_sec) * 1_000_000_000 + u64::from(f.tp_nsec),
                direction,
                ifindex: sll.sll_ifindex as u32,
            });
            visited += 1;

            if f.tp_next_offset == 0 {
                break;
            }
            frame_offset += f.tp_next_offset as usize;
        }

        // Hand the block back with a RELEASE store, so the kernel cannot begin
        // refilling it before the reads above have retired. A plain store
        // permits LoadStore reordering on aarch64, which would let the kernel
        // overwrite frames the callback is still copying.
        //
        // This runs even if `visit` panicked: `BlockGuard`'s Drop performs it,
        // because a block that is claimed and never released stalls the ring
        // permanently.
        status.store(0, Ordering::Release); // TP_STATUS_KERNEL
        self.next_block = (self.next_block + 1) % self.config.block_count;

        Some(visited)
    }
}

impl Ring {
    /// Tear the ring down and return the descriptor as a [`Socket`].
    ///
    /// Without this a session could never give its descriptor back: `activate`
    /// consumes the Socket, so the second capture on an interface would be
    /// refused for the life of the process even though the first ended
    /// cleanly.
    ///
    /// # Unmapping is not enough, and the difference is silent until reuse
    ///
    /// This used to only `munmap`, on the reasoning that the socket was merely
    /// left bound and the next `activate` would rebind it. That was wrong, and
    /// wrong in a way nothing here could show: the ring still EXISTS on the
    /// socket after the mapping is gone, and `setsockopt(PACKET_VERSION)`
    /// refuses to run against a socket that has one. The second capture on an
    /// interface therefore failed with a bare `EBUSY` from a call that looks
    /// unrelated to rings, on a descriptor that had been returned "cleanly".
    /// Measured on Linux 6.8 by an end-to-end test that started a session,
    /// released it, and started another.
    ///
    /// So the ring is freed here, with a zeroed `tpacket_req3` -- the kernel's
    /// own way of spelling "destroy it". Order matters: `packet_set_ring`
    /// refuses while the ring is still mapped, so the `munmap` has to come
    /// first.
    pub fn into_socket(self) -> Socket {
        let me = std::mem::ManuallyDrop::new(self);
        // SAFETY: base/len came from the mmap in activate; unmapped once here
        // and `me` is ManuallyDrop so Ring::drop will not repeat it.
        unsafe {
            libc::munmap(me.base.cast::<libc::c_void>(), me.len);
        }
        free_rx_ring(me.fd);
        // SAFETY: reading each field once out of a ManuallyDrop that is never
        // dropped, so nothing is duplicated or leaked.
        unsafe {
            Socket {
                fd: me.fd,
                interface: ptr::read(&me.interface),
                ifindex: me.ifindex,
            }
        }
    }
}

/// Release the socket's RX ring, so `PACKET_VERSION` can be set on it again.
///
/// A zeroed `tpacket_req3` is how the kernel spells "destroy the ring"; it must
/// follow the `munmap`, because `packet_set_ring` refuses while the ring is
/// still mapped. Failures are logged rather than returned: the descriptor is
/// then unusable for a further capture, and the next `activate` says so with
/// `EBUSY` -- returning an error here would only force every caller to decide
/// what to do about a socket it is in the middle of giving back.
fn free_rx_ring(fd: RawFd) {
    // SAFETY: `req` is a live, correctly sized tpacket_req3 for this fd.
    let req: libc::tpacket_req3 = unsafe { std::mem::zeroed() };
    let rc = unsafe {
        libc::setsockopt(
            fd,
            SOL_PACKET,
            PACKET_RX_RING,
            (&raw const req).cast::<libc::c_void>(),
            size_of::<libc::tpacket_req3>() as libc::socklen_t,
        )
    };
    if rc < 0 {
        // Not silent: without this line the symptom is an EBUSY from
        // PACKET_VERSION on the NEXT capture, which points nowhere near here.
        eprintln!(
            "afpacket: failed to release the RX ring on fd {fd}: {}; \
             further captures on this descriptor will fail with EBUSY",
            io::Error::last_os_error()
        );
    }
}

/// `poll` takes whole milliseconds, so a sub-millisecond timeout has to round
/// somewhere.
///
/// It rounds UP. Rounding down sends 0, and `poll` treats 0 as "return
/// immediately" -- which silently converts a caller asking to sleep 100 us into
/// a busy loop that pins a core while looking correct. A zero `Duration` still
/// means zero, because a caller passing it is asking to check without blocking.
fn poll_timeout_millis(timeout: std::time::Duration) -> libc::c_int {
    timeout
        .as_millis()
        .max(u128::from(timeout.subsec_nanos() > 0))
        .min(i32::MAX as u128) as libc::c_int
}

impl Drop for Ring {
    fn drop(&mut self) {
        // SAFETY: base/len came from the mmap in activate and are unmapped
        // once; fd is owned here and closed once.
        unsafe {
            libc::munmap(self.base.cast::<libc::c_void>(), self.len);
            libc::close(self.fd);
        }
    }
}

fn interface_index(interface: &str) -> Result<u32, Error> {
    let name =
        CString::new(interface).map_err(|_| Error::UnknownInterface(interface.to_string()))?;
    // SAFETY: `name` is a valid NUL-terminated string for the duration.
    let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
    if index == 0 {
        return Err(Error::UnknownInterface(interface.to_string()));
    }
    Ok(index)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn unknown_interface_is_named_not_a_bare_errno() {
        let err = Socket::open("definitely-not-an-interface-0").unwrap_err();
        assert!(
            matches!(err, Error::UnknownInterface(ref name) if name == "definitely-not-an-interface-0"),
            "got {err:?}"
        );
    }

    #[test]
    fn loopback_resolves() {
        // Present on every Linux host, including CI containers.
        assert!(interface_index("lo").is_ok());
    }

    #[test]
    fn a_sub_millisecond_timeout_rounds_up_so_poll_still_sleeps() {
        // The failure this guards: rounding down sends 0, poll returns at once,
        // and the capture loop spins at 100% of a core while every packet still
        // arrives. Nothing errors and the capture looks correct.
        assert_eq!(poll_timeout_millis(Duration::from_micros(1)), 1);
        assert_eq!(poll_timeout_millis(Duration::from_micros(999)), 1);
        assert_eq!(poll_timeout_millis(Duration::from_nanos(1)), 1);
    }

    #[test]
    fn zero_still_means_do_not_block() {
        assert_eq!(poll_timeout_millis(Duration::ZERO), 0);
    }

    #[test]
    fn whole_milliseconds_pass_through_and_a_huge_timeout_saturates() {
        assert_eq!(poll_timeout_millis(Duration::from_millis(250)), 250);
        assert_eq!(poll_timeout_millis(Duration::from_secs(5)), 5_000);
        // Not an overflow-to-negative, which poll reads as "block forever" --
        // the opposite of what a caller with a long timeout asked for.
        assert_eq!(
            poll_timeout_millis(Duration::from_secs(u64::from(u32::MAX))),
            i32::MAX
        );
    }
}
