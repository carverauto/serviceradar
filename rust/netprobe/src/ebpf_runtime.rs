use anyhow::{Context, Result};
use aya::{
    Ebpf,
    maps::{HashMap as AyaHashMap, ProgramArray},
    programs::{KProbe, SchedClassifier, TcAttachType, TracePoint, Xdp, XdpFlags, tc},
};
use nix::libc;
use tokio::sync::broadcast;

use std::{
    collections::VecDeque,
    io,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use crate::{
    af_xdp::{self, DEFAULT_REDIRECT_BUDGET},
    af_xdp_classifier::AfXdpClassifierRuntime,
    attribution::{AyaAttributionReader, FlowAttributionRuntime, FlowAttributionRuntimeConfig},
    config::Config,
    ebpf_loader::load_netprobe_ebpf,
    event_queue::EventSender,
    external_flow::SharedExternalFlowMatcher,
    fingerprint::{FingerprintAccumulator, P0fSignatureRuntime},
    kernel::ensure_supported_kernel,
    metrics::Metrics,
    proto::netprobe::{DpiEvent, FingerprintEvent, FlowAttributionEvent, ProcessSnapshot},
    runtime_config::{DpiEventGate, FingerprintEventGate},
};

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct InterfaceConfig {
    enabled: u32,
    redirect_budget: u32,
    flags: u32,
    xsk_queue_count: u32,
}

// SAFETY: InterfaceConfig is #[repr(C)] and contains only u32 integer fields. It
// matches the eBPF-side InterfaceConfig map value ABI exactly and has no padding
// that can contain references or invalid bit patterns.
unsafe impl aya::Pod for InterfaceConfig {}

const SAMPLING_MIN_BUDGET: u32 = 1;
const SAMPLING_CPU_PRESSURE_THRESHOLD: f64 = 5.0;
const SAMPLING_WINDOW: Duration = Duration::from_secs(30);
const SAMPLING_INTERVAL: Duration = Duration::from_secs(5);

pub struct NetprobeEbpfRuntime {
    // The packet-capture / DPI / fingerprint / AF_XDP-sampling runtimes only run
    // when at least one capture interface is configured. In attribution-only mode
    // they are absent, so netprobe stays bounded and never touches the data path.
    _classifier_runtime: Option<AfXdpClassifierRuntime>,
    _p0f_runtime: Option<P0fSignatureRuntime>,
    _attribution_runtime: FlowAttributionRuntime,
    _sampling_runtime: Option<AdaptiveSamplingRuntime>,
    // In attribution-only mode we don't run the fingerprint/DPI producers, but the
    // IPC server streams those event types to the agent; dropping the senders would
    // close those channels and disconnect the agent. Hold them open (no producer).
    _fingerprint_keepalive: Option<EventSender<FingerprintEvent>>,
    _dpi_keepalive: Option<EventSender<DpiEvent>>,
    _ebpf: Ebpf,
}

impl NetprobeEbpfRuntime {
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        object_path: &Path,
        config: &Config,
        metrics: Metrics,
        fingerprint_events: EventSender<FingerprintEvent>,
        dpi_events: EventSender<DpiEvent>,
        flow_attribution_events: Option<EventSender<Arc<FlowAttributionEvent>>>,
        process_snapshots: broadcast::Sender<ProcessSnapshot>,
        external_flow_matcher: SharedExternalFlowMatcher,
        fingerprint_gate: Arc<std::sync::Mutex<FingerprintEventGate>>,
        dpi_gate: Arc<DpiEventGate>,
    ) -> Result<Self> {
        let kernel = ensure_supported_kernel()?;
        log::info!(
            "netprobe eBPF capture kernel check passed: {}",
            kernel.release
        );
        let mut ebpf = load_netprobe_ebpf(object_path, config)?;
        // Attach the global socket-lifecycle attribution probes. These populate
        // the flow_to_pid / process_info maps the FlowAttributionRuntime polls.
        // They are GLOBAL kernel hooks (not per-interface), so flow attribution
        // works regardless of capture_interfaces and independently of the
        // AF_XDP/XDP/TC packet-capture path. Previously these programs were
        // compiled into the object but never loaded/attached, so flow_to_pid
        // stayed empty and no FlowAttributionEvent was ever emitted.
        attach_attribution_probes(&mut ebpf)?;
        // Flow attribution (kprobe-driven) runs in EVERY mode, before and
        // independently of the packet-capture data path.
        let attribution_reader = AyaAttributionReader::from_ebpf(&mut ebpf)?;
        let attribution_runtime = FlowAttributionRuntime::start(
            attribution_reader,
            flow_attribution_events,
            process_snapshots,
            external_flow_matcher,
            metrics.clone(),
            flow_attribution_runtime_config(config),
        )?;

        if config.capture_interfaces.is_empty() {
            // Attribution-only mode: no capture interface configured. Run ONLY the
            // global kprobe attribution path — no TC/XDP/AF_XDP (so no host-NIC
            // black-hole) and no fingerprint/DPI/sampling runtimes (so no busy-poll
            // CPU or spurious events). netprobe stays a bounded, well-behaved daemon
            // whether or not the agent is connected. The fingerprint/DPI IPC senders
            // are held open (no producer) so those agent streams don't close.
            return Ok(Self::attribution_only(
                ebpf,
                attribution_runtime,
                fingerprint_events,
                dpi_events,
                "0 capture interfaces",
            ));
        }

        if let Some(interface) = config
            .capture_interfaces
            .iter()
            .find(|interface| is_default_route_interface(interface))
        {
            log::warn!(
                "netprobe packet capture disabled on {interface}: the interface carries the host default route and AF_XDP/XDP redirect would black-hole host connectivity; kprobe flow attribution remains active"
            );
            return Ok(Self::attribution_only(
                ebpf,
                attribution_runtime,
                fingerprint_events,
                dpi_events,
                "unsafe capture interface",
            ));
        }

        // Capture mode: at least one interface is configured. Bring up the
        // fingerprint/DPI/sampling runtimes and the TC/AF_XDP capture data path.
        let interfaces = af_xdp::resolve_interfaces(&config.capture_interfaces)
            .context("failed to resolve AF_XDP capture interfaces")?;
        let fingerprint_accumulator = FingerprintAccumulator::default();
        let p0f_runtime = P0fSignatureRuntime::start_from_ebpf(
            fingerprint_interface_name(config),
            &mut ebpf,
            fingerprint_events,
            fingerprint_gate,
            fingerprint_accumulator.clone(),
            metrics.clone(),
        )?;
        let interface_allowlist = populate_interface_allowlist(&mut ebpf, &interfaces)?;
        let sampling_runtime = AdaptiveSamplingRuntime::start(
            interface_allowlist,
            interfaces.clone(),
            metrics.clone(),
        )
        .context("failed to start AF_XDP adaptive sampling runtime")?;
        let classifier_runtime = AfXdpClassifierRuntime::start_from_ebpf(
            &config.capture_interfaces,
            &mut ebpf,
            metrics,
            dpi_events,
            dpi_gate,
            fingerprint_accumulator,
        )?;
        // Load the tail-call target (netprobe_tc_syn_signature) and populate the
        // jump table BEFORE attaching the classifiers, so their tail calls land.
        setup_tc_tail_calls(&mut ebpf)?;
        attach_tc_programs(&mut ebpf, &config.capture_interfaces)?;
        // The XDP program owns the AF_XDP/XSKMAP redirect (TC cannot redirect into
        // an XSKMAP). attach_xdp_program refuses the host's primary/default-route
        // NIC (#3 guard) so capture can never black-hole host connectivity.
        attach_xdp_program(&mut ebpf, &config.capture_interfaces)?;

        Ok(Self {
            _classifier_runtime: Some(classifier_runtime),
            _p0f_runtime: Some(p0f_runtime),
            _attribution_runtime: attribution_runtime,
            _sampling_runtime: Some(sampling_runtime),
            _fingerprint_keepalive: None,
            _dpi_keepalive: None,
            _ebpf: ebpf,
        })
    }

    fn attribution_only(
        ebpf: Ebpf,
        attribution_runtime: FlowAttributionRuntime,
        fingerprint_events: EventSender<FingerprintEvent>,
        dpi_events: EventSender<DpiEvent>,
        reason: &str,
    ) -> Self {
        log::info!(
            "netprobe attribution-only mode ({reason}): kprobe flow attribution active; packet capture, DPI, fingerprinting, and AF_XDP are disabled"
        );
        Self {
            _classifier_runtime: None,
            _p0f_runtime: None,
            _attribution_runtime: attribution_runtime,
            _sampling_runtime: None,
            _fingerprint_keepalive: Some(fingerprint_events),
            _dpi_keepalive: Some(dpi_events),
            _ebpf: ebpf,
        }
    }
}

fn flow_attribution_runtime_config(config: &Config) -> FlowAttributionRuntimeConfig {
    FlowAttributionRuntimeConfig {
        process_snapshot_interval: (config.process_snapshot_interval_s > 0)
            .then(|| Duration::from_secs(config.process_snapshot_interval_s)),
        resend_interval: (config.flow_attribution_resend_interval_s > 0)
            .then(|| Duration::from_secs(config.flow_attribution_resend_interval_s)),
    }
}

fn fingerprint_interface_name(config: &Config) -> String {
    match config.capture_interfaces.as_slice() {
        [interface] => interface.clone(),
        _ => "ebpf".to_owned(),
    }
}

fn populate_interface_allowlist(
    ebpf: &mut Ebpf,
    interfaces: &[af_xdp::AfXdpInterface],
) -> Result<AyaHashMap<aya::maps::MapData, u32, InterfaceConfig>> {
    let map = ebpf.take_map("interface_allowlist").ok_or_else(|| {
        anyhow::anyhow!("interface_allowlist map is missing from netprobe eBPF object")
    })?;
    let mut map = AyaHashMap::try_from(map)?;

    for interface in interfaces {
        let config = InterfaceConfig {
            enabled: 1,
            redirect_budget: DEFAULT_REDIRECT_BUDGET,
            flags: 0,
            xsk_queue_count: interface.queue_count.get(),
        };
        map.insert(interface.ifindex, config, 0)
            .with_context(|| format!("failed to allow AF_XDP interface {}", interface.name))?;
    }

    Ok(map)
}

struct AdaptiveSamplingRuntime {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl AdaptiveSamplingRuntime {
    fn start(
        mut interface_allowlist: AyaHashMap<aya::maps::MapData, u32, InterfaceConfig>,
        interfaces: Vec<af_xdp::AfXdpInterface>,
        metrics: Metrics,
    ) -> Result<Self> {
        metrics.set_sampling_budget(DEFAULT_REDIRECT_BUDGET);
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("netprobe-af-xdp-sampling".to_owned())
            .spawn(move || {
                let mut sampler = CpuWindowSampler::new();
                let mut budget = DEFAULT_REDIRECT_BUDGET;
                while !stop_worker.load(Ordering::Relaxed) {
                    if let Some(cpu_percent) = sampler.sample() {
                        let next_budget = next_sampling_budget(
                            budget,
                            sampler.window_duration(),
                            sampler.average_cpu_percent(),
                            cpu_percent,
                        );
                        if next_budget != budget {
                            budget = next_budget;
                            metrics.set_sampling_budget(budget);
                            if let Err(err) = update_sampling_budget(
                                &mut interface_allowlist,
                                &interfaces,
                                budget,
                            ) {
                                log::warn!("failed to update AF_XDP sampling budget: {err:#}");
                            }
                        }
                    }
                    thread::sleep(SAMPLING_INTERVAL);
                }
            })
            .context("failed to spawn AF_XDP adaptive sampling thread")?;

        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

impl Drop for AdaptiveSamplingRuntime {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            log::warn!("AF_XDP adaptive sampling thread panicked during shutdown");
        }
    }
}

fn update_sampling_budget(
    map: &mut AyaHashMap<aya::maps::MapData, u32, InterfaceConfig>,
    interfaces: &[af_xdp::AfXdpInterface],
    budget: u32,
) -> Result<()> {
    for interface in interfaces {
        let config = InterfaceConfig {
            enabled: 1,
            redirect_budget: budget,
            flags: 0,
            xsk_queue_count: interface.queue_count.get(),
        };
        map.insert(interface.ifindex, config, 0)
            .with_context(|| format!("failed to update sampling budget for {}", interface.name))?;
    }
    Ok(())
}

fn next_sampling_budget(
    current: u32,
    window_duration: Duration,
    average_cpu_percent: f64,
    latest_cpu_percent: f64,
) -> u32 {
    let pressure_sustained = window_duration >= SAMPLING_WINDOW
        && average_cpu_percent > SAMPLING_CPU_PRESSURE_THRESHOLD
        && latest_cpu_percent > SAMPLING_CPU_PRESSURE_THRESHOLD;
    if pressure_sustained {
        return current.saturating_sub(current / 2).max(SAMPLING_MIN_BUDGET);
    }
    if average_cpu_percent < SAMPLING_CPU_PRESSURE_THRESHOLD / 2.0 {
        return current.saturating_add(1).min(DEFAULT_REDIRECT_BUDGET);
    }
    current
}

struct CpuWindowSampler {
    previous_cpu_ticks: Option<u64>,
    previous_observed_at: Option<Instant>,
    samples: VecDeque<(Instant, f64)>,
    ticks_per_second: f64,
}

impl CpuWindowSampler {
    fn new() -> Self {
        Self {
            previous_cpu_ticks: None,
            previous_observed_at: None,
            samples: VecDeque::new(),
            ticks_per_second: ticks_per_second(),
        }
    }

    fn sample(&mut self) -> Option<f64> {
        let observed_at = Instant::now();
        let cpu_ticks = process_cpu_ticks().ok()?;
        let previous_ticks = self.previous_cpu_ticks;
        let previous_observed_at = self.previous_observed_at;
        self.previous_cpu_ticks = Some(cpu_ticks);
        self.previous_observed_at = Some(observed_at);
        let (Some(previous_ticks), Some(previous_observed_at)) =
            (previous_ticks, previous_observed_at)
        else {
            return None;
        };
        let elapsed = observed_at.duration_since(previous_observed_at);
        if elapsed.is_zero() || self.ticks_per_second <= 0.0 {
            return None;
        }
        let cpu_seconds = cpu_ticks.saturating_sub(previous_ticks) as f64 / self.ticks_per_second;
        let cpu_percent = (cpu_seconds / elapsed.as_secs_f64()) * 100.0;
        self.samples.push_back((observed_at, cpu_percent));
        while self.samples.front().is_some_and(|(sampled_at, _)| {
            observed_at.duration_since(*sampled_at) > SAMPLING_WINDOW
        }) {
            self.samples.pop_front();
        }
        Some(cpu_percent)
    }

    fn window_duration(&self) -> Duration {
        match (self.samples.front(), self.samples.back()) {
            (Some((first, _)), Some((last, _))) => last.duration_since(*first),
            _ => Duration::ZERO,
        }
    }

    fn average_cpu_percent(&self) -> f64 {
        if self.samples.is_empty() {
            return 0.0;
        }
        self.samples.iter().map(|(_, cpu)| *cpu).sum::<f64>() / self.samples.len() as f64
    }
}

fn ticks_per_second() -> f64 {
    let value = unsafe {
        // SAFETY: sysconf is thread-safe; _SC_CLK_TCK has no pointer arguments.
        libc::sysconf(libc::_SC_CLK_TCK)
    };
    if value > 0 { value as f64 } else { 100.0 }
}

fn process_cpu_ticks() -> Result<u64> {
    let stat = std::fs::read_to_string("/proc/self/stat")?;
    let close_paren = stat
        .rfind(')')
        .ok_or_else(|| anyhow::anyhow!("malformed /proc/self/stat: missing comm terminator"))?;
    let fields: Vec<&str> = stat[close_paren + 2..].split_whitespace().collect();
    let user_ticks = fields
        .get(11)
        .ok_or_else(|| anyhow::anyhow!("malformed /proc/self/stat: missing utime"))?
        .parse::<u64>()?;
    let system_ticks = fields
        .get(12)
        .ok_or_else(|| anyhow::anyhow!("malformed /proc/self/stat: missing stime"))?
        .parse::<u64>()?;
    Ok(user_ticks.saturating_add(system_ticks))
}

// Index in the tc_tail_calls ProgramArray; must match TC_TAIL_SYN_SIGNATURE in
// the eBPF source (rust/netprobe/ebpf/src/lib.rs).
const TC_TAIL_SYN_SIGNATURE: u32 = 0;

// Loads the tail-call target (netprobe_tc_syn_signature) and registers its fd in
// the tc_tail_calls jump table so the TC classifiers can bpf_tail_call into it.
// The target is loaded (verified) but never attached to a hook.
fn setup_tc_tail_calls(ebpf: &mut Ebpf) -> Result<()> {
    let syn_fd = {
        let program: &mut SchedClassifier = ebpf
            .program_mut("netprobe_tc_syn_signature")
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "netprobe_tc_syn_signature program is missing from netprobe eBPF object"
                )
            })?
            .try_into()?;
        program
            .load()
            .context("failed to load TC program netprobe_tc_syn_signature")?;
        program
            .fd()
            .context("netprobe_tc_syn_signature has no fd after load")?
            .try_clone()
            .context("failed to clone netprobe_tc_syn_signature fd")?
    };
    let mut jump_table: ProgramArray<_> = ebpf
        .map_mut("tc_tail_calls")
        .ok_or_else(|| anyhow::anyhow!("tc_tail_calls map is missing from netprobe eBPF object"))?
        .try_into()?;
    jump_table
        .set(TC_TAIL_SYN_SIGNATURE, &syn_fd, 0)
        .context("failed to register netprobe_tc_syn_signature in tc_tail_calls jump table")?;
    Ok(())
}

fn attach_tc_programs(ebpf: &mut Ebpf, interfaces: &[String]) -> Result<()> {
    for interface in interfaces {
        ensure_clsact(interface)?;
    }

    attach_tc_program(
        ebpf,
        "netprobe_tc_ingress",
        interfaces,
        TcAttachType::Ingress,
    )?;
    attach_tc_program(ebpf, "netprobe_tc_egress", interfaces, TcAttachType::Egress)
}

// Returns true if `interface` carries the host's IPv4 or IPv6 default route.
// Used to refuse attaching the consuming AF_XDP/XDP redirect to the host's
// primary/management NIC (which would black-hole connectivity).
fn is_default_route_interface(interface: &str) -> bool {
    // IPv4: /proc/net/route rows with Destination 00000000 are the default route.
    if let Ok(contents) = std::fs::read_to_string("/proc/net/route") {
        for line in contents.lines().skip(1) {
            let mut fields = line.split_whitespace();
            if let (Some(iface), Some(dest)) = (fields.next(), fields.next())
                && dest == "00000000"
                && iface == interface
            {
                return true;
            }
        }
    }
    // IPv6: /proc/net/ipv6_route rows with a /0 prefix (dest len 00) are default.
    if let Ok(contents) = std::fs::read_to_string("/proc/net/ipv6_route") {
        for line in contents.lines() {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() >= 10 {
                let dest_prefix_len = fields[1];
                let iface = fields[9];
                if dest_prefix_len == "00" && iface == interface {
                    return true;
                }
            }
        }
    }
    false
}

fn attach_xdp_program(ebpf: &mut Ebpf, interfaces: &[String]) -> Result<()> {
    // SAFETY GUARD (#3): the XDP program XDP_REDIRECTs ingress into the AF_XDP
    // XSKMAP, which CONSUMES the frame — the kernel network stack never sees it.
    // Attaching it to the host's primary/default-route NIC therefore black-holes
    // host connectivity (SSH, the agent's own gateway traffic, etc.). Refuse it;
    // packet capture must run on a dedicated or mirror/SPAN interface.
    for interface in interfaces {
        if is_default_route_interface(interface) {
            anyhow::bail!(
                "refusing to attach the netprobe AF_XDP/XDP redirect to '{interface}': it carries the host default route and the redirect would black-hole host connectivity. Configure a dedicated or mirror capture interface instead."
            );
        }
    }
    let program: &mut Xdp = ebpf
        .program_mut("netprobe_xdp_ingress")
        .ok_or_else(|| {
            anyhow::anyhow!("netprobe_xdp_ingress program is missing from netprobe eBPF object")
        })?
        .try_into()?;
    program
        .load()
        .context("failed to load XDP program netprobe_xdp_ingress")?;

    for interface in interfaces {
        // Try native/driver XDP first; fall back to generic (SKB) mode for NICs
        // without native XDP support (e.g. virtio-net). AF_XDP capture works in
        // either mode via XDP_COPY; native is just higher throughput.
        match program.attach(interface, XdpFlags::default()) {
            Ok(_) => {}
            Err(err) => {
                log::warn!(
                    "native XDP attach failed on {interface} ({err:#}); retrying in SKB (generic) mode"
                );
                program
                    .attach(interface, XdpFlags::SKB_MODE)
                    .with_context(|| {
                        format!("failed to attach netprobe_xdp_ingress to {interface}")
                    })?;
            }
        }
    }

    Ok(())
}

// Load + attach the socket-lifecycle kprobes/kretprobe/tracepoint that emit
// FlowAttributionRecord -> flow_to_pid / process_info (rust/netprobe/ebpf/src/lib.rs).
// These are global kernel hooks, so they require no capture interface and never
// touch the host data path (unlike the AF_XDP/XDP redirect). aya keeps each link
// alive inside the owned `Ebpf`, so attribution persists for the runtime's life.
fn attach_attribution_probes(ebpf: &mut Ebpf) -> Result<()> {
    // tcp_connect/tcp_close/udp_sendmsg/udp_recvmsg are kprobes; inet_csk_accept
    // is a kretprobe. aya represents both as KProbe and attaches by the program's
    // section kind, so the same load/attach call works for all of them.
    for name in [
        "tcp_connect",
        "inet_csk_accept",
        "tcp_close",
        "udp_sendmsg",
        "udp_recvmsg",
    ] {
        let program: &mut KProbe = ebpf
            .program_mut(name)
            .ok_or_else(|| anyhow::anyhow!("{name} probe is missing from netprobe eBPF object"))?
            .try_into()?;
        program
            .load()
            .with_context(|| format!("failed to load attribution probe {name}"))?;
        program
            .attach(name, 0)
            .with_context(|| format!("failed to attach attribution probe {name}"))?;
    }

    let tracepoint: &mut TracePoint = ebpf
        .program_mut("inet_sock_set_state")
        .ok_or_else(|| {
            anyhow::anyhow!("inet_sock_set_state tracepoint is missing from netprobe eBPF object")
        })?
        .try_into()?;
    tracepoint
        .load()
        .context("failed to load attribution tracepoint inet_sock_set_state")?;
    tracepoint
        .attach("sock", "inet_sock_set_state")
        .context("failed to attach attribution tracepoint inet_sock_set_state")?;

    for name in ["sched_process_exec", "sched_process_exit"] {
        let tracepoint: &mut TracePoint = ebpf
            .program_mut(name)
            .ok_or_else(|| {
                anyhow::anyhow!("{name} tracepoint is missing from netprobe eBPF object")
            })?
            .try_into()?;
        tracepoint
            .load()
            .with_context(|| format!("failed to load attribution tracepoint {name}"))?;
        tracepoint
            .attach("sched", name)
            .with_context(|| format!("failed to attach attribution tracepoint {name}"))?;
    }

    // Best-effort optional probes. ICMP echo: ping_v4_sendmsg / ping_v6_sendmsg
    // (dgram ICMP / ICMPv6) + raw_sendmsg / rawv6_sendmsg (raw). IPv6 UDP:
    // udpv6_sendmsg / udpv6_recvmsg — the v4 udp_* hooks attached mandatorily above
    // do NOT carry IPv6 UDP. These symbols depend on kernel config (e.g. IPv6
    // disabled) and may not exist, so attach best-effort: a missing optional hook
    // must NOT take down the core TCP/UDP attribution that just loaded.
    for name in [
        "ping_v4_sendmsg",
        "raw_sendmsg",
        "ping_v6_sendmsg",
        "rawv6_sendmsg",
        "udpv6_sendmsg",
        "udpv6_recvmsg",
    ] {
        if let Err(err) = attach_optional_probe(ebpf, name) {
            log::warn!("netprobe optional attribution probe {name} not attached: {err:#}");
        }
    }

    Ok(())
}

// Load + attach one best-effort optional kprobe (v4/v6 ICMP, IPv6 UDP). Returns
// Err (logged, non-fatal by the caller) if the program is missing, fails to load,
// or fails to attach — e.g. the kernel symbol does not exist on this build.
fn attach_optional_probe(ebpf: &mut Ebpf, name: &str) -> Result<()> {
    let program: &mut KProbe = ebpf
        .program_mut(name)
        .ok_or_else(|| anyhow::anyhow!("{name} probe is missing from netprobe eBPF object"))?
        .try_into()?;
    program
        .load()
        .with_context(|| format!("failed to load optional attribution probe {name}"))?;
    program
        .attach(name, 0)
        .with_context(|| format!("failed to attach optional attribution probe {name}"))?;
    Ok(())
}

fn attach_tc_program(
    ebpf: &mut Ebpf,
    name: &str,
    interfaces: &[String],
    attach_type: TcAttachType,
) -> Result<()> {
    let program: &mut SchedClassifier = ebpf
        .program_mut(name)
        .ok_or_else(|| anyhow::anyhow!("{name} program is missing from netprobe eBPF object"))?
        .try_into()?;
    program
        .load()
        .with_context(|| format!("failed to load TC program {name}"))?;

    for interface in interfaces {
        program
            .attach(interface, attach_type)
            .with_context(|| format!("failed to attach {name} to {interface}"))?;
    }

    Ok(())
}

fn ensure_clsact(interface: &str) -> Result<()> {
    match tc::qdisc_add_clsact(interface) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(err) => Err(err).with_context(|| format!("failed to add clsact qdisc to {interface}")),
    }
}
