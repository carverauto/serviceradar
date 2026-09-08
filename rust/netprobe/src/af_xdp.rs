#[cfg(target_os = "linux")]
mod linux {
    use std::{
        fs, io,
        mem::{self, size_of},
        num::NonZeroU32,
        os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd},
        path::Path,
        ptr::{self, NonNull},
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering, fence},
        },
        thread::{self, JoinHandle},
        time::Duration,
    };

    use anyhow::{Context, Result, bail};
    use crossbeam_channel::{Receiver, Sender, TrySendError, bounded};
    use nix::libc;

    const CHANNEL_CAPACITY: usize = 4096;
    // #3: bound CPU. The RX ring is serviced without a blocking syscall, so the
    // poll cadence sets CPU under load. 250us caps active polling at ~4k
    // wakeups/s/queue (vs ~100k/s at 10us) — a large CPU reduction for a
    // monitoring path where sub-ms batching latency is fine — and we drop to the
    // 1ms idle sleep after only 20ms idle. (A blocking poll()/epoll with
    // XDP_USE_NEED_WAKEUP is the ideal follow-up.)
    const BUSY_POLL_SPIN: Duration = Duration::from_micros(250);
    const IDLE_SLEEP: Duration = Duration::from_millis(1);
    const IDLE_SLEEP_AFTER: Duration = Duration::from_millis(20);
    const RX_RING_SIZE: u32 = 1024;
    const FILL_RING_SIZE: u32 = 2048;
    const COMPLETION_RING_SIZE: u32 = 2048;
    const UMEM_FRAME_SIZE: u32 = 4096;
    const UMEM_FRAME_COUNT: u32 = FILL_RING_SIZE;

    pub const DEFAULT_REDIRECT_BUDGET: u32 = 16;

    #[derive(Debug)]
    pub struct AfXdpPacket {
        pub interface: String,
        pub ifindex: u32,
        pub queue_id: u32,
        pub data: Vec<u8>,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct AfXdpInterface {
        pub name: String,
        pub ifindex: u32,
        pub queue_count: NonZeroU32,
        pub preferred_cores: Vec<Option<usize>>,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct AfXdpConsumerConfig {
        pub interface: String,
        pub ifindex: u32,
        pub queue_id: u32,
        pub preferred_core: Option<usize>,
        pub redirect_budget: u32,
    }

    #[derive(Debug)]
    pub struct AfXdpStream {
        pub config: AfXdpConsumerConfig,
        pub receiver: Receiver<AfXdpPacket>,
    }

    pub struct AfXdpConsumers {
        shutdown: Arc<AtomicBool>,
        threads: Vec<JoinHandle<()>>,
        streams: Vec<AfXdpStream>,
    }

    pub trait XskSocketRegistry: Send + Sync {
        fn register_socket(&self, queue_id: u32, socket_fd: RawFd) -> Result<()>;
    }

    #[derive(Debug, Default)]
    pub struct NoopXskSocketRegistry;

    impl XskSocketRegistry for NoopXskSocketRegistry {
        fn register_socket(&self, _queue_id: u32, _socket_fd: RawFd) -> Result<()> {
            Ok(())
        }
    }

    pub struct AyaXskSocketRegistry {
        map: Mutex<aya::maps::XskMap<aya::maps::MapData>>,
    }

    impl AyaXskSocketRegistry {
        pub fn from_ebpf(ebpf: &mut aya::Ebpf) -> Result<Self> {
            let map = ebpf.take_map("xsk_sockets").ok_or_else(|| {
                anyhow::anyhow!("xsk_sockets map is missing from netprobe eBPF object")
            })?;
            Ok(Self {
                map: Mutex::new(aya::maps::XskMap::try_from(map)?),
            })
        }
    }

    impl XskSocketRegistry for AyaXskSocketRegistry {
        fn register_socket(&self, queue_id: u32, socket_fd: RawFd) -> Result<()> {
            let mut map = self
                .map
                .lock()
                .map_err(|_| anyhow::anyhow!("xsk_sockets map mutex poisoned"))?;
            let socket_fd = unsafe {
                // SAFETY: The AF_XDP socket stays open in the consumer source after this call.
                // BorrowedFd only lends the raw descriptor long enough for bpf_map_update_elem.
                BorrowedFd::borrow_raw(socket_fd)
            };
            map.set(queue_id, socket_fd, 0)
                .with_context(|| format!("failed to register AF_XDP socket for queue {queue_id}"))
        }
    }

    impl AfXdpConsumers {
        pub fn start(interfaces: &[String]) -> Result<Self> {
            let interfaces = resolve_interfaces(interfaces)?;
            Self::start_resolved(&interfaces)
        }

        pub fn start_resolved(interfaces: &[AfXdpInterface]) -> Result<Self> {
            Self::start_resolved_with_registry(
                interfaces,
                Arc::new(NoopXskSocketRegistry) as Arc<dyn XskSocketRegistry>,
            )
        }

        pub fn start_with_registry(
            interfaces: &[String],
            xsk_registry: Arc<dyn XskSocketRegistry>,
        ) -> Result<Self> {
            let interfaces = resolve_interfaces(interfaces)?;
            Self::start_resolved_with_registry(&interfaces, xsk_registry)
        }

        pub fn start_resolved_with_registry(
            interfaces: &[AfXdpInterface],
            xsk_registry: Arc<dyn XskSocketRegistry>,
        ) -> Result<Self> {
            let shutdown = Arc::new(AtomicBool::new(false));
            let configs = consumer_configs_for_interfaces(interfaces);
            let mut threads = Vec::with_capacity(configs.len());
            let mut streams = Vec::with_capacity(configs.len());

            for config in configs {
                let (tx, rx) = bounded(CHANNEL_CAPACITY);
                let shutdown_worker = Arc::clone(&shutdown);
                let xsk_registry_worker = Arc::clone(&xsk_registry);
                let thread_config = config.clone();
                let thread_name = format!(
                    "netprobe-af-xdp-{}-q{}",
                    thread_config.interface, thread_config.queue_id
                );
                let thread = thread::Builder::new()
                    .name(thread_name)
                    .spawn(move || {
                        if let Err(err) =
                            run_consumer(thread_config, tx, shutdown_worker, xsk_registry_worker)
                        {
                            log::warn!("AF_XDP consumer exited: {err:#}");
                        }
                    })
                    .context("failed to spawn AF_XDP consumer thread")?;
                streams.push(AfXdpStream {
                    config,
                    receiver: rx,
                });
                threads.push(thread);
            }

            Ok(Self {
                shutdown,
                threads,
                streams,
            })
        }

        pub fn streams(&self) -> &[AfXdpStream] {
            &self.streams
        }

        pub fn take_streams(&mut self) -> Vec<AfXdpStream> {
            std::mem::take(&mut self.streams)
        }
    }

    impl Drop for AfXdpConsumers {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::SeqCst);
            while let Some(thread) = self.threads.pop() {
                if thread.join().is_err() {
                    log::warn!("AF_XDP consumer thread panicked during shutdown");
                }
            }
        }
    }

    fn run_consumer(
        config: AfXdpConsumerConfig,
        tx: Sender<AfXdpPacket>,
        shutdown: Arc<AtomicBool>,
        xsk_registry: Arc<dyn XskSocketRegistry>,
    ) -> Result<()> {
        if let Some(core) = config.preferred_core {
            pin_current_thread(core).with_context(|| {
                format!(
                    "failed to pin {} queue {} AF_XDP thread to CPU {core}",
                    config.interface, config.queue_id
                )
            })?;
        }

        let mut source =
            AfXdpSocketSource::bind(config.ifindex, config.queue_id).with_context(|| {
                format!(
                    "failed to initialize AF_XDP socket for {} queue {}",
                    config.interface, config.queue_id
                )
            })?;
        register_xsk_socket(xsk_registry.as_ref(), &config, source.socket_fd())?;
        let mut backoff = BackoffState::default();

        while !shutdown.load(Ordering::Relaxed) {
            match poll_once(&mut source, &config, &tx, &mut backoff)? {
                PollOutcome::Packet => {}
                PollOutcome::Idle => {
                    let delay = backoff.next_delay();
                    thread::sleep(delay);
                    backoff.record_idle(delay);
                }
            }
        }

        Ok(())
    }

    trait PacketSource {
        fn poll_packet(&mut self) -> Result<Option<Vec<u8>>>;
    }

    struct AfXdpSocketSource {
        _socket: AfXdpSocket,
        rings: AfXdpRings,
    }

    impl AfXdpSocketSource {
        fn bind(ifindex: u32, queue_id: u32) -> Result<Self> {
            let mut socket = AfXdpSocket::open()?;
            let rings = AfXdpRings::new(&socket)?;
            socket.bind_interface(ifindex, queue_id)?;
            Ok(Self {
                _socket: socket,
                rings,
            })
        }

        fn socket_fd(&self) -> RawFd {
            self._socket.as_raw_fd()
        }
    }

    impl PacketSource for AfXdpSocketSource {
        fn poll_packet(&mut self) -> Result<Option<Vec<u8>>> {
            self.rings.poll_packet()
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum PollOutcome {
        Packet,
        Idle,
    }

    fn poll_once<S: PacketSource>(
        source: &mut S,
        config: &AfXdpConsumerConfig,
        tx: &Sender<AfXdpPacket>,
        backoff: &mut BackoffState,
    ) -> Result<PollOutcome> {
        let Some(data) = source.poll_packet()? else {
            return Ok(PollOutcome::Idle);
        };

        backoff.record_packet();
        let packet = AfXdpPacket {
            interface: config.interface.clone(),
            ifindex: config.ifindex,
            queue_id: config.queue_id,
            data,
        };
        match tx.try_send(packet) {
            Ok(()) => Ok(PollOutcome::Packet),
            Err(TrySendError::Full(_)) => {
                log::debug!(
                    "dropping AF_XDP packet from {} queue {} because classifier channel is full",
                    config.interface,
                    config.queue_id
                );
                Ok(PollOutcome::Packet)
            }
            Err(TrySendError::Disconnected(_)) => {
                bail!(
                    "AF_XDP classifier channel disconnected for {} queue {}",
                    config.interface,
                    config.queue_id
                )
            }
        }
    }

    fn register_xsk_socket(
        registry: &dyn XskSocketRegistry,
        config: &AfXdpConsumerConfig,
        socket_fd: RawFd,
    ) -> Result<()> {
        registry
            .register_socket(config.queue_id, socket_fd)
            .with_context(|| {
                format!(
                    "failed to register {} queue {} AF_XDP socket in xsk_sockets map",
                    config.interface, config.queue_id
                )
            })
    }

    #[derive(Default)]
    struct BackoffState {
        idle_for: Duration,
    }

    impl BackoffState {
        fn next_delay(&self) -> Duration {
            if self.idle_for >= IDLE_SLEEP_AFTER {
                IDLE_SLEEP
            } else {
                BUSY_POLL_SPIN
            }
        }

        fn record_idle(&mut self, delay: Duration) {
            self.idle_for = self.idle_for.saturating_add(delay);
        }

        fn record_packet(&mut self) {
            self.idle_for = Duration::ZERO;
        }
    }

    struct AfXdpSocket {
        fd: OwnedFd,
    }

    impl AfXdpSocket {
        fn open() -> Result<Self> {
            let raw_fd = unsafe {
                // SAFETY: socket is called with constant domain/type/protocol values and returns
                // either a valid owned file descriptor or -1 with errno set.
                libc::socket(libc::AF_XDP, libc::SOCK_RAW | libc::SOCK_CLOEXEC, 0)
            };
            if raw_fd < 0 {
                return Err(io::Error::last_os_error()).context("AF_XDP socket creation failed");
            }

            let fd = unsafe {
                // SAFETY: raw_fd was returned by socket above and is uniquely owned here.
                OwnedFd::from_raw_fd(raw_fd)
            };
            Ok(Self { fd })
        }

        fn bind_interface(&mut self, ifindex: u32, queue_id: u32) -> Result<()> {
            let addr = libc::sockaddr_xdp {
                sxdp_family: libc::AF_XDP as libc::sa_family_t,
                sxdp_flags: libc::XDP_COPY,
                sxdp_ifindex: ifindex,
                sxdp_queue_id: queue_id,
                sxdp_shared_umem_fd: 0,
            };
            let result = unsafe {
                // SAFETY: addr points to a valid sockaddr_xdp for the duration of the call; fd is
                // an open AF_XDP socket.
                libc::bind(
                    self.fd.as_raw_fd(),
                    (&addr as *const libc::sockaddr_xdp).cast::<libc::sockaddr>(),
                    size_of::<libc::sockaddr_xdp>() as libc::socklen_t,
                )
            };
            if result < 0 {
                return Err(io::Error::last_os_error()).context("AF_XDP socket bind failed");
            }

            Ok(())
        }
    }

    impl AsRawFd for AfXdpSocket {
        fn as_raw_fd(&self) -> std::os::fd::RawFd {
            self.fd.as_raw_fd()
        }
    }

    struct AfXdpRings {
        umem: MmapRegion,
        _rx_ring: RingMmap,
        _fill_ring: RingMmap,
        _completion_ring: RingMmap,
        rx: RxRing,
        fill: FillRing,
        frame_size: u64,
    }

    impl AfXdpRings {
        fn new(socket: &AfXdpSocket) -> Result<Self> {
            let umem_len =
                usize::try_from(u64::from(UMEM_FRAME_SIZE) * u64::from(UMEM_FRAME_COUNT))
                    .context("AF_XDP UMEM length does not fit usize")?;
            let umem = MmapRegion::anonymous(umem_len).context("failed to allocate AF_XDP UMEM")?;

            register_umem(socket.as_raw_fd(), &umem, UMEM_FRAME_SIZE)?;
            set_xdp_ring_size(socket.as_raw_fd(), libc::XDP_RX_RING, RX_RING_SIZE)?;
            set_xdp_ring_size(socket.as_raw_fd(), libc::XDP_UMEM_FILL_RING, FILL_RING_SIZE)?;
            set_xdp_ring_size(
                socket.as_raw_fd(),
                libc::XDP_UMEM_COMPLETION_RING,
                COMPLETION_RING_SIZE,
            )?;

            let offsets = xdp_mmap_offsets(socket.as_raw_fd())?;
            let rx_ring = RingMmap::xdp(
                socket.as_raw_fd(),
                ring_len(offsets.rx.desc, RX_RING_SIZE, size_of::<libc::xdp_desc>())?,
                libc::XDP_PGOFF_RX_RING,
            )
            .context("failed to mmap AF_XDP RX ring")?;
            let fill_ring = RingMmap::xdp(
                socket.as_raw_fd(),
                ring_len(offsets.fr.desc, FILL_RING_SIZE, size_of::<u64>())?,
                libc::XDP_UMEM_PGOFF_FILL_RING as libc::off_t,
            )
            .context("failed to mmap AF_XDP fill ring")?;
            let completion_ring = RingMmap::xdp(
                socket.as_raw_fd(),
                ring_len(offsets.cr.desc, COMPLETION_RING_SIZE, size_of::<u64>())?,
                libc::XDP_UMEM_PGOFF_COMPLETION_RING as libc::off_t,
            )
            .context("failed to mmap AF_XDP completion ring")?;

            let rx = RxRing::new(&rx_ring, offsets.rx, RX_RING_SIZE)?;
            let mut fill = FillRing::new(&fill_ring, offsets.fr, FILL_RING_SIZE)?;
            fill.prime(UMEM_FRAME_COUNT, UMEM_FRAME_SIZE);

            Ok(Self {
                umem,
                _rx_ring: rx_ring,
                _fill_ring: fill_ring,
                _completion_ring: completion_ring,
                rx,
                fill,
                frame_size: u64::from(UMEM_FRAME_SIZE),
            })
        }

        fn poll_packet(&mut self) -> Result<Option<Vec<u8>>> {
            let Some(desc) = self.rx.next_desc() else {
                return Ok(None);
            };
            let packet = self.umem.packet(desc.addr, desc.len)?;
            let frame_addr = desc.addr & !(self.frame_size - 1);
            self.fill.restock(frame_addr);
            Ok(Some(packet))
        }
    }

    struct RxRing {
        producer: NonNull<u32>,
        consumer: NonNull<u32>,
        desc: NonNull<libc::xdp_desc>,
        cached_consumer: u32,
        mask: u32,
    }

    impl RxRing {
        fn new(region: &RingMmap, offsets: libc::xdp_ring_offset, size: u32) -> Result<Self> {
            ensure_power_of_two(size, "RX ring")?;
            let producer = region.field_ptr::<u32>(offsets.producer)?;
            let consumer = region.field_ptr::<u32>(offsets.consumer)?;
            let desc = region.field_ptr::<libc::xdp_desc>(offsets.desc)?;
            let cached_consumer = unsafe {
                // SAFETY: consumer points into the mmap'd RX ring for the lifetime of RxRing.
                ptr::read_volatile(consumer.as_ptr())
            };
            Ok(Self {
                producer,
                consumer,
                desc,
                cached_consumer,
                mask: size - 1,
            })
        }

        fn next_desc(&mut self) -> Option<libc::xdp_desc> {
            let producer = unsafe {
                // SAFETY: producer points into the mmap'd RX ring for the lifetime of RxRing.
                ptr::read_volatile(self.producer.as_ptr())
            };
            if self.cached_consumer == producer {
                return None;
            }

            fence(Ordering::Acquire);
            let index = self.cached_consumer & self.mask;
            let desc = unsafe {
                // SAFETY: index is masked by the power-of-two ring size, so it addresses an
                // xdp_desc entry inside the mmap'd descriptor array.
                ptr::read_volatile(self.desc.as_ptr().add(index as usize))
            };
            self.cached_consumer = self.cached_consumer.wrapping_add(1);
            unsafe {
                // SAFETY: consumer points into the mmap'd RX ring for the lifetime of RxRing.
                ptr::write_volatile(self.consumer.as_ptr(), self.cached_consumer);
            }
            Some(desc)
        }
    }

    struct FillRing {
        producer: NonNull<u32>,
        desc: NonNull<u64>,
        cached_producer: u32,
        mask: u32,
    }

    impl FillRing {
        fn new(region: &RingMmap, offsets: libc::xdp_ring_offset, size: u32) -> Result<Self> {
            ensure_power_of_two(size, "fill ring")?;
            let producer = region.field_ptr::<u32>(offsets.producer)?;
            let desc = region.field_ptr::<u64>(offsets.desc)?;
            let cached_producer = unsafe {
                // SAFETY: producer points into the mmap'd fill ring for the lifetime of FillRing.
                ptr::read_volatile(producer.as_ptr())
            };
            Ok(Self {
                producer,
                desc,
                cached_producer,
                mask: size - 1,
            })
        }

        fn prime(&mut self, frame_count: u32, frame_size: u32) {
            for frame in 0..frame_count {
                self.write_addr(u64::from(frame) * u64::from(frame_size));
            }
            self.publish();
        }

        fn restock(&mut self, frame_addr: u64) {
            self.write_addr(frame_addr);
            self.publish();
        }

        fn write_addr(&mut self, addr: u64) {
            let index = self.cached_producer & self.mask;
            unsafe {
                // SAFETY: index is masked by the power-of-two ring size, so it addresses a u64
                // entry inside the mmap'd descriptor array.
                ptr::write_volatile(self.desc.as_ptr().add(index as usize), addr);
            }
            self.cached_producer = self.cached_producer.wrapping_add(1);
        }

        fn publish(&self) {
            fence(Ordering::Release);
            unsafe {
                // SAFETY: producer points into the mmap'd fill ring for the lifetime of FillRing.
                ptr::write_volatile(self.producer.as_ptr(), self.cached_producer);
            }
        }
    }

    struct MmapRegion {
        ptr: NonNull<u8>,
        len: usize,
    }

    impl MmapRegion {
        fn anonymous(len: usize) -> Result<Self> {
            let ptr = unsafe {
                // SAFETY: mmap is called with MAP_ANONYMOUS and no fd. On success it returns a
                // page-aligned region owned by this MmapRegion and unmapped in Drop.
                libc::mmap(
                    ptr::null_mut(),
                    len,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                    -1,
                    0,
                )
            };
            if ptr == libc::MAP_FAILED {
                return Err(io::Error::last_os_error()).context("anonymous mmap failed");
            }
            let ptr = NonNull::new(ptr.cast::<u8>()).context("anonymous mmap returned null")?;
            Ok(Self { ptr, len })
        }

        fn packet(&self, addr: u64, len: u32) -> Result<Vec<u8>> {
            let start =
                usize::try_from(addr).context("AF_XDP descriptor address overflows usize")?;
            let len = usize::try_from(len).context("AF_XDP descriptor length overflows usize")?;
            let end = start
                .checked_add(len)
                .context("AF_XDP descriptor range overflows usize")?;
            if end > self.len {
                bail!(
                    "AF_XDP descriptor range [{start}, {end}) exceeds UMEM length {}",
                    self.len
                );
            }
            let slice = unsafe {
                // SAFETY: bounds are checked above; ptr is valid for self.len bytes and remains
                // mapped for the lifetime of MmapRegion.
                std::slice::from_raw_parts(self.ptr.as_ptr().add(start), len)
            };
            Ok(slice.to_vec())
        }
    }

    impl Drop for MmapRegion {
        fn drop(&mut self) {
            let result = unsafe {
                // SAFETY: ptr/len came from a successful mmap call and this Drop runs once.
                libc::munmap(self.ptr.as_ptr().cast::<libc::c_void>(), self.len)
            };
            if result < 0 {
                log::warn!(
                    "failed to munmap AF_XDP region: {}",
                    io::Error::last_os_error()
                );
            }
        }
    }

    struct RingMmap {
        ptr: NonNull<u8>,
        len: usize,
    }

    impl RingMmap {
        fn xdp(fd: std::os::fd::RawFd, len: usize, offset: libc::off_t) -> Result<Self> {
            let ptr = unsafe {
                // SAFETY: mmap maps a kernel-provided AF_XDP ring for the given socket fd/offset.
                // The resulting mapping is owned by RingMmap and unmapped in Drop.
                libc::mmap(
                    ptr::null_mut(),
                    len,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_SHARED,
                    fd,
                    offset,
                )
            };
            if ptr == libc::MAP_FAILED {
                return Err(io::Error::last_os_error()).context("AF_XDP ring mmap failed");
            }
            let ptr = NonNull::new(ptr.cast::<u8>()).context("AF_XDP ring mmap returned null")?;
            Ok(Self { ptr, len })
        }

        fn field_ptr<T>(&self, offset: u64) -> Result<NonNull<T>> {
            let offset = usize::try_from(offset).context("AF_XDP ring offset overflows usize")?;
            let end = offset
                .checked_add(size_of::<T>())
                .context("AF_XDP ring field range overflows usize")?;
            if end > self.len {
                bail!(
                    "AF_XDP ring field range [{offset}, {end}) exceeds mmap length {}",
                    self.len
                );
            }
            let ptr = unsafe {
                // SAFETY: bounds were validated above. Kernel ring offsets are aligned for their
                // published field types; NonNull preserves the raw pointer without creating refs.
                self.ptr.as_ptr().add(offset).cast::<T>()
            };
            NonNull::new(ptr).context("AF_XDP ring field pointer is null")
        }
    }

    impl Drop for RingMmap {
        fn drop(&mut self) {
            let result = unsafe {
                // SAFETY: ptr/len came from a successful mmap call and this Drop runs once.
                libc::munmap(self.ptr.as_ptr().cast::<libc::c_void>(), self.len)
            };
            if result < 0 {
                log::warn!(
                    "failed to munmap AF_XDP ring: {}",
                    io::Error::last_os_error()
                );
            }
        }
    }

    fn register_umem(fd: std::os::fd::RawFd, umem: &MmapRegion, frame_size: u32) -> Result<()> {
        let reg = libc::xdp_umem_reg {
            addr: umem.ptr.as_ptr() as u64,
            len: umem.len as u64,
            chunk_size: frame_size,
            headroom: 0,
            flags: 0,
            tx_metadata_len: 0,
        };
        set_sockopt(fd, libc::SOL_XDP, libc::XDP_UMEM_REG, &reg, "XDP_UMEM_REG")
    }

    fn set_xdp_ring_size(fd: std::os::fd::RawFd, opt: libc::c_int, size: u32) -> Result<()> {
        set_sockopt(fd, libc::SOL_XDP, opt, &size, "AF_XDP ring size")
    }

    fn set_sockopt<T>(
        fd: std::os::fd::RawFd,
        level: libc::c_int,
        opt: libc::c_int,
        value: &T,
        name: &str,
    ) -> Result<()> {
        let result = unsafe {
            // SAFETY: value points to a properly initialized value of length size_of::<T>() for
            // the duration of the setsockopt call.
            libc::setsockopt(
                fd,
                level,
                opt,
                (value as *const T).cast::<libc::c_void>(),
                size_of::<T>() as libc::socklen_t,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error()).with_context(|| format!("{name} failed"));
        }
        Ok(())
    }

    fn xdp_mmap_offsets(fd: std::os::fd::RawFd) -> Result<libc::xdp_mmap_offsets> {
        let mut offsets = unsafe {
            // SAFETY: xdp_mmap_offsets is a plain C struct filled by getsockopt below.
            mem::zeroed::<libc::xdp_mmap_offsets>()
        };
        let mut len = size_of::<libc::xdp_mmap_offsets>() as libc::socklen_t;
        let result = unsafe {
            // SAFETY: offsets points to valid writable memory and len is initialized to its size.
            libc::getsockopt(
                fd,
                libc::SOL_XDP,
                libc::XDP_MMAP_OFFSETS,
                (&mut offsets as *mut libc::xdp_mmap_offsets).cast::<libc::c_void>(),
                &mut len,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error()).context("XDP_MMAP_OFFSETS failed");
        }
        Ok(offsets)
    }

    fn ring_len(desc_offset: u64, ring_size: u32, desc_size: usize) -> Result<usize> {
        let desc_offset =
            usize::try_from(desc_offset).context("AF_XDP descriptor offset overflows usize")?;
        let desc_bytes = usize::try_from(ring_size)
            .context("AF_XDP ring size overflows usize")?
            .checked_mul(desc_size)
            .context("AF_XDP descriptor bytes overflow usize")?;
        desc_offset
            .checked_add(desc_bytes)
            .context("AF_XDP mmap length overflows usize")
    }

    fn ensure_power_of_two(value: u32, label: &str) -> Result<()> {
        if value.is_power_of_two() {
            Ok(())
        } else {
            bail!("{label} size {value} is not a power of two")
        }
    }

    fn resolve_interface(interface: &str) -> Result<AfXdpInterface> {
        let ifindex = read_interface_index(interface)
            .with_context(|| format!("failed to resolve ifindex for {interface}"))?;
        let queue_count = read_rx_queue_count(interface).unwrap_or_else(|err| {
            log::debug!(
                "failed to read RX queue count for {interface}; falling back to one queue: {err:#}"
            );
            default_queue_count()
        });
        let preferred_cores = (0..queue_count.get())
            .map(|queue_id| preferred_core_for_interface_queue(interface, queue_id))
            .collect();

        Ok(AfXdpInterface {
            name: interface.to_owned(),
            ifindex,
            queue_count,
            preferred_cores,
        })
    }

    pub fn resolve_interfaces(interfaces: &[String]) -> Result<Vec<AfXdpInterface>> {
        interfaces
            .iter()
            .map(|interface| resolve_interface(interface))
            .collect()
    }

    fn default_queue_count() -> NonZeroU32 {
        NonZeroU32::new(1).expect("one is non-zero")
    }

    fn consumer_configs_for_interfaces(interfaces: &[AfXdpInterface]) -> Vec<AfXdpConsumerConfig> {
        let mut configs = Vec::new();
        for interface in interfaces {
            for queue_id in 0..interface.queue_count.get() {
                configs.push(AfXdpConsumerConfig {
                    interface: interface.name.clone(),
                    ifindex: interface.ifindex,
                    queue_id,
                    preferred_core: interface
                        .preferred_cores
                        .get(queue_id as usize)
                        .copied()
                        .flatten(),
                    redirect_budget: DEFAULT_REDIRECT_BUDGET,
                });
            }
        }

        configs
    }

    fn read_interface_index(interface: &str) -> Result<u32> {
        let path = Path::new("/sys/class/net").join(interface).join("ifindex");
        let contents = fs::read_to_string(&path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        contents
            .trim()
            .parse::<u32>()
            .with_context(|| format!("failed to parse {}", path.display()))
    }

    fn read_rx_queue_count(interface: &str) -> Result<NonZeroU32> {
        let path = Path::new("/sys/class/net").join(interface).join("queues");
        let mut count = 0u32;
        for entry in
            fs::read_dir(&path).with_context(|| format!("failed to read {}", path.display()))?
        {
            let entry = entry.with_context(|| format!("failed to read {}", path.display()))?;
            if entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with("rx-"))
            {
                count = count.saturating_add(1);
            }
        }

        NonZeroU32::new(count)
            .with_context(|| format!("no RX queues found under {}", path.display()))
    }

    fn preferred_core_for_interface_queue(interface: &str, queue_id: u32) -> Option<usize> {
        let interrupts = fs::read_to_string("/proc/interrupts").ok()?;
        let irqs = parse_interface_irqs(&interrupts, interface);
        let irq = irqs
            .iter()
            .find(|irq| irq.queue_id == Some(queue_id))
            .or_else(|| irqs.iter().find(|irq| irq.queue_id.is_none()))
            .or_else(|| irqs.first())?;
        let path = format!("/proc/irq/{}/smp_affinity", irq.irq);
        let mask = fs::read_to_string(path).ok()?;
        first_cpu_from_affinity_mask(mask.trim())
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    struct InterfaceIrq {
        irq: u32,
        queue_id: Option<u32>,
    }

    fn parse_interface_irqs(interrupts: &str, interface: &str) -> Vec<InterfaceIrq> {
        let mut irqs = Vec::new();
        for line in interrupts.lines() {
            if !line.contains(interface) {
                continue;
            }
            let Some((irq, rest)) = line.split_once(':') else {
                continue;
            };
            let Ok(irq) = irq.trim().parse::<u32>() else {
                continue;
            };
            irqs.push(InterfaceIrq {
                irq,
                queue_id: parse_queue_id(rest, interface),
            });
        }

        irqs
    }

    fn parse_queue_id(line: &str, interface: &str) -> Option<u32> {
        let start = line.find(interface)?;
        let tail = &line[start + interface.len()..];
        let suffix = tail.rsplit_once('-')?.1;
        suffix.trim().parse::<u32>().ok()
    }

    fn first_cpu_from_affinity_mask(mask: &str) -> Option<usize> {
        let compact = mask.replace(',', "");
        let mut cpu_base = 0usize;
        for ch in compact.chars().rev() {
            let digit = ch.to_digit(16)?;
            for bit in 0..4 {
                if digit & (1 << bit) != 0 {
                    return Some(cpu_base + bit);
                }
            }
            cpu_base += 4;
        }

        None
    }

    fn pin_current_thread(core: usize) -> Result<()> {
        let mut set = unsafe {
            // SAFETY: cpu_set_t is a plain C bitset initialized by CPU_ZERO below before use.
            std::mem::zeroed::<libc::cpu_set_t>()
        };
        unsafe {
            // SAFETY: set is a valid cpu_set_t pointer and core is the bit to enable.
            libc::CPU_ZERO(&mut set);
            libc::CPU_SET(core, &mut set);
        }
        let result = unsafe {
            // SAFETY: pid 0 targets the current thread/process per sched_setaffinity(2); set is
            // initialized above and lives for the duration of the call.
            libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set)
        };
        if result < 0 {
            return Err(io::Error::last_os_error()).context("sched_setaffinity failed");
        }

        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use std::{
            collections::VecDeque, num::NonZeroU32, os::fd::RawFd, sync::Mutex, time::Duration,
        };

        use anyhow::Result;
        use crossbeam_channel::bounded;

        use super::{
            AfXdpConsumerConfig, AfXdpInterface, BUSY_POLL_SPIN, BackoffState,
            DEFAULT_REDIRECT_BUDGET, IDLE_SLEEP, IDLE_SLEEP_AFTER, PacketSource, PollOutcome,
            XskSocketRegistry, consumer_configs_for_interfaces, first_cpu_from_affinity_mask,
            parse_interface_irqs, poll_once, register_xsk_socket,
        };

        struct FakeSource {
            packets: VecDeque<Option<Vec<u8>>>,
        }

        impl PacketSource for FakeSource {
            fn poll_packet(&mut self) -> Result<Option<Vec<u8>>> {
                Ok(self.packets.pop_front().flatten())
            }
        }

        #[derive(Default)]
        struct RecordingXskRegistry {
            registrations: Mutex<Vec<(u32, RawFd)>>,
        }

        impl XskSocketRegistry for RecordingXskRegistry {
            fn register_socket(&self, queue_id: u32, socket_fd: RawFd) -> Result<()> {
                self.registrations
                    .lock()
                    .unwrap()
                    .push((queue_id, socket_fd));
                Ok(())
            }
        }

        #[test]
        fn parses_interface_irqs() {
            let interrupts = "\
 32: 0 1 2 3 PCI-MSI eth0-TxRx-0
 33: 0 1 2 3 PCI-MSI enp3s0-rx-1
NMI: 0 0 0 0 Non-maskable interrupts
";

            let eth0 = parse_interface_irqs(interrupts, "eth0");
            assert_eq!(eth0.len(), 1);
            assert_eq!(eth0[0].irq, 32);
            assert_eq!(eth0[0].queue_id, Some(0));

            let enp3s0 = parse_interface_irqs(interrupts, "enp3s0");
            assert_eq!(enp3s0.len(), 1);
            assert_eq!(enp3s0[0].irq, 33);
            assert_eq!(enp3s0[0].queue_id, Some(1));
        }

        #[test]
        fn parses_first_cpu_from_affinity_mask() {
            assert_eq!(first_cpu_from_affinity_mask("00000001"), Some(0));
            assert_eq!(first_cpu_from_affinity_mask("00000010"), Some(4));
            assert_eq!(first_cpu_from_affinity_mask("00000000,00000004"), Some(2));
            assert_eq!(first_cpu_from_affinity_mask("00000000"), None);
        }

        #[test]
        fn builds_one_consumer_config_per_interface_queue() {
            let interfaces = vec![AfXdpInterface {
                name: "eth0".to_owned(),
                ifindex: 7,
                queue_count: NonZeroU32::new(2).unwrap(),
                preferred_cores: vec![Some(3), Some(5)],
            }];

            let configs = consumer_configs_for_interfaces(&interfaces);
            assert_eq!(configs.len(), 2);
            assert_eq!(
                configs[0],
                AfXdpConsumerConfig {
                    interface: "eth0".to_owned(),
                    ifindex: 7,
                    queue_id: 0,
                    preferred_core: Some(3),
                    redirect_budget: DEFAULT_REDIRECT_BUDGET,
                }
            );
            assert_eq!(configs[1].queue_id, 1);
            assert_eq!(configs[1].preferred_core, Some(5));
        }

        #[test]
        fn poll_once_sends_packet_on_dedicated_channel() {
            let mut source = FakeSource {
                packets: VecDeque::from([Some(vec![1, 2, 3])]),
            };
            let config = AfXdpConsumerConfig {
                interface: "eth0".to_owned(),
                ifindex: 7,
                queue_id: 2,
                preferred_core: None,
                redirect_budget: DEFAULT_REDIRECT_BUDGET,
            };
            let (tx, rx) = bounded(1);
            let mut backoff = BackoffState {
                idle_for: IDLE_SLEEP_AFTER,
            };

            let outcome = poll_once(&mut source, &config, &tx, &mut backoff).unwrap();

            assert_eq!(outcome, PollOutcome::Packet);
            let packet = rx.try_recv().unwrap();
            assert_eq!(packet.interface, "eth0");
            assert_eq!(packet.ifindex, 7);
            assert_eq!(packet.queue_id, 2);
            assert_eq!(packet.data, vec![1, 2, 3]);
            assert_eq!(backoff.next_delay(), BUSY_POLL_SPIN);
        }

        #[test]
        fn poll_once_reports_idle_without_touching_channel() {
            let mut source = FakeSource {
                packets: VecDeque::from([None]),
            };
            let config = AfXdpConsumerConfig {
                interface: "eth0".to_owned(),
                ifindex: 7,
                queue_id: 0,
                preferred_core: None,
                redirect_budget: DEFAULT_REDIRECT_BUDGET,
            };
            let (tx, rx) = bounded(1);
            let mut backoff = BackoffState::default();

            let outcome = poll_once(&mut source, &config, &tx, &mut backoff).unwrap();

            assert_eq!(outcome, PollOutcome::Idle);
            assert!(rx.try_recv().is_err());
        }

        #[test]
        fn registers_xsk_socket_by_queue_id() {
            let registry = RecordingXskRegistry::default();
            let config = AfXdpConsumerConfig {
                interface: "eth0".to_owned(),
                ifindex: 7,
                queue_id: 3,
                preferred_core: None,
                redirect_budget: DEFAULT_REDIRECT_BUDGET,
            };

            register_xsk_socket(&registry, &config, 42).unwrap();

            assert_eq!(*registry.registrations.lock().unwrap(), vec![(3, 42)]);
        }

        #[test]
        fn backoff_switches_to_sleep_after_idle_window_and_resets_on_packet() {
            let mut backoff = BackoffState::default();
            assert_eq!(backoff.next_delay(), BUSY_POLL_SPIN);

            backoff.record_idle(IDLE_SLEEP_AFTER - Duration::from_micros(1));
            assert_eq!(backoff.next_delay(), BUSY_POLL_SPIN);

            backoff.record_idle(Duration::from_micros(1));
            assert_eq!(backoff.next_delay(), IDLE_SLEEP);

            backoff.record_packet();
            assert_eq!(backoff.next_delay(), BUSY_POLL_SPIN);
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod non_linux {
    use std::{num::NonZeroU32, os::fd::RawFd, sync::Arc};

    use anyhow::Result;
    use crossbeam_channel::Receiver;

    pub const DEFAULT_REDIRECT_BUDGET: u32 = 16;

    #[derive(Debug)]
    pub struct AfXdpPacket {
        pub interface: String,
        pub ifindex: u32,
        pub queue_id: u32,
        pub data: Vec<u8>,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct AfXdpConsumerConfig {
        pub interface: String,
        pub ifindex: u32,
        pub queue_id: u32,
        pub preferred_core: Option<usize>,
        pub redirect_budget: u32,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct AfXdpInterface {
        pub name: String,
        pub ifindex: u32,
        pub queue_count: NonZeroU32,
        pub preferred_cores: Vec<Option<usize>>,
    }

    #[derive(Debug)]
    pub struct AfXdpStream {
        pub config: AfXdpConsumerConfig,
        pub receiver: Receiver<AfXdpPacket>,
    }

    pub struct AfXdpConsumers {
        streams: Vec<AfXdpStream>,
    }

    pub trait XskSocketRegistry: Send + Sync {
        fn register_socket(&self, queue_id: u32, socket_fd: RawFd) -> Result<()>;
    }

    #[derive(Debug, Default)]
    pub struct NoopXskSocketRegistry;

    impl XskSocketRegistry for NoopXskSocketRegistry {
        fn register_socket(&self, _queue_id: u32, _socket_fd: RawFd) -> Result<()> {
            Ok(())
        }
    }

    impl AfXdpConsumers {
        pub fn start(_interfaces: &[String]) -> Result<Self> {
            Ok(Self {
                streams: Vec::new(),
            })
        }

        pub fn start_with_registry(
            _interfaces: &[String],
            _xsk_registry: Arc<dyn XskSocketRegistry>,
        ) -> Result<Self> {
            Self::start(_interfaces)
        }

        pub fn streams(&self) -> &[AfXdpStream] {
            &self.streams
        }

        pub fn take_streams(&mut self) -> Vec<AfXdpStream> {
            std::mem::take(&mut self.streams)
        }
    }

    pub fn resolve_interfaces(_interfaces: &[String]) -> Result<Vec<AfXdpInterface>> {
        Ok(Vec::new())
    }
}

#[cfg(target_os = "linux")]
pub use linux::{
    AfXdpConsumerConfig, AfXdpConsumers, AfXdpInterface, AfXdpPacket, AfXdpStream,
    AyaXskSocketRegistry, DEFAULT_REDIRECT_BUDGET, NoopXskSocketRegistry, XskSocketRegistry,
    resolve_interfaces,
};

#[cfg(not(target_os = "linux"))]
pub use non_linux::{
    AfXdpConsumerConfig, AfXdpConsumers, AfXdpInterface, AfXdpPacket, AfXdpStream,
    DEFAULT_REDIRECT_BUDGET, NoopXskSocketRegistry, XskSocketRegistry, resolve_interfaces,
};
