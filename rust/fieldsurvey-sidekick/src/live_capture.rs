use crate::observation::SidekickObservation;
use tokio::sync::mpsc;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureRequest {
    pub interface_name: String,
    pub sidekick_id: String,
    pub radio_id: String,
}

pub fn spawn_capture(
    request: CaptureRequest,
) -> mpsc::Receiver<Result<SidekickObservation, String>> {
    let (tx, rx) = mpsc::channel(256);

    std::thread::spawn(move || {
        if let Err(error) = run_capture(request, tx.clone()) {
            let _ = tx.blocking_send(Err(error));
        }
    });

    rx
}

#[cfg(target_os = "linux")]
fn run_capture(
    request: CaptureRequest,
    tx: mpsc::Sender<Result<SidekickObservation, String>>,
) -> Result<(), String> {
    use std::ffi::CString;
    use std::mem;
    use std::os::fd::RawFd;
    use std::ptr;

    const SOL_PACKET: libc::c_int = 263;
    const PACKET_RX_RING: libc::c_int = 5;
    const PACKET_VERSION: libc::c_int = 10;
    const TPACKET_V3: libc::c_int = 2;
    const TP_STATUS_KERNEL: u32 = 0;
    const TP_STATUS_USER: u32 = 1;
    const BLOCK_SIZE: u32 = 1 << 20;
    const BLOCK_COUNT: u32 = 4;
    const FRAME_SIZE: u32 = 4096;
    const POLL_TIMEOUT_MILLIS: libc::c_int = 1000;

    #[repr(C)]
    struct TpacketReq3 {
        tp_block_size: u32,
        tp_block_nr: u32,
        tp_frame_size: u32,
        tp_frame_nr: u32,
        tp_retire_blk_tov: u32,
        tp_sizeof_priv: u32,
        tp_feature_req_word: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct TpacketBdTs {
        ts_sec: u32,
        ts_nsec: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct TpacketHdrV1 {
        block_status: u32,
        num_pkts: u32,
        offset_to_first_pkt: u32,
        blk_len: u32,
        seq_num: u64,
        ts_first_pkt: TpacketBdTs,
        ts_last_pkt: TpacketBdTs,
    }

    #[repr(C)]
    union TpacketBdHeaderU {
        bh1: TpacketHdrV1,
    }

    #[repr(C)]
    struct TpacketBlockDesc {
        version: u32,
        offset_to_priv: u32,
        hdr: TpacketBdHeaderU,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct TpacketHdrVariant1 {
        tp_rxhash: u32,
        tp_vlan_tci: u32,
        tp_vlan_tpid: u16,
        tp_padding: u16,
    }

    #[repr(C)]
    union TpacketHdrVariant {
        hv1: TpacketHdrVariant1,
    }

    #[repr(C)]
    struct Tpacket3Hdr {
        tp_next_offset: u32,
        tp_sec: u32,
        tp_nsec: u32,
        tp_snaplen: u32,
        tp_len: u32,
        tp_status: u32,
        tp_mac: u16,
        tp_net: u16,
        variant: TpacketHdrVariant,
        tp_padding: [u8; 8],
    }

    #[derive(Clone, Copy)]
    struct ClockBridge {
        realtime_to_monotonic_offset_nanos: i128,
    }

    impl ClockBridge {
        fn sample() -> Self {
            let realtime = clock_nanos(libc::CLOCK_REALTIME).unwrap_or_default() as i128;
            let monotonic = clock_nanos(libc::CLOCK_MONOTONIC_RAW)
                .or_else(|| clock_nanos(libc::CLOCK_MONOTONIC))
                .unwrap_or_default() as i128;

            Self {
                realtime_to_monotonic_offset_nanos: monotonic - realtime,
            }
        }

        fn monotonic_from_unix_nanos(self, unix_nanos: i64) -> Option<u64> {
            let monotonic = unix_nanos as i128 + self.realtime_to_monotonic_offset_nanos;
            u64::try_from(monotonic).ok()
        }
    }

    struct SocketGuard(RawFd);

    impl Drop for SocketGuard {
        fn drop(&mut self) {
            unsafe {
                libc::close(self.0);
            }
        }
    }

    struct RingGuard {
        fd: RawFd,
        ptr: *mut libc::c_void,
        len: usize,
    }

    impl Drop for RingGuard {
        fn drop(&mut self) {
            let zero_req = TpacketReq3 {
                tp_block_size: 0,
                tp_block_nr: 0,
                tp_frame_size: 0,
                tp_frame_nr: 0,
                tp_retire_blk_tov: 0,
                tp_sizeof_priv: 0,
                tp_feature_req_word: 0,
            };

            unsafe {
                let _ = libc::setsockopt(
                    self.fd,
                    SOL_PACKET,
                    PACKET_RX_RING,
                    (&zero_req as *const TpacketReq3).cast::<libc::c_void>(),
                    mem::size_of::<TpacketReq3>() as libc::socklen_t,
                );
                libc::munmap(self.ptr, self.len);
            }
        }
    }

    let iface = CString::new(request.interface_name.as_str())
        .map_err(|_| "interface_name contains an interior NUL byte".to_string())?;
    let ifindex = unsafe { libc::if_nametoindex(iface.as_ptr()) };
    if ifindex == 0 {
        return Err(format!("interface {} not found", request.interface_name));
    }

    let fd = unsafe {
        libc::socket(
            libc::AF_PACKET,
            libc::SOCK_RAW,
            (libc::ETH_P_ALL as u16).to_be() as i32,
        )
    };
    if fd < 0 {
        return Err(format!(
            "failed to open AF_PACKET socket: {}",
            last_os_error()
        ));
    }
    let socket = SocketGuard(fd);

    let version: libc::c_int = TPACKET_V3;
    let version_result = unsafe {
        libc::setsockopt(
            socket.0,
            SOL_PACKET,
            PACKET_VERSION,
            (&version as *const libc::c_int).cast::<libc::c_void>(),
            mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    if version_result < 0 {
        return Err(format!(
            "failed to enable TPACKET_V3 on AF_PACKET socket: {}",
            last_os_error()
        ));
    }

    let ring_request = TpacketReq3 {
        tp_block_size: BLOCK_SIZE,
        tp_block_nr: BLOCK_COUNT,
        tp_frame_size: FRAME_SIZE,
        tp_frame_nr: (BLOCK_SIZE / FRAME_SIZE) * BLOCK_COUNT,
        tp_retire_blk_tov: 100,
        tp_sizeof_priv: 0,
        tp_feature_req_word: 0,
    };
    let ring_result = unsafe {
        libc::setsockopt(
            socket.0,
            SOL_PACKET,
            PACKET_RX_RING,
            (&ring_request as *const TpacketReq3).cast::<libc::c_void>(),
            mem::size_of::<TpacketReq3>() as libc::socklen_t,
        )
    };
    if ring_result < 0 {
        return Err(format!(
            "failed to configure TPACKET_V3 RX ring: {}",
            last_os_error()
        ));
    }

    let ring_len = (ring_request.tp_block_size * ring_request.tp_block_nr) as usize;
    let ring_ptr = unsafe {
        libc::mmap(
            ptr::null_mut(),
            ring_len,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            socket.0,
            0,
        )
    };
    if ring_ptr == libc::MAP_FAILED {
        return Err(format!(
            "failed to mmap packet RX ring: {}",
            last_os_error()
        ));
    }
    let ring = RingGuard {
        fd: socket.0,
        ptr: ring_ptr,
        len: ring_len,
    };

    let mut addr: libc::sockaddr_ll = unsafe { mem::zeroed() };
    addr.sll_family = libc::AF_PACKET as u16;
    addr.sll_protocol = (libc::ETH_P_ALL as u16).to_be();
    addr.sll_ifindex = ifindex as i32;

    let bind_result = unsafe {
        libc::bind(
            socket.0,
            (&addr as *const libc::sockaddr_ll).cast::<libc::sockaddr>(),
            mem::size_of::<libc::sockaddr_ll>() as libc::socklen_t,
        )
    };
    if bind_result < 0 {
        return Err(format!(
            "failed to bind packet socket to {}: {}",
            request.interface_name,
            last_os_error()
        ));
    }

    let mut block_index = 0_usize;

    loop {
        if tx.is_closed() {
            return Ok(());
        }

        let block_ptr = unsafe {
            (ring.ptr as *mut u8)
                .add(block_index * ring_request.tp_block_size as usize)
                .cast::<TpacketBlockDesc>()
        };

        let block_status = unsafe { (*block_ptr).hdr.bh1.block_status };
        if block_status & TP_STATUS_USER == 0 {
            let mut poll_fd = libc::pollfd {
                fd: socket.0,
                events: libc::POLLIN,
                revents: 0,
            };
            let poll_result = unsafe { libc::poll(&mut poll_fd, 1, POLL_TIMEOUT_MILLIS) };
            if poll_result < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(format!("packet ring poll failed: {error}"));
            }
            continue;
        }

        let block_done = process_block(
            block_ptr,
            ring_request.tp_block_size as usize,
            &request,
            &tx,
            ClockBridge::sample(),
        )?;

        unsafe {
            (*block_ptr).hdr.bh1.block_status = TP_STATUS_KERNEL;
        }

        if !block_done {
            return Ok(());
        }

        block_index = (block_index + 1) % ring_request.tp_block_nr as usize;
    }

    fn process_block(
        block_ptr: *mut TpacketBlockDesc,
        block_size: usize,
        request: &CaptureRequest,
        tx: &mpsc::Sender<Result<SidekickObservation, String>>,
        clock_bridge: ClockBridge,
    ) -> Result<bool, String> {
        let block_base = block_ptr.cast::<u8>();
        let header = unsafe { (*block_ptr).hdr.bh1 };
        let mut packet_offset = header.offset_to_first_pkt as usize;

        for _ in 0..header.num_pkts {
            if tx.is_closed() {
                return Ok(false);
            }

            if packet_offset + mem::size_of::<Tpacket3Hdr>() > block_size {
                break;
            }

            let packet_header = unsafe { block_base.add(packet_offset).cast::<Tpacket3Hdr>() };
            let header_ref = unsafe { &*packet_header };
            let packet_data_offset = packet_offset + header_ref.tp_mac as usize;
            let packet_len = header_ref.tp_snaplen as usize;

            if packet_len == 0 || packet_data_offset + packet_len > block_size {
                if header_ref.tp_next_offset == 0 {
                    break;
                }
                packet_offset += header_ref.tp_next_offset as usize;
                continue;
            }

            let frame = unsafe {
                std::slice::from_raw_parts(block_base.add(packet_data_offset), packet_len)
            };
            let captured_at_unix_nanos =
                (header_ref.tp_sec as i64 * 1_000_000_000) + header_ref.tp_nsec as i64;
            let captured_at_monotonic_nanos =
                clock_bridge.monotonic_from_unix_nanos(captured_at_unix_nanos);

            if let Ok(observation) = crate::capture::observation_from_packet(
                frame,
                &request.sidekick_id,
                &request.radio_id,
                &request.interface_name,
                captured_at_unix_nanos,
                captured_at_monotonic_nanos,
            ) {
                if tx.blocking_send(Ok(observation)).is_err() {
                    return Ok(false);
                }
            }

            if header_ref.tp_next_offset == 0 {
                break;
            }
            packet_offset += header_ref.tp_next_offset as usize;
        }

        Ok(true)
    }

    fn clock_nanos(clock_id: libc::clockid_t) -> Option<u64> {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        let result = unsafe { libc::clock_gettime(clock_id, &mut ts) };
        if result < 0 {
            return None;
        }

        Some((ts.tv_sec as u64 * 1_000_000_000) + ts.tv_nsec as u64)
    }
}

#[cfg(not(target_os = "linux"))]
fn run_capture(
    request: CaptureRequest,
    tx: mpsc::Sender<Result<SidekickObservation, String>>,
) -> Result<(), String> {
    let _ = tx;
    Err(format!(
        "live capture is only supported on Linux monitor interfaces; requested {}",
        request.interface_name
    ))
}

#[cfg(target_os = "linux")]
fn last_os_error() -> std::io::Error {
    std::io::Error::last_os_error()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_request_keeps_identity_fields() {
        let request = CaptureRequest {
            interface_name: "wlan2".to_string(),
            sidekick_id: "sidekick-1".to_string(),
            radio_id: "radio-1".to_string(),
        };

        assert_eq!(request.interface_name, "wlan2");
        assert_eq!(request.sidekick_id, "sidekick-1");
        assert_eq!(request.radio_id, "radio-1");
    }
}
