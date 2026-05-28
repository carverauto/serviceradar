#[cfg(target_os = "linux")]
mod linux {
    use std::{
        fs, io,
        mem::size_of,
        os::fd::{AsRawFd, FromRawFd, OwnedFd},
        path::Path,
        sync::{
            atomic::{AtomicBool, Ordering},
            mpsc::{sync_channel, Receiver, SyncSender},
            Arc,
        },
        thread::{self, JoinHandle},
        time::Duration,
    };

    use anyhow::{Context, Result};
    use nix::libc;

    const CHANNEL_CAPACITY: usize = 4096;
    const DEFAULT_QUEUE_ID: u32 = 0;
    const BUSY_POLL_SPIN: Duration = Duration::from_micros(10);
    const IDLE_SLEEP: Duration = Duration::from_millis(1);
    const IDLE_SLEEP_AFTER: Duration = Duration::from_millis(100);

    #[derive(Debug)]
    pub struct AfXdpPacket {
        pub interface: String,
        pub ifindex: u32,
        pub queue_id: u32,
        pub data: Vec<u8>,
    }

    pub struct AfXdpConsumers {
        shutdown: Arc<AtomicBool>,
        threads: Vec<JoinHandle<()>>,
    }

    impl AfXdpConsumers {
        pub fn start(interfaces: &[String]) -> Result<(Self, Receiver<AfXdpPacket>)> {
            let shutdown = Arc::new(AtomicBool::new(false));
            let (tx, rx) = sync_channel(CHANNEL_CAPACITY);
            let mut threads = Vec::with_capacity(interfaces.len());

            for interface in interfaces {
                let ifindex = read_interface_index(interface)
                    .with_context(|| format!("failed to resolve ifindex for {interface}"))?;
                let preferred_core = preferred_core_for_interface(interface);
                let tx = tx.clone();
                let shutdown_worker = Arc::clone(&shutdown);
                let interface = interface.clone();
                let thread = thread::Builder::new()
                    .name(format!("netprobe-af-xdp-{interface}"))
                    .spawn(move || {
                        if let Err(err) = run_consumer(
                            interface,
                            ifindex,
                            DEFAULT_QUEUE_ID,
                            preferred_core,
                            tx,
                            shutdown_worker,
                        ) {
                            log::warn!("AF_XDP consumer exited: {err:#}");
                        }
                    })
                    .context("failed to spawn AF_XDP consumer thread")?;
                threads.push(thread);
            }

            Ok((Self { shutdown, threads }, rx))
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
        interface: String,
        ifindex: u32,
        queue_id: u32,
        preferred_core: Option<usize>,
        _tx: SyncSender<AfXdpPacket>,
        shutdown: Arc<AtomicBool>,
    ) -> Result<()> {
        if let Some(core) = preferred_core {
            pin_current_thread(core).with_context(|| {
                format!("failed to pin {interface} AF_XDP thread to CPU {core}")
            })?;
        }

        let _socket = AfXdpSocket::bind(ifindex, queue_id)
            .with_context(|| format!("failed to bind AF_XDP socket for {interface}"))?;
        let mut idle_for = Duration::ZERO;

        while !shutdown.load(Ordering::Relaxed) {
            thread::sleep(if idle_for >= IDLE_SLEEP_AFTER {
                IDLE_SLEEP
            } else {
                BUSY_POLL_SPIN
            });
            idle_for = idle_for.saturating_add(BUSY_POLL_SPIN);
        }

        Ok(())
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

    fn read_interface_index(interface: &str) -> Result<u32> {
        let path = Path::new("/sys/class/net").join(interface).join("ifindex");
        let contents = fs::read_to_string(&path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        contents
            .trim()
            .parse::<u32>()
            .with_context(|| format!("failed to parse {}", path.display()))
    }

    fn preferred_core_for_interface(interface: &str) -> Option<usize> {
        let interrupts = fs::read_to_string("/proc/interrupts").ok()?;
        let irqs = parse_interface_irqs(&interrupts, interface);
        for irq in irqs {
            let path = format!("/proc/irq/{irq}/smp_affinity");
            let mask = fs::read_to_string(path).ok()?;
            if let Some(core) = first_cpu_from_affinity_mask(mask.trim()) {
                return Some(core);
            }
        }

        None
    }

    fn parse_interface_irqs(interrupts: &str, interface: &str) -> Vec<u32> {
        let mut irqs = Vec::new();
        for line in interrupts.lines() {
            if !line.contains(interface) {
                continue;
            }
            let Some((irq, _rest)) = line.split_once(':') else {
                continue;
            };
            if let Ok(irq) = irq.trim().parse::<u32>() {
                irqs.push(irq);
            }
        }

        irqs
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
        use super::{first_cpu_from_affinity_mask, parse_interface_irqs};

        #[test]
        fn parses_interface_irqs() {
            let interrupts = "\
 32: 0 1 2 3 PCI-MSI eth0-TxRx-0
 33: 0 1 2 3 PCI-MSI enp3s0-rx-0
NMI: 0 0 0 0 Non-maskable interrupts
";

            assert_eq!(parse_interface_irqs(interrupts, "eth0"), vec![32]);
            assert_eq!(parse_interface_irqs(interrupts, "enp3s0"), vec![33]);
        }

        #[test]
        fn parses_first_cpu_from_affinity_mask() {
            assert_eq!(first_cpu_from_affinity_mask("00000001"), Some(0));
            assert_eq!(first_cpu_from_affinity_mask("00000010"), Some(4));
            assert_eq!(first_cpu_from_affinity_mask("00000000,00000004"), Some(2));
            assert_eq!(first_cpu_from_affinity_mask("00000000"), None);
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod non_linux {
    use std::sync::mpsc::{sync_channel, Receiver};

    use anyhow::Result;

    #[derive(Debug)]
    pub struct AfXdpPacket {
        pub interface: String,
        pub ifindex: u32,
        pub queue_id: u32,
        pub data: Vec<u8>,
    }

    pub struct AfXdpConsumers;

    impl AfXdpConsumers {
        pub fn start(_interfaces: &[String]) -> Result<(Self, Receiver<AfXdpPacket>)> {
            let (_tx, rx) = sync_channel(1);
            Ok((Self, rx))
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::{AfXdpConsumers, AfXdpPacket};

#[cfg(not(target_os = "linux"))]
pub use non_linux::{AfXdpConsumers, AfXdpPacket};
