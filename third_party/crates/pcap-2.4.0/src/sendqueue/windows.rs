//! WinPcap/npcap sendqueue support module.
//!
//! Sending individual packets through WinPcap/npcap can be stunningly slow, since a user-to-kernel
//! transition is required for each packet transfer.  To alleviate this there's support for
//! queueing up a batch of packets in userland, requiring only a single transition to kernel to
//! transmit them all.

use std::convert::TryInto;
use std::io::IoSlice;
use std::ptr::NonNull;

use crate::{
    capture::{Active, Capture},
    raw, Error,
};

/// Representation of a batch of packets that can be transferred in a single call using
/// [`SendQueue::transmit()`].
pub struct SendQueue(NonNull<raw::pcap_send_queue>);

/// Indicate whether to send packets as quickly as possible or delay the relative amount of time
/// between packet header timestamps between packet transmissions.
pub enum SendSync {
    /// Ignore timestamps; send packets as quickly as possible.
    Off = 0,

    /// Use the time difference between packets to delay between packet transmissions.
    ///
    /// # Notes
    /// The internal (n/win)pcap implementations may implement the delay as a busy-wait loop.
    On = 1,
}

#[inline]
fn make_pkthdr(ts: Option<std::time::Duration>, len: u32) -> raw::pcap_pkthdr {
    raw::pcap_pkthdr {
        ts: if let Some(ts) = ts {
            libc::timeval {
                // tv_sec is currently i32 in libc when building for Windows
                tv_sec: ts.as_secs() as i32,
                tv_usec: ts.subsec_micros() as i32,
            }
        } else {
            libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            }
        },
        caplen: len,
        len,
    }
}

impl SendQueue {
    /// Create a new `SendQueue` object with a maximum capacity of `memsize`.
    ///
    /// The buffer size `memsize` must be able to contain both packet headers and actual packet
    /// contents.
    ///
    /// Applications that need to precalculate exact buffer sizes can use [`packet_header_size()`](crate::packet_header_size())
    /// to get the size of the header that is implicitly added along with each packet.
    pub fn new(memsize: u32) -> Result<Self, Error> {
        let squeue = unsafe { raw::pcap_sendqueue_alloc(memsize) };
        let squeue = NonNull::new(squeue).ok_or(Error::InsufficientMemory)?;

        Ok(Self(squeue))
    }

    pub fn maxlen(&self) -> u32 {
        unsafe { self.0.as_ref().maxlen }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn len(&self) -> u32 {
        unsafe { self.0.as_ref().len }
    }

    /// Add a packet to the queue.
    ///
    /// The `ts` argument only needs to be a `Some()` value if the transmission mode will be
    /// synchronous when calling [`SendQueue::transmit()`].
    pub fn queue(&mut self, ts: Option<std::time::Duration>, buf: &[u8]) -> Result<(), Error> {
        let len = buf.len().try_into().ok().ok_or(Error::BufferOverflow)?;

        let pkthdr = make_pkthdr(ts, len);

        let ph = &pkthdr as *const _;
        let res = unsafe { raw::pcap_sendqueue_queue(self.0.as_ptr(), ph, buf.as_ptr()) };
        if res == -1 {
            return Err(Error::InsufficientMemory);
        }

        Ok(())
    }

    /// Add a (potentially) scattered packet to the queue.
    ///
    /// ```
    /// use std::io::IoSlice;
    /// use pcap::sendqueue::SendQueue;
    /// let dstmac: [u8; 6] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
    /// let srcmac: [u8; 6] = [0, 0, 0, 0, 0, 0];
    /// let ethtype: [u8; 2] = [0x12, 0x34];
    /// let payload: [u8; 5] = [0x00, 0x01, 0x02, 0x03, 0x04];
    /// let iov = [
    ///   IoSlice::new(&dstmac),
    ///   IoSlice::new(&srcmac),
    ///   IoSlice::new(&ethtype),
    ///   IoSlice::new(&payload),
    /// ];
    /// let mut sq = SendQueue::new(1024*1024).unwrap();
    /// sq.queue_sg(None, &iov).unwrap();
    /// ```
    pub fn queue_sg(
        &mut self,
        ts: Option<std::time::Duration>,
        iov: &[IoSlice<'_>],
    ) -> Result<(), Error> {
        // Calculate the total packet size from the scatter/gather list.
        let pktsize: usize = iov.iter().map(|b| b.len()).sum();

        // Make sure there's enough room for packet header and (assembled) packet.
        // Note: It is assumed that len cannot exceed maxlen.  This invariant must be upheld by
        // all methods implemented by SendQueue.
        let remain = (self.maxlen() - self.len()) as usize;
        let need = std::mem::size_of::<raw::pcap_pkthdr>() + pktsize;
        if remain < need {
            return Err(Error::BufferOverflow);
        }

        // SAFETY:
        // At this point it is know that the internal sendqueue buffer will fit the packet data,
        // and as such any further buffer length validations are not needed.

        let pktlen = pktsize.try_into().ok().ok_or(Error::BufferOverflow)?;

        // Generate a raw packet header and get a pointer to it.
        let pkthdr = make_pkthdr(ts, pktlen);
        let rawhdr = &pkthdr as *const _ as *const u8;

        // Get a raw pointer to the current write location in sendqueue's internal buffer.
        let rawsq = unsafe { self.0.as_mut() };
        let sqbuf = rawsq.buffer as *mut u8;
        let bufoffs = rawsq.len.try_into().ok().ok_or(Error::BufferOverflow)?;
        let mut wbuf = unsafe { sqbuf.offset(bufoffs) };

        // Copy packet header into the sendqueue's buffer
        let mut lastlen = std::mem::size_of::<raw::pcap_pkthdr>();
        unsafe {
            std::ptr::copy_nonoverlapping(rawhdr, wbuf, lastlen);
        }

        // Iterate over scatter/gather list and copy each entry into the sendqueue's raw buffer
        for b in iov {
            // Get a write pointer at the next position
            let len = lastlen.try_into().ok().ok_or(Error::BufferOverflow)?;
            wbuf = unsafe { wbuf.offset(len) };

            unsafe {
                std::ptr::copy_nonoverlapping(b.as_ptr(), wbuf, b.len());
            }

            lastlen = b.len();
        }

        // 'len' is used as write cursor
        rawsq.len += need as u32;

        Ok(())
    }

    /// Transmit the contents of the queue.
    ///
    /// If entire queue was transmitted successfully the queue will be automatically reset.
    ///
    /// If `sync` is set to `SendSync::On` the difference between packet header timestamps
    /// will be used as a delay between sending each packet.  If `SendSync::Off` is used the packets
    /// will be transmitted with no delay between packets.
    pub fn transmit(&mut self, dev: &mut Capture<Active>, sync: SendSync) -> Result<(), Error> {
        let res =
            unsafe { raw::pcap_sendqueue_transmit(dev.as_ptr(), self.0.as_ptr(), sync as i32) };

        if res < self.len() {
            return unsafe { Err(Error::new(raw::pcap_geterr(dev.as_ptr()))) };
        } else {
            self.reset();
        }

        Ok(())
    }

    pub fn reset(&mut self) {
        unsafe { self.0.as_mut() }.len = 0;
    }
}

impl Drop for SendQueue {
    fn drop(&mut self) {
        unsafe {
            raw::pcap_sendqueue_destroy(self.0.as_ptr());
        }
    }
}
