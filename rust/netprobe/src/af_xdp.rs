#[cfg(target_os = "linux")]
mod linux {
    use std::{
        fs, io,
        mem::size_of,
        num::NonZeroU32,
        os::fd::{AsRawFd, FromRawFd, OwnedFd},
        path::Path,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        thread::{self, JoinHandle},
        time::Duration,
    };

    use anyhow::{bail, Context, Result};
    use crossbeam_channel::{bounded, Receiver, Sender, TrySendError};
    use nix::libc;

    const CHANNEL_CAPACITY: usize = 4096;
    const BUSY_POLL_SPIN: Duration = Duration::from_micros(10);
    const IDLE_SLEEP: Duration = Duration::from_millis(1);
    const IDLE_SLEEP_AFTER: Duration = Duration::from_millis(100);

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

    impl AfXdpConsumers {
        pub fn start(interfaces: &[String]) -> Result<Self> {
            let interfaces = interfaces
                .iter()
                .map(|interface| resolve_interface(interface))
                .collect::<Result<Vec<_>>>()?;
            Self::start_resolved(&interfaces)
        }

        pub fn start_resolved(interfaces: &[AfXdpInterface]) -> Result<Self> {
            let shutdown = Arc::new(AtomicBool::new(false));
            let configs = consumer_configs_for_interfaces(interfaces);
            let mut threads = Vec::with_capacity(configs.len());
            let mut streams = Vec::with_capacity(configs.len());

            for config in configs {
                let (tx, rx) = bounded(CHANNEL_CAPACITY);
                let shutdown_worker = Arc::clone(&shutdown);
                let thread_config = config.clone();
                let thread_name = format!(
                    "netprobe-af-xdp-{}-q{}",
                    thread_config.interface, thread_config.queue_id
                );
                let thread = thread::Builder::new()
                    .name(thread_name)
                    .spawn(move || {
                        if let Err(err) = run_consumer(thread_config, tx, shutdown_worker) {
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
    ) -> Result<()> {
        if let Some(core) = config.preferred_core {
            pin_current_thread(core).with_context(|| {
                format!(
                    "failed to pin {} queue {} AF_XDP thread to CPU {core}",
                    config.interface, config.queue_id
                )
            })?;
        }

        let socket = AfXdpSocket::bind(config.ifindex, config.queue_id).with_context(|| {
            format!(
                "failed to bind AF_XDP socket for {} queue {}",
                config.interface, config.queue_id
            )
        })?;
        let mut source = AfXdpSocketSource::new(socket);
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
    }

    impl AfXdpSocketSource {
        fn new(socket: AfXdpSocket) -> Self {
            Self { _socket: socket }
        }
    }

    impl PacketSource for AfXdpSocketSource {
        fn poll_packet(&mut self) -> Result<Option<Vec<u8>>> {
            // The §18.8 task owns socket binding, thread placement, and channel shape.
            // §18.9 replaces this no-op with UMEM/RX-ring packet dequeue and DPI dispatch.
            Ok(None)
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
        fn bind(ifindex: u32, queue_id: u32) -> Result<Self> {
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
            let addr = libc::sockaddr_xdp {
                sxdp_family: libc::AF_XDP as libc::sa_family_t,
                sxdp_flags: 0,
                sxdp_ifindex: ifindex,
                sxdp_queue_id: queue_id,
                sxdp_shared_umem_fd: 0,
            };
            let result = unsafe {
                // SAFETY: addr points to a valid sockaddr_xdp for the duration of the call; fd is
                // an open AF_XDP socket.
                libc::bind(
                    fd.as_raw_fd(),
                    (&addr as *const libc::sockaddr_xdp).cast::<libc::sockaddr>(),
                    size_of::<libc::sockaddr_xdp>() as libc::socklen_t,
                )
            };
            if result < 0 {
                return Err(io::Error::last_os_error()).context("AF_XDP socket bind failed");
            }

            Ok(Self { fd })
        }
    }

    impl AsRawFd for AfXdpSocket {
        fn as_raw_fd(&self) -> std::os::fd::RawFd {
            self.fd.as_raw_fd()
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
        use std::{collections::VecDeque, num::NonZeroU32, time::Duration};

        use anyhow::Result;
        use crossbeam_channel::bounded;

        use super::{
            consumer_configs_for_interfaces, first_cpu_from_affinity_mask, parse_interface_irqs,
            poll_once, AfXdpConsumerConfig, AfXdpInterface, BackoffState, PacketSource,
            PollOutcome, BUSY_POLL_SPIN, DEFAULT_REDIRECT_BUDGET, IDLE_SLEEP, IDLE_SLEEP_AFTER,
        };

        struct FakeSource {
            packets: VecDeque<Option<Vec<u8>>>,
        }

        impl PacketSource for FakeSource {
            fn poll_packet(&mut self) -> Result<Option<Vec<u8>>> {
                Ok(self.packets.pop_front().flatten())
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
    use std::num::NonZeroU32;

    use anyhow::Result;
    use crossbeam_channel::Receiver;

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

    impl AfXdpConsumers {
        pub fn start(_interfaces: &[String]) -> Result<Self> {
            Ok(Self {
                streams: Vec::new(),
            })
        }

        pub fn streams(&self) -> &[AfXdpStream] {
            &self.streams
        }

        pub fn take_streams(&mut self) -> Vec<AfXdpStream> {
            std::mem::take(&mut self.streams)
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::{AfXdpConsumerConfig, AfXdpConsumers, AfXdpInterface, AfXdpPacket, AfXdpStream};

#[cfg(not(target_os = "linux"))]
pub use non_linux::{
    AfXdpConsumerConfig, AfXdpConsumers, AfXdpInterface, AfXdpPacket, AfXdpStream,
};
