//! pcapng encoding for a capture session.
//!
//! A session emits a Section Header Block, one Interface Description Block per
//! captured interface, then a stream of Enhanced Packet Blocks. Callers chunk
//! the resulting bytes into `PcapngBlock.bytes` messages; a chunk boundary may
//! fall anywhere, because the reader treats the concatenation as the file.
//!
//! Almost every way to get this wrong produces a file that still opens. The
//! defects this module is written to avoid, each of which reads clean:
//!
//! * **Omitting `if_tsresol` while writing nanosecond timestamps is a 33-year
//!   time error.** The default resolution is 10^-6, so a reader divides a
//!   nanosecond counter by 1e6. A round-trip test through our own decoder
//!   cannot catch it, because our decoder would assume 10^-9 too — so
//!   [`tests`] asserts the literal option bytes.
//! * **A wrong LinkType is not an error.** Ethernet frames written under
//!   `LINKTYPE_RAW` (101) decode as garbage with exit 0. Note that 101 is
//!   exactly what this repo's two existing fixture writers use
//!   (`dpi.rs`, `fingerprint.rs`), so copy-paste lands you there. AF_PACKET
//!   delivers full Ethernet frames, so the value must be 1.
//! * **`SnapLen = 0` is not "unlimited"** to libpcap, which substitutes
//!   262144 and then hard-errors on anything larger. Declaring an honest
//!   snaplen above 262144 is worse: tcpdump silently discards the oversized
//!   packet and exits 0.
//! * **Re-emitting the SHB per chunk starts a new section**, resetting the
//!   interface table. The first packets print, then everything after fails —
//!   so a test that reads only the first packet passes.
//! * **`Original Packet Length < Captured Packet Length`** makes tcpdump drop
//!   the packet while exiting 0. From TPACKET_V3, captured is `tp_snaplen`
//!   and original is `tp_len`; swapping them is silent.

/// Block type magic for the Section Header Block, and the value a reader scans
/// for to find a section.
const BLOCK_TYPE_SHB: u32 = 0x0A0D_0D0A;
const BLOCK_TYPE_IDB: u32 = 0x0000_0001;
const BLOCK_TYPE_EPB: u32 = 0x0000_0006;

/// Written in native byte order; a reader detects endianness by reading this
/// back and comparing.
const BYTE_ORDER_MAGIC: u32 = 0x1A2B_3C4D;

const VERSION_MAJOR: u16 = 1;
const VERSION_MINOR: u16 = 0;

/// `LINKTYPE_ETHERNET`. AF_PACKET/SOCK_RAW hands us complete Ethernet frames.
pub const LINKTYPE_ETHERNET: u16 = 1;

/// Option code for `if_tsresol` and its value for nanosecond resolution.
///
/// The value is an exponent: 9 means 10^-9. Without this option a reader
/// assumes 10^-6.
const OPT_IF_TSRESOL: u16 = 9;
const TSRESOL_NANOSECONDS: u8 = 9;

/// `opt_endofopt`. A spec MUST for writers that libpcap does not enforce, so
/// omitting it produces a nonconformant file that passes every local test.
const OPT_END_OF_OPT: u16 = 0;

/// libpcap's ceiling. A captured length above this is discarded silently.
pub const MAX_SNAPLEN: u32 = super::bpf::MAX_SNAPLEN;

/// Encodes one session's pcapng stream.
///
/// The header is emitted exactly once, by [`Encoder::begin`], and never
/// repeated. `Encoder` owns no I/O: each method returns the bytes to append to
/// the session stream, so chunking and transport stay the caller's problem.
#[derive(Debug)]
pub struct Encoder {
    snaplen: u32,
    interfaces: Vec<String>,
    /// How many Interface Description Blocks `begin` wrote. An Enhanced Packet
    /// Block naming an interface outside this range makes libpcap abort the
    /// read, losing every later packet in the session.
    idb_count: usize,
    began: bool,
}

/// One captured frame, as read from the ring.
#[derive(Debug, Clone, Copy)]
pub struct Frame<'a> {
    /// Index into the interface list given to [`Encoder::new`], matching the
    /// order the IDBs were written.
    pub interface_id: u32,
    /// Wall-clock nanoseconds since the Unix epoch.
    pub timestamp_ns: u64,
    /// Bytes actually captured; TPACKET_V3's `tp_snaplen`.
    pub data: &'a [u8],
    /// Length of the frame on the wire; TPACKET_V3's `tp_len`. May exceed
    /// `data.len()` when the frame was truncated to the snaplen.
    pub original_len: u32,
}

impl Encoder {
    /// `snaplen` 0 means "unlimited", which libpcap expresses as
    /// [`MAX_SNAPLEN`] rather than 0.
    ///
    /// Clamping 0 up to 1 instead — as this did — is worse than passing 0
    /// through: every packet is declared one byte long and libpcap decodes the
    /// file as zero packets while exiting 0. 0 is also the proto3 default for
    /// `StartRemoteCapture.snaplen`, so it is the value an unset field sends.
    pub fn new(interfaces: Vec<String>, snaplen: u32) -> Self {
        let snaplen = if snaplen == 0 {
            MAX_SNAPLEN
        } else {
            snaplen.min(MAX_SNAPLEN)
        };
        let idb_count = interfaces.len().max(1);
        Self {
            snaplen,
            interfaces,
            idb_count,
            began: false,
        }
    }

    pub fn snaplen(&self) -> u32 {
        self.snaplen
    }

    /// Emit the Section Header Block and every Interface Description Block.
    ///
    /// Returns an empty vector if already called: the header belongs to the
    /// section, not to a chunk, and a second SHB would reset the interface
    /// table for every packet that follows.
    pub fn begin(&mut self) -> Vec<u8> {
        if self.began {
            return Vec::new();
        }
        self.began = true;

        let mut out = Vec::with_capacity(64 + self.interfaces.len() * 32);
        self.write_shb(&mut out);
        for _ in 0..self.interfaces.len().max(1) {
            self.write_idb(&mut out);
        }
        out
    }

    /// Encode one Enhanced Packet Block.
    ///
    /// Returns `None` for a frame this encoder must not write. Each refusal
    /// prevents a failure that is silent or that poisons the rest of the file:
    ///
    /// * a zero-length frame, or `original_len < captured`, makes tcpdump drop
    ///   the packet while exiting 0;
    /// * an `interface_id` with no matching IDB makes libpcap ABORT the read,
    ///   so every later packet in the session is lost, not just this one;
    /// * a captured length above the declared snaplen does the same.
    pub fn packet(&self, frame: Frame<'_>) -> Option<Vec<u8>> {
        let captured = u32::try_from(frame.data.len()).ok()?;
        if captured == 0 || frame.original_len < captured {
            return None;
        }
        if frame.interface_id as usize >= self.idb_count {
            return None;
        }
        if captured > self.snaplen {
            return None;
        }

        // Packet data is padded to a 32-bit boundary; the padding is not
        // counted in Captured Packet Length.
        let padding = padding_for(frame.data.len());
        let total_len = 32 + captured as usize + padding;

        let mut out = Vec::with_capacity(total_len);
        out.extend_from_slice(&BLOCK_TYPE_EPB.to_ne_bytes());
        out.extend_from_slice(&(total_len as u32).to_ne_bytes());
        out.extend_from_slice(&frame.interface_id.to_ne_bytes());
        // The 64-bit timestamp is split, high half first.
        out.extend_from_slice(&((frame.timestamp_ns >> 32) as u32).to_ne_bytes());
        out.extend_from_slice(&(frame.timestamp_ns as u32).to_ne_bytes());
        out.extend_from_slice(&captured.to_ne_bytes());
        out.extend_from_slice(&frame.original_len.to_ne_bytes());
        out.extend_from_slice(frame.data);
        out.extend(std::iter::repeat_n(0u8, padding));
        // Block Total Length appears twice so a reader can walk backwards.
        out.extend_from_slice(&(total_len as u32).to_ne_bytes());
        Some(out)
    }

    fn write_shb(&self, out: &mut Vec<u8>) {
        let total_len: u32 = 28;
        out.extend_from_slice(&BLOCK_TYPE_SHB.to_ne_bytes());
        out.extend_from_slice(&total_len.to_ne_bytes());
        out.extend_from_slice(&BYTE_ORDER_MAGIC.to_ne_bytes());
        out.extend_from_slice(&VERSION_MAJOR.to_ne_bytes());
        out.extend_from_slice(&VERSION_MINOR.to_ne_bytes());
        // Section Length -1: a streaming encoder cannot know it, and a
        // plausible-but-wrong positive value reads clean in every sequential
        // reader while breaking a seeking one.
        out.extend_from_slice(&(-1i64).to_ne_bytes());
        out.extend_from_slice(&total_len.to_ne_bytes());
    }

    fn write_idb(&self, out: &mut Vec<u8>) {
        // 20 bytes of fixed fields, an 8-byte if_tsresol option (4 header +
        // 1 value + 3 padding), and a 4-byte opt_endofopt.
        let total_len: u32 = 20 + 8 + 4;
        out.extend_from_slice(&BLOCK_TYPE_IDB.to_ne_bytes());
        out.extend_from_slice(&total_len.to_ne_bytes());
        out.extend_from_slice(&LINKTYPE_ETHERNET.to_ne_bytes());
        out.extend_from_slice(&0u16.to_ne_bytes()); // reserved
        out.extend_from_slice(&self.snaplen.to_ne_bytes());

        // if_tsresol. Without this the reader assumes microseconds and every
        // timestamp is wrong by a factor of 1000.
        out.extend_from_slice(&OPT_IF_TSRESOL.to_ne_bytes());
        out.extend_from_slice(&1u16.to_ne_bytes());
        out.push(TSRESOL_NANOSECONDS);
        out.extend_from_slice(&[0u8; 3]); // option value padded to 4 bytes

        out.extend_from_slice(&OPT_END_OF_OPT.to_ne_bytes());
        out.extend_from_slice(&0u16.to_ne_bytes());

        out.extend_from_slice(&total_len.to_ne_bytes());
    }
}

const fn padding_for(len: usize) -> usize {
    (4 - (len % 4)) % 4
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u32_at(buf: &[u8], off: usize) -> u32 {
        u32::from_ne_bytes(buf[off..off + 4].try_into().unwrap())
    }

    #[test]
    fn header_is_emitted_exactly_once() {
        let mut enc = Encoder::new(vec!["eth0".into()], 262_144);
        let first = enc.begin();
        assert!(!first.is_empty());

        // A second SHB would start a new section and reset the interface
        // table: packets before it decode, everything after fails.
        assert!(enc.begin().is_empty());
    }

    #[test]
    fn section_header_has_the_right_magic_and_unspecified_length() {
        let mut enc = Encoder::new(vec!["eth0".into()], 65_535);
        let out = enc.begin();

        assert_eq!(u32_at(&out, 0), 0x0A0D_0D0A);
        assert_eq!(u32_at(&out, 4), 28);
        assert_eq!(u32_at(&out, 8), 0x1A2B_3C4D);
        // Section Length must be -1, not a guess.
        let section_len = i64::from_ne_bytes(out[16..24].try_into().unwrap());
        assert_eq!(section_len, -1);
        assert_eq!(u32_at(&out, 24), 28, "block total length repeats");
    }

    #[test]
    fn interface_block_declares_ethernet_not_raw() {
        // 101 (LINKTYPE_RAW) is what this repo's existing fixture writers use.
        // Writing Ethernet frames under it produces a file every tool accepts
        // and decodes as garbage.
        let mut enc = Encoder::new(vec!["eth0".into()], 65_535);
        let out = enc.begin();
        let idb = &out[28..];

        assert_eq!(u32_at(idb, 0), BLOCK_TYPE_IDB);
        let linktype = u16::from_ne_bytes(idb[8..10].try_into().unwrap());
        assert_eq!(linktype, 1, "must be LINKTYPE_ETHERNET, never 101");
    }

    #[test]
    fn interface_block_carries_literal_nanosecond_tsresol_bytes() {
        // Asserting the literal bytes is the point. A round-trip through our
        // own decoder cannot catch a missing if_tsresol, because our decoder
        // would assume nanoseconds too — and the resulting error is 1000x, or
        // roughly 33 years of apparent clock skew.
        let mut enc = Encoder::new(vec!["eth0".into()], 65_535);
        let out = enc.begin();
        let idb = &out[28..];

        let opt_code = u16::from_ne_bytes(idb[16..18].try_into().unwrap());
        let opt_len = u16::from_ne_bytes(idb[18..20].try_into().unwrap());
        assert_eq!(opt_code, 9, "if_tsresol option code");
        assert_eq!(opt_len, 1);
        assert_eq!(idb[20], 9, "10^-9 == nanoseconds");

        // opt_endofopt is a writer MUST that no reader enforces.
        let end_code = u16::from_ne_bytes(idb[24..26].try_into().unwrap());
        let end_len = u16::from_ne_bytes(idb[26..28].try_into().unwrap());
        assert_eq!((end_code, end_len), (0, 0));
    }

    #[test]
    fn one_interface_block_per_interface() {
        let mut enc = Encoder::new(vec!["eth0".into(), "eth1".into()], 65_535);
        let out = enc.begin();
        assert_eq!(out.len(), 28 + 32 + 32);
    }

    #[test]
    fn snaplen_zero_becomes_the_libpcap_ceiling_not_zero() {
        // This test previously asserted 1, pinning the bug under a name that
        // promised the opposite. 0 is the proto3 default, so it is what an
        // unset snaplen sends; declaring every packet one byte long makes
        // libpcap decode the file as zero packets while exiting 0.
        assert_eq!(
            Encoder::new(vec!["eth0".into()], 0).snaplen(),
            MAX_SNAPLEN,
            "0 means unlimited, which libpcap spells 262144"
        );
        assert_eq!(
            Encoder::new(vec!["eth0".into()], u32::MAX).snaplen(),
            MAX_SNAPLEN
        );
        // A value in range must pass through untouched, so the clamp cannot
        // silently widen a deliberately small snaplen.
        assert_eq!(Encoder::new(vec!["eth0".into()], 1500).snaplen(), 1500);
        assert_eq!(Encoder::new(vec!["eth0".into()], 1).snaplen(), 1);
    }

    #[test]
    fn a_packet_naming_an_interface_with_no_idb_is_refused() {
        // libpcap aborts the whole read on an unknown interface id, so one bad
        // frame costs every later packet in the session, not just itself.
        let enc = Encoder::new(vec!["eth0".into()], 65_535);
        assert!(
            enc.packet(Frame {
                interface_id: 1,
                timestamp_ns: 1,
                data: &[0u8; 40],
                original_len: 40,
            })
            .is_none(),
            "interface_id 1 has no IDB when only one interface was declared"
        );
        assert!(
            enc.packet(Frame {
                interface_id: 0,
                timestamp_ns: 1,
                data: &[0u8; 40],
                original_len: 40,
            })
            .is_some()
        );
    }

    #[test]
    fn a_frame_longer_than_the_declared_snaplen_is_refused() {
        // Same failure mode: libpcap hard-errors and discards the remainder.
        let enc = Encoder::new(vec!["eth0".into()], 128);
        assert!(
            enc.packet(Frame {
                interface_id: 0,
                timestamp_ns: 1,
                data: &[0u8; 129],
                original_len: 129,
            })
            .is_none()
        );
        assert!(
            enc.packet(Frame {
                interface_id: 0,
                timestamp_ns: 1,
                data: &[0u8; 128],
                original_len: 400,
            })
            .is_some(),
            "a frame truncated TO the snaplen is valid"
        );
    }

    #[test]
    fn packet_block_splits_the_timestamp_high_half_first() {
        let enc = Encoder::new(vec!["eth0".into()], 65_535);
        let ts = 0x0123_4567_89ab_cdefu64;
        let block = enc
            .packet(Frame {
                interface_id: 0,
                timestamp_ns: ts,
                data: &[0xaa; 4],
                original_len: 4,
            })
            .expect("valid frame");

        assert_eq!(u32_at(&block, 0), BLOCK_TYPE_EPB);
        assert_eq!(u32_at(&block, 8), 0, "interface id");
        assert_eq!(u32_at(&block, 12), 0x0123_4567, "timestamp high half first");
        assert_eq!(u32_at(&block, 16), 0x89ab_cdef, "timestamp low half");
        assert_eq!(u32_at(&block, 20), 4, "captured length");
        assert_eq!(u32_at(&block, 24), 4, "original length");
    }

    #[test]
    fn packet_data_is_padded_to_a_32_bit_boundary_without_inflating_caplen() {
        let enc = Encoder::new(vec!["eth0".into()], 65_535);
        for (len, expect_total) in [(1usize, 36usize), (2, 36), (3, 36), (4, 36), (5, 40)] {
            let data = vec![0x5a; len];
            let block = enc
                .packet(Frame {
                    interface_id: 0,
                    timestamp_ns: 1,
                    data: &data,
                    original_len: len as u32,
                })
                .expect("valid frame");

            assert_eq!(block.len(), expect_total, "len {len}");
            assert_eq!(u32_at(&block, 20), len as u32, "caplen excludes padding");
            assert_eq!(u32_at(&block, 4), expect_total as u32);
            let trailer = u32_at(&block, block.len() - 4);
            assert_eq!(trailer, expect_total as u32, "total length repeats");
        }
    }

    #[test]
    fn truncated_frames_are_valid_but_inverted_lengths_are_refused() {
        let enc = Encoder::new(vec!["eth0".into()], 65_535);

        // The legitimate truncated case: captured 40 of a 54-byte frame.
        // Assert the FIELDS, not merely that a block came back: swapping
        // captured and original is invisible to an is_some() check and makes
        // libpcap refuse the whole file.
        let block = enc
            .packet(Frame {
                interface_id: 0,
                timestamp_ns: 1,
                data: &[0u8; 40],
                original_len: 54,
            })
            .expect("a truncated frame is valid");
        assert_eq!(u32_at(&block, 20), 40, "captured length");
        assert_eq!(u32_at(&block, 24), 54, "original length");

        // original < captured makes tcpdump drop the packet and exit 0.
        assert!(
            enc.packet(Frame {
                interface_id: 0,
                timestamp_ns: 1,
                data: &[0u8; 40],
                original_len: 39,
            })
            .is_none()
        );

        // A zero-length frame is dropped by tcpdump the same silent way.
        assert!(
            enc.packet(Frame {
                interface_id: 0,
                timestamp_ns: 1,
                data: &[],
                original_len: 0,
            })
            .is_none()
        );
    }

    #[test]
    fn every_block_length_is_a_multiple_of_four() {
        // A reader walks the file by these lengths; a non-multiple desynchronises
        // it from the next block header.
        let mut enc = Encoder::new(vec!["eth0".into(), "eth1".into()], 262_144);
        let mut stream = enc.begin();
        for len in 1..=64usize {
            let data = vec![0u8; len];
            stream.extend(
                enc.packet(Frame {
                    interface_id: 0,
                    timestamp_ns: len as u64,
                    data: &data,
                    original_len: len as u32,
                })
                .expect("valid frame"),
            );
        }

        let mut off = 0usize;
        let mut blocks = 0usize;
        while off < stream.len() {
            let total = u32_at(&stream, off + 4) as usize;
            assert!(
                total >= 12 && total.is_multiple_of(4),
                "block at {off} len {total}"
            );
            assert_eq!(
                u32_at(&stream, off + total - 4),
                total as u32,
                "trailing length at {off}"
            );
            off += total;
            blocks += 1;
        }
        assert_eq!(off, stream.len(), "blocks must tile the stream exactly");
        assert_eq!(blocks, 1 + 2 + 64);
    }
}
