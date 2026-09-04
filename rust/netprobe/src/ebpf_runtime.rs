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
    census::DeviceCensusRuntime,
    config::Config,
    ebpf_loader::load_netprobe_ebpf,
    event_queue::EventSender,
    external_flow::SharedExternalFlowMatcher,
    fingerprint::{FingerprintAccumulator, P0fSignatureRuntime},
    kernel::ensure_supported_kernel,
    kernel_layout::{InetSockSetStateLayout, detect_inet_sock_set_state_layout},
    mdns::runtime::MdnsRuntime,
    metrics::Metrics,
    proto::netprobe::{
        DeviceCensusSnapshot, DpiEvent, FingerprintEvent, FlowAttributionEvent, MdnsSnapshot,
        ProcessSnapshot,
    },
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
    _census_runtime: Option<DeviceCensusRuntime>,
    _mdns_runtime: Option<MdnsRuntime>,
    _attribution_runtime: FlowAttributionRuntime,
    _sampling_runtime: Option<AdaptiveSamplingRuntime>,
    // In attribution-only mode we don't run the fingerprint/DPI producers, but the
    // IPC server streams those event types to the agent; dropping the senders would
    // close those channels and disconnect the agent. Hold them open (no producer).
    _fingerprint_keepalive: Option<broadcast::Sender<FingerprintEvent>>,
    _dpi_keepalive: Option<broadcast::Sender<DpiEvent>>,
    _ebpf: Ebpf,
}

impl NetprobeEbpfRuntime {
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        object_path: &Path,
        config: &Config,
        metrics: Metrics,
        fingerprint_events: broadcast::Sender<FingerprintEvent>,
        dpi_events: broadcast::Sender<DpiEvent>,
        flow_attribution_events: Option<EventSender<Arc<FlowAttributionEvent>>>,
        process_snapshots: broadcast::Sender<ProcessSnapshot>,
        census_snapshots: broadcast::Sender<DeviceCensusSnapshot>,
        mdns_snapshots: broadcast::Sender<MdnsSnapshot>,
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
        let tcp_layout = match attach_attribution_probes(&mut ebpf) {
            Ok(layout) => layout,
            Err(err) => {
                metrics.inc_attribution_stage("program_attach", "tcp", "failed");
                return Err(err);
            }
        };
        metrics.inc_attribution_stage("program_attach", "tcp", "ready");
        metrics.inc_attribution_stage("tracepoint_layout", "tcp", tcp_layout.metric_outcome());
        // Flow attribution (kprobe-driven) runs in EVERY mode, before and
        // independently of the packet-capture data path.
        let attribution_reader = match AyaAttributionReader::from_ebpf(&mut ebpf) {
            Ok(reader) => {
                metrics.inc_attribution_stage("ring_reader", "tcp", "ready");
                reader
            }
            Err(err) => {
                metrics.inc_attribution_stage("ring_reader", "tcp", "failed");
                return Err(err);
            }
        };
        let attribution_runtime = FlowAttributionRuntime::start(
            attribution_reader,
            flow_attribution_events,
            process_snapshots,
            external_flow_matcher,
            metrics.clone(),
            flow_attribution_runtime_config(config),
        )?;
        metrics.inc_attribution_stage("userspace_runtime", "tcp", "ready");

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
            // The passive device census still runs here, and this is the case
            // that matters most: a host with a single NIC carrying the default
            // route is the ordinary deployment, and it is exactly the segment
            // whose devices we want to see. Only the AF_XDP/XDP *redirect* can
            // black-hole traffic -- netprobe_tc_ingress observes and returns
            // TC_ACT_OK, diverting nothing. So attach the ingress classifier
            // (and nothing else) and let the census run.
            let (census_runtime, mdns_runtime) = match Self::start_census_only(
                &mut ebpf,
                &config.capture_interfaces,
                census_snapshots,
                mdns_snapshots,
            ) {
                Ok((census, mdns)) => (Some(census), mdns),
                Err(err) => {
                    // A census failure must never take down flow attribution.
                    log::warn!("netprobe passive device census disabled: {err:#}");
                    (None, None)
                }
            };
            return Ok(Self::attribution_only_with_census(
                ebpf,
                attribution_runtime,
                fingerprint_events,
                dpi_events,
                "unsafe capture interface",
                census_runtime,
                mdns_runtime,
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
        // Passive device census: consumes the l2_observations ring the TC
        // ingress classifier feeds. Started before the allowlist is populated
        // so no observation is produced before there is a reader.
        let census_runtime = DeviceCensusRuntime::start_from_ebpf(
            fingerprint_interface_name(config),
            &mut ebpf,
            census_snapshots,
        )
        .context("failed to start passive device census runtime")?;

        // The mDNS collector is optional in the strong sense: it identifies
        // devices the census has already found, so losing it costs device TYPE
        // and nothing else. It must never be able to take down the census that
        // supplies the MAC binding it enriches.
        let mdns_runtime = match MdnsRuntime::start_from_ebpf(
            fingerprint_interface_name(config),
            &mut ebpf,
            mdns_snapshots.clone(),
        ) {
            Ok(runtime) => Some(runtime),
            Err(err) => {
                log::warn!("netprobe mDNS collector disabled: {err:#}");
                None
            }
        };
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
            _census_runtime: Some(census_runtime),
            _mdns_runtime: mdns_runtime,
            _attribution_runtime: attribution_runtime,
            _sampling_runtime: Some(sampling_runtime),
            _fingerprint_keepalive: None,
            _dpi_keepalive: None,
            _ebpf: ebpf,
        })
    }

    // Attach ONLY netprobe_tc_ingress and start the census. Deliberately does
    // not touch XDP, AF_XDP, or the egress classifier: egress frames carry this
    // host's own source MAC and say nothing about the segment.
    // Returns both runtimes: this is the path the ORDINARY deployment takes -- a
    // single NIC carrying the default route -- so the mDNS collector has to start
    // here or it never runs anywhere that matters.
    fn start_census_only(
        ebpf: &mut Ebpf,
        capture_interfaces: &[String],
        census_snapshots: broadcast::Sender<DeviceCensusSnapshot>,
        mdns_snapshots: broadcast::Sender<MdnsSnapshot>,
    ) -> Result<(DeviceCensusRuntime, Option<MdnsRuntime>)> {
        let interfaces = af_xdp::resolve_interfaces(capture_interfaces)
            .context("failed to resolve census interfaces")?;
        // The census gates on the same interface allowlist as flow accounting,
        // so it has to be populated even though no redirect will happen.
        let _allowlist = populate_interface_allowlist(ebpf, &interfaces)?;
        for interface in capture_interfaces {
            ensure_clsact(interface)?;
            // Census-only mode attaches ingress, but a PREVIOUS run may have
            // been in full-capture mode and left an egress classifier behind.
            // Clean both, or switching modes leaks the one this mode does not
            // re-attach and therefore never replaces.
            detach_stale_tc_programs(interface);
        }
        attach_tc_program(
            ebpf,
            "netprobe_tc_ingress",
            capture_interfaces,
            TcAttachType::Ingress,
        )?;
        let interface = capture_interfaces.first().cloned().unwrap_or_default();
        let runtime =
            DeviceCensusRuntime::start_from_ebpf(interface.clone(), ebpf, census_snapshots)?;
        log::info!(
            "netprobe passive device census active on {}: TC ingress only, no redirect",
            capture_interfaces.join(",")
        );

        // Failure here costs device TYPE, not device presence. The census must
        // survive it.
        let mdns = match MdnsRuntime::start_from_ebpf(interface, ebpf, mdns_snapshots) {
            Ok(mdns) => {
                log::info!(
                    "netprobe mDNS collector active on {}",
                    capture_interfaces.join(",")
                );
                Some(mdns)
            }
            Err(err) => {
                log::warn!("netprobe mDNS collector disabled: {err:#}");
                None
            }
        };

        Ok((runtime, mdns))
    }

    fn attribution_only_with_census(
        ebpf: Ebpf,
        attribution_runtime: FlowAttributionRuntime,
        fingerprint_events: broadcast::Sender<FingerprintEvent>,
        dpi_events: broadcast::Sender<DpiEvent>,
        reason: &str,
        census_runtime: Option<DeviceCensusRuntime>,
        mdns_runtime: Option<MdnsRuntime>,
    ) -> Self {
        let mut runtime = Self::attribution_only(
            ebpf,
            attribution_runtime,
            fingerprint_events,
            dpi_events,
            reason,
        );
        runtime._census_runtime = census_runtime;
        runtime._mdns_runtime = mdns_runtime;
        runtime
    }

    fn attribution_only(
        ebpf: Ebpf,
        attribution_runtime: FlowAttributionRuntime,
        fingerprint_events: broadcast::Sender<FingerprintEvent>,
        dpi_events: broadcast::Sender<DpiEvent>,
        reason: &str,
    ) -> Self {
        log::info!(
            "netprobe attribution-only mode ({reason}): kprobe flow attribution active; packet capture, DPI, fingerprinting, and AF_XDP are disabled"
        );
        Self {
            _classifier_runtime: None,
            _p0f_runtime: None,
            _census_runtime: None,
            _mdns_runtime: None,
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

// Every netprobe TC classifier, with the attach point it belongs to.
//
// Kept as one list so a detach sweep cannot fall behind the attach path: adding
// a classifier here is what makes the stale-cleanup cover it.
const NETPROBE_TC_PROGRAMS: [(&str, TcAttachType); 2] = [
    ("netprobe_tc_ingress", TcAttachType::Ingress),
    ("netprobe_tc_egress", TcAttachType::Egress),
];

/// Detach netprobe TC classifiers left behind by a previous run.
///
/// Re-attaching without this LEAKS A FILTER PER RESTART. TC permits several
/// filters at the same priority, so a second attach stacks rather than
/// replacing, and the kernel then runs every copy on every frame.
///
/// Observed on a live host: three copies of `netprobe_tc_ingress` attached at
/// once after three restarts, two of them from an older build. Every frame was
/// processed by stale programs and the measured observation rate was
/// meaningless -- the leak corrupts measurements long before it exhausts
/// anything.
///
/// systemd restarts do not reliably drop the link, and the unit is
/// `Restart=always`, so this runs before every attach rather than only on a
/// clean start.
///
/// Best-effort by design: a failure to clean up must not stop netprobe from
/// starting, because a host with a stale filter and no running collector is
/// strictly worse than one with a duplicate.
fn detach_stale_tc_programs(interface: &str) {
    for (name, attach_type) in NETPROBE_TC_PROGRAMS {
        match tc::qdisc_detach_program(interface, attach_type, name) {
            Ok(()) => log::info!("detached a stale {name} from {interface}"),
            // NotFound simply means there was nothing stale to clean up.
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => log::warn!("could not detach a stale {name} from {interface}: {err}"),
        }
    }
}

fn attach_tc_programs(ebpf: &mut Ebpf, interfaces: &[String]) -> Result<()> {
    for interface in interfaces {
        ensure_clsact(interface)?;
        // Full-capture mode attaches TWO classifiers, and neither replaces a
        // previous copy of itself. Without this the leak is two filters per
        // restart rather than one.
        detach_stale_tc_programs(interface);
    }

    // Iterating the same list the detach sweep uses, rather than naming the two
    // classifiers again here. Naming them twice is how the sweep fell behind in
    // the first place: egress was added to the attach path and not to the
    // cleanup, so it leaked on every restart while ingress did not.
    for (name, attach_type) in NETPROBE_TC_PROGRAMS {
        attach_tc_program(ebpf, name, interfaces, attach_type)?;
    }

    Ok(())
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
fn attach_attribution_probes(ebpf: &mut Ebpf) -> Result<InetSockSetStateLayout> {
    crate::kernel_layout::ensure_supported_sock_common_layout()?;
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

    let tcp_layout = detect_inet_sock_set_state_layout()?;
    let tracepoint_program = tcp_layout.program_name();
    let tracepoint: &mut TracePoint = ebpf
        .program_mut(tracepoint_program)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "TCP attribution unavailable: {tracepoint_program} is missing from netprobe eBPF object"
            )
        })?
        .try_into()?;
    tracepoint
        .load()
        .with_context(|| format!("failed to load attribution tracepoint {tracepoint_program}"))?;
    tracepoint
        .attach("sock", "inet_sock_set_state")
        .with_context(|| format!("failed to attach attribution tracepoint {tracepoint_program}"))?;

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

    Ok(tcp_layout)
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

#[cfg(all(test, target_os = "linux"))]
mod loaded_tcp_tests {
    use std::{
        fs,
        net::{IpAddr, Ipv4Addr, SocketAddrV4, TcpListener, TcpStream},
        path::{Path, PathBuf},
        sync::{Arc, mpsc},
        thread,
        time::{Duration, Instant, SystemTime, UNIX_EPOCH},
    };

    use anyhow::{Context, Result, bail};
    use aya::{EbpfLoader, maps::HashMap as AyaHashMap};
    use prometheus::{Encoder, TextEncoder};
    use tokio::sync::broadcast;

    use super::attach_attribution_probes;
    use crate::{
        af_xdp_classifier::{FlowKey, canonical_flow_key},
        attribution::{
            AyaAttributionReader, FlowAttributionRuntime, FlowAttributionRuntimeConfig,
            FlowPidRecord,
        },
        event_queue,
        external_flow::SharedExternalFlowMatcher,
        metrics::Metrics,
        proto::netprobe::FlowAttributionEvent,
    };

    const CAP_NET_ADMIN: u32 = 12;
    const CAP_PERFMON: u32 = 38;
    const CAP_BPF: u32 = 39;
    const TCP_ACCEPT_EVENT: u32 = 2;
    const EVENT_WAIT: Duration = Duration::from_secs(10);
    const SERVICE_TEST_PORT_START: u16 = 20_000;
    const SERVICE_TEST_PORT_END: u16 = 20_100;
    const TEST_PORT_START: u16 = 40_000;
    const TEST_PORT_END: u16 = 40_100;
    const EPHEMERAL_PORT_FLOOR: u16 = 32_768;

    /// Loads the production eBPF object and proves that real client and accepted
    /// server sockets reach the owner-resolved userspace event boundary.
    ///
    /// Run only through `//rust/netprobe:loaded_tcp_attribution_test` on a Linux
    /// worker granted CAP_BPF, CAP_PERFMON, and CAP_NET_ADMIN. The ordinary unit
    /// target leaves this ignored because an unprivileged skip would make the
    /// release gate lie.
    #[test]
    #[ignore = "requires Linux with CAP_BPF, CAP_PERFMON, and CAP_NET_ADMIN; run the dedicated Bazel target"]
    fn loaded_object_tcp_loopback_emits_owner_resolved_client_and_server_events() -> Result<()> {
        require_capability(CAP_NET_ADMIN, "CAP_NET_ADMIN")?;
        require_capability(CAP_BPF, "CAP_BPF")?;
        require_capability(CAP_PERFMON, "CAP_PERFMON")?;

        let object = PathBuf::from(
            std::env::var("NETPROBE_TEST_EBPF_OBJECT")
                .context("attach/readiness: NETPROBE_TEST_EBPF_OBJECT was not declared")?,
        );
        if !object.is_file() {
            bail!(
                "attach/readiness: declared production eBPF object is missing: {}",
                object.display()
            );
        }

        // Deliberately avoid the production pin directory: this test validates
        // the shipped object and runtime path without sharing map state with a
        // concurrently running netprobe daemon on a privileged verification host.
        let pin_directory = BpffsPinDirectory::create()?;
        let mut ebpf = EbpfLoader::new()
            .map_pin_path(pin_directory.path())
            .load_file(&object)
            .with_context(|| {
                format!(
                    "attach/readiness: load production object {} with isolated map pins under {}",
                    object.display(),
                    pin_directory.path().display()
                )
            })?;
        let layout = attach_attribution_probes(&mut ebpf)
            .context("attach/readiness: attach production attribution probes")?;
        let flow_to_pid_map = ebpf.take_map("flow_to_pid").context(
            "close handling: production object is missing flow_to_pid for cleanup proof",
        )?;
        let socket_to_pid_map = ebpf.take_map("socket_to_pid").context(
            "close handling: production object is missing socket_to_pid for cleanup proof",
        )?;
        let flow_to_pid: AyaHashMap<_, FlowKey, FlowPidRecord> =
            AyaHashMap::try_from(flow_to_pid_map)
                .context("close handling: open flow_to_pid map")?;
        let socket_to_pid: AyaHashMap<_, u64, FlowPidRecord> =
            AyaHashMap::try_from(socket_to_pid_map)
                .context("close handling: open socket_to_pid map")?;

        let reader = AyaAttributionReader::from_ebpf(&mut ebpf)
            .context("drain_ring readiness: open production flow_events ring")?;
        let (event_tx, mut event_rx) = event_queue::bounded(1024);
        let (process_snapshot_tx, _) = broadcast::channel(4);
        let metrics = Metrics::new().context("userspace readiness: create metrics registry")?;
        let runtime = FlowAttributionRuntime::start(
            reader,
            Some(event_tx),
            process_snapshot_tx,
            SharedExternalFlowMatcher::new(120_000),
            metrics.clone(),
            FlowAttributionRuntimeConfig {
                process_snapshot_interval: None,
                resend_interval: None,
            },
        )
        .context("drain_ring readiness: start production ring reader")?;

        // Give tracepoint/kprobe links and the reader thread a deterministic
        // readiness interval before generating the controlled stimulus.
        thread::sleep(Duration::from_millis(100));

        let listener = bind_test_listener()?;
        let listener_addr = listener
            .local_addr()
            .context("stimulus: read loopback listener address")?;
        let (accepted_tx, accepted_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || -> Result<()> {
            let accept_tid = linux_tid()?;
            let accept_comm = task_comm(accept_tid)?;
            let (stream, _) = listener.accept().context("stimulus: accept loopback TCP")?;
            accepted_tx
                .send((stream, accept_tid, accept_comm))
                .map_err(|_| anyhow::anyhow!("stimulus: accepted-stream receiver dropped"))?;
            Ok(())
        });

        let client_tid = linux_tid()?;
        let client_comm = task_comm(client_tid)?;
        let client = TcpStream::connect(listener_addr)
            .context("stimulus: complete loopback TCP client handshake")?;
        let client_addr = client
            .local_addr()
            .context("stimulus: read loopback client address")?;
        if client_addr.port() < EPHEMERAL_PORT_FLOOR {
            bail!(
                "stimulus: client port {} is outside the service-gate model; expected >= {EPHEMERAL_PORT_FLOOR}",
                client_addr.port()
            );
        }
        let (accepted, accept_tid, accept_comm) = accepted_rx
            .recv_timeout(EVENT_WAIT)
            .context("stimulus: wait for accepted loopback socket")?;
        server
            .join()
            .map_err(|_| anyhow::anyhow!("stimulus: accept thread panicked"))??;

        let expected_tgid = std::process::id();
        let expected_uid = effective_uid()?;
        let deadline = Instant::now() + EVENT_WAIT;
        let mut observed = Vec::new();
        let mut client_event = None;
        let mut server_event = None;

        while Instant::now() < deadline && (client_event.is_none() || server_event.is_none()) {
            match event_rx.try_recv() {
                Ok(event) => {
                    if event.transport_protocol == "tcp" {
                        observed.push(event_summary(&event));
                    }
                    if owner_resolved(
                        &event,
                        client_tid,
                        expected_tgid,
                        expected_uid,
                        &client_comm,
                    ) && event.local_ip == Ipv4Addr::LOCALHOST.to_string()
                        && event.remote_ip == Ipv4Addr::LOCALHOST.to_string()
                        && event.local_port == u32::from(client_addr.port())
                        && event.remote_port == u32::from(listener_addr.port())
                    {
                        client_event = Some(Arc::clone(&event));
                    }
                    if owner_resolved(
                        &event,
                        accept_tid,
                        expected_tgid,
                        expected_uid,
                        &accept_comm,
                    ) && event.event_kind == TCP_ACCEPT_EVENT
                        && event.local_ip == Ipv4Addr::LOCALHOST.to_string()
                        && event.remote_ip == Ipv4Addr::LOCALHOST.to_string()
                        && event.local_port == u32::from(listener_addr.port())
                        && event.remote_port == u32::from(client_addr.port())
                    {
                        server_event = Some(event);
                    }
                }
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    bail!("agent handoff: production event queue disconnected")
                }
            }
        }

        let Some(client_event) = client_event else {
            bail!(
                "kernel-to-ring/tuple/owner/event boundary: no owner-resolved outbound TCP event for 127.0.0.1:{} -> 127.0.0.1:{}; observed TCP events: {observed:?}",
                client_addr.port(),
                listener_addr.port()
            );
        };
        let Some(server_event) = server_event else {
            bail!(
                "kernel-to-ring/tuple/owner/event boundary: no owner-resolved accepted TCP event for 127.0.0.1:{} <- 127.0.0.1:{}; observed TCP events: {observed:?}",
                listener_addr.port(),
                client_addr.port()
            );
        };
        let server_gate_key = attribution_gate_key(&server_event)?;
        let server_socket_address = server_event.socket_address;
        assert_map_owner(
            &flow_to_pid,
            &server_gate_key,
            accept_tid,
            expected_tgid,
            "controlled flow gate before close",
        )?;
        assert_socket_owner(
            &socket_to_pid,
            server_socket_address,
            accept_tid,
            expected_tgid,
            "accepted socket before close",
        )?;

        let close_count_before = tcp_close_count(&metrics)?;
        drop(client);
        drop(accepted);

        let close_deadline = Instant::now() + EVENT_WAIT;
        while Instant::now() < close_deadline
            && (tcp_close_count(&metrics)? <= close_count_before
                || map_contains(&flow_to_pid, &server_gate_key)?
                || map_contains(&socket_to_pid, &server_socket_address)?)
        {
            thread::sleep(Duration::from_millis(10));
        }
        if tcp_close_count(&metrics)? <= close_count_before {
            bail!(
                "close handling: the controlled tuple did not advance the TCP close outcome from baseline {close_count_before}"
            );
        }
        if map_contains(&flow_to_pid, &server_gate_key)? {
            bail!("close handling: controlled accepted tuple retained its flow gate after close");
        }
        if map_contains(&socket_to_pid, &server_socket_address)? {
            bail!("close handling: controlled accepted socket retained its owner after close");
        }

        prove_service_gate_eviction_and_reuse(&flow_to_pid, expected_tgid, &mut event_rx)?;

        drop(runtime);
        drop(flow_to_pid);
        drop(socket_to_pid);
        drop(ebpf);
        pin_directory.cleanup()?;

        if client_event.local_port != u32::from(client_addr.port()) {
            bail!("internal test error: captured client event changed after selection");
        }

        eprintln!("loaded-object TCP attribution used {layout:?}");

        Ok(())
    }

    fn owner_resolved(
        event: &FlowAttributionEvent,
        expected_tid: u32,
        expected_tgid: u32,
        expected_uid: u32,
        expected_comm: &str,
    ) -> bool {
        event.transport_protocol == "tcp"
            && event.local_port != 0
            && event.remote_port != 0
            && event.pid == expected_tid
            && event.tgid == expected_tgid
            && event.uid == expected_uid
            && event.comm == expected_comm
    }

    fn event_summary(event: &FlowAttributionEvent) -> String {
        format!(
            "kind={} {}:{} -> {}:{} pid={} tgid={} uid={} comm={}",
            event.event_kind,
            event.local_ip,
            event.local_port,
            event.remote_ip,
            event.remote_port,
            event.pid,
            event.tgid,
            event.uid,
            event.comm
        )
    }

    fn effective_uid() -> Result<u32> {
        let status = fs::read_to_string("/proc/self/status")
            .context("owner resolution: read /proc/self/status")?;
        status
            .lines()
            .find_map(|line| line.strip_prefix("Uid:"))
            .and_then(|values| values.split_whitespace().nth(1))
            .and_then(|value| value.parse().ok())
            .context("owner resolution: parse effective uid from /proc/self/status")
    }

    fn linux_tid() -> Result<u32> {
        // SAFETY: gettid takes no pointer arguments and has no memory-safety
        // preconditions. The positive kernel TID fits in u32 on Linux.
        let tid = unsafe { nix::libc::syscall(nix::libc::SYS_gettid) };
        u32::try_from(tid).context("owner resolution: gettid returned an invalid value")
    }

    fn task_comm(tid: u32) -> Result<String> {
        let path = format!("/proc/self/task/{tid}/comm");
        let comm = fs::read_to_string(&path)
            .with_context(|| format!("owner resolution: read expected task comm from {path}"))?;
        let comm = comm.trim_end_matches(['\r', '\n']).to_string();
        if comm.is_empty() {
            bail!("owner resolution: expected task comm from {path} was empty");
        }
        Ok(comm)
    }

    struct BpffsPinDirectory {
        path: PathBuf,
        cleaned: bool,
    }

    impl BpffsPinDirectory {
        fn create() -> Result<Self> {
            let root = Path::new("/sys/fs/bpf");
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .context("map isolation: system clock predates Unix epoch")?
                .as_nanos();
            let tid = linux_tid()?;
            for attempt in 0..32 {
                let path = root.join(format!(
                    "serviceradar-netprobe-loaded-test-{}-{tid}-{nonce}-{attempt}",
                    std::process::id()
                ));
                match fs::create_dir(&path) {
                    Ok(()) => {
                        return Ok(Self {
                            path,
                            cleaned: false,
                        });
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!(
                                "map isolation: create unique bpffs pin directory {}",
                                path.display()
                            )
                        });
                    }
                }
            }
            bail!("map isolation: could not allocate a unique bpffs pin directory")
        }

        fn path(&self) -> &Path {
            &self.path
        }

        fn cleanup(mut self) -> Result<()> {
            fs::remove_dir_all(&self.path).with_context(|| {
                format!(
                    "map isolation: remove test bpffs pin directory {}",
                    self.path.display()
                )
            })?;
            self.cleaned = true;
            Ok(())
        }
    }

    impl Drop for BpffsPinDirectory {
        fn drop(&mut self) {
            if !self.cleaned
                && let Err(error) = fs::remove_dir_all(&self.path)
            {
                eprintln!(
                    "map isolation cleanup failed for {}: {error}",
                    self.path.display()
                );
            }
        }
    }

    fn bind_test_listener() -> Result<TcpListener> {
        for port in TEST_PORT_START..=TEST_PORT_END {
            match TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)) {
                Ok(listener) => return Ok(listener),
                Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => continue,
                Err(error) => return Err(error).context("stimulus: bind loopback listener"),
            }
        }
        bail!("stimulus: no loopback test port available in {TEST_PORT_START}..={TEST_PORT_END}")
    }

    fn bind_service_test_listener() -> Result<TcpListener> {
        for port in SERVICE_TEST_PORT_START..=SERVICE_TEST_PORT_END {
            match TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)) {
                Ok(listener) => return Ok(listener),
                Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => continue,
                Err(error) => return Err(error).context("service reuse: bind loopback listener"),
            }
        }
        bail!(
            "service reuse: no loopback test port available in {SERVICE_TEST_PORT_START}..={SERVICE_TEST_PORT_END}"
        )
    }

    fn prove_service_gate_eviction_and_reuse(
        flow_to_pid: &AyaHashMap<aya::maps::MapData, FlowKey, FlowPidRecord>,
        expected_tgid: u32,
        event_rx: &mut event_queue::EventReceiver<Arc<FlowAttributionEvent>>,
    ) -> Result<()> {
        let listener = bind_service_test_listener()?;
        let listener_addr = listener
            .local_addr()
            .context("service reuse: read listener address")?;
        let (accepted_tx, accepted_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || -> Result<()> {
            let accept_tid = linux_tid()?;
            for attempt in 1..=2 {
                let (stream, peer_addr) = listener
                    .accept()
                    .with_context(|| format!("service reuse: accept attempt {attempt}"))?;
                accepted_tx
                    .send((stream, peer_addr, accept_tid))
                    .map_err(|_| {
                        anyhow::anyhow!("service reuse: accepted-stream receiver dropped")
                    })?;
            }
            Ok(())
        });

        let first_client = TcpStream::connect(listener_addr)
            .context("service reuse: first loopback TCP handshake")?;
        let first_client_addr = first_client
            .local_addr()
            .context("service reuse: first client address")?;
        if first_client_addr.port() < EPHEMERAL_PORT_FLOOR {
            bail!(
                "service reuse: first client port {} is below the service-gate floor {EPHEMERAL_PORT_FLOOR}",
                first_client_addr.port()
            );
        }
        let (first_accepted, first_peer_addr, accept_tid) = accepted_rx
            .recv_timeout(EVENT_WAIT)
            .context("service reuse: wait for first accepted socket")?;
        if first_peer_addr != first_client_addr {
            bail!(
                "service reuse: accepted peer {first_peer_addr} did not match client {first_client_addr}"
            );
        }
        let service_gate = attribution_gate_key_for_tuple(listener_addr, first_client_addr)?;
        wait_for_map_owner(
            flow_to_pid,
            &service_gate,
            accept_tid,
            expected_tgid,
            "service gate after first accept",
        )?;

        drop(first_client);
        drop(first_accepted);
        wait_for_map_absence(flow_to_pid, &service_gate, "service gate after first close")?;

        let second_client = TcpStream::connect(listener_addr)
            .context("service reuse: second loopback TCP handshake")?;
        let second_client_addr = second_client
            .local_addr()
            .context("service reuse: second client address")?;
        if second_client_addr.port() < EPHEMERAL_PORT_FLOOR {
            bail!(
                "service reuse: second client port {} is below the service-gate floor {EPHEMERAL_PORT_FLOOR}",
                second_client_addr.port()
            );
        }
        let (second_accepted, second_peer_addr, second_accept_tid) = accepted_rx
            .recv_timeout(EVENT_WAIT)
            .context("service reuse: wait for second accepted socket")?;
        if second_peer_addr != second_client_addr || second_accept_tid != accept_tid {
            bail!("service reuse: second accept did not run in the controlled accept thread");
        }
        let reused_gate = attribution_gate_key_for_tuple(listener_addr, second_client_addr)?;
        if reused_gate != service_gate {
            bail!("service reuse: service-coalesced gate changed across peer-port reuse");
        }
        wait_for_map_owner(
            flow_to_pid,
            &reused_gate,
            accept_tid,
            expected_tgid,
            "service gate after second accept",
        )?;

        drop(second_client);
        drop(second_accepted);
        server
            .join()
            .map_err(|_| anyhow::anyhow!("service reuse: accept thread panicked"))??;
        wait_for_map_absence(
            flow_to_pid,
            &service_gate,
            "service gate after second close",
        )?;

        // Discard the service-reuse events so this helper cannot leave the
        // bounded receiver full while waiting for close cleanup.
        while event_rx.try_recv().is_ok() {}
        Ok(())
    }

    fn attribution_gate_key(event: &FlowAttributionEvent) -> Result<FlowKey> {
        let local_ip: IpAddr = event.local_ip.parse().context("close handling: local IP")?;
        let remote_ip: IpAddr = event
            .remote_ip
            .parse()
            .context("close handling: remote IP")?;
        let local_port = u16::try_from(event.local_port).context("close handling: local port")?;
        let remote_port =
            u16::try_from(event.remote_port).context("close handling: remote port")?;
        attribution_gate_key_for_tuple(
            (local_ip, local_port).into(),
            (remote_ip, remote_port).into(),
        )
    }

    fn attribution_gate_key_for_tuple(
        local: std::net::SocketAddr,
        remote: std::net::SocketAddr,
    ) -> Result<FlowKey> {
        let local_port = local.port();
        let remote_port = remote.port();
        let mut key = canonical_flow_key(local.ip(), remote.ip(), local_port, remote_port, 6)
            .context("close handling: canonicalize accepted tuple")?;
        if local_port < EPHEMERAL_PORT_FLOOR && remote_port >= EPHEMERAL_PORT_FLOOR {
            if key.endpoint_a_port == remote_port {
                key.endpoint_a_port = 0;
                key.endpoint_a_addr = [0; 16];
            } else if key.endpoint_b_port == remote_port {
                key.endpoint_b_port = 0;
                key.endpoint_b_addr = [0; 16];
            } else {
                bail!("close handling: remote endpoint missing from canonical key")
            }
        }
        Ok(key)
    }

    fn wait_for_map_owner(
        map: &AyaHashMap<aya::maps::MapData, FlowKey, FlowPidRecord>,
        key: &FlowKey,
        expected_tid: u32,
        expected_tgid: u32,
        stage: &str,
    ) -> Result<()> {
        let deadline = Instant::now() + EVENT_WAIT;
        while Instant::now() < deadline {
            match map.get(key, 0) {
                Ok(owner) if owner.pid == expected_tid && owner.tgid == expected_tgid => {
                    return Ok(());
                }
                Ok(_) | Err(aya::maps::MapError::KeyNotFound) => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("close handling: inspect {stage} while waiting for owner")
                    });
                }
            }
        }
        assert_map_owner(map, key, expected_tid, expected_tgid, stage)
    }

    fn wait_for_map_absence(
        map: &AyaHashMap<aya::maps::MapData, FlowKey, FlowPidRecord>,
        key: &FlowKey,
        stage: &str,
    ) -> Result<()> {
        let deadline = Instant::now() + EVENT_WAIT;
        while Instant::now() < deadline && map_contains(map, key)? {
            thread::sleep(Duration::from_millis(10));
        }
        if map_contains(map, key)? {
            bail!("close handling: {stage} remained present")
        }
        Ok(())
    }

    fn assert_map_owner(
        map: &AyaHashMap<aya::maps::MapData, FlowKey, FlowPidRecord>,
        key: &FlowKey,
        expected_tid: u32,
        expected_tgid: u32,
        stage: &str,
    ) -> Result<()> {
        let owner = map
            .get(key, 0)
            .with_context(|| format!("close handling: {stage} was not present"))?;
        if owner.pid != expected_tid || owner.tgid != expected_tgid {
            bail!(
                "close handling: {stage} owner was pid/tgid {}/{}, expected {expected_tid}/{expected_tgid}",
                owner.pid,
                owner.tgid
            );
        }
        Ok(())
    }

    fn assert_socket_owner(
        map: &AyaHashMap<aya::maps::MapData, u64, FlowPidRecord>,
        socket_address: u64,
        expected_tid: u32,
        expected_tgid: u32,
        stage: &str,
    ) -> Result<()> {
        let owner = map
            .get(&socket_address, 0)
            .with_context(|| format!("close handling: {stage} was not present"))?;
        if owner.pid != expected_tid || owner.tgid != expected_tgid {
            bail!(
                "close handling: {stage} owner was pid/tgid {}/{}, expected {expected_tid}/{expected_tgid}",
                owner.pid,
                owner.tgid
            );
        }
        Ok(())
    }

    fn map_contains<K: aya::Pod, V: aya::Pod>(
        map: &AyaHashMap<aya::maps::MapData, K, V>,
        key: &K,
    ) -> Result<bool> {
        match map.get(key, 0) {
            Ok(_) => Ok(true),
            Err(aya::maps::MapError::KeyNotFound) => Ok(false),
            Err(error) => Err(error).context("close handling: inspect eBPF owner map"),
        }
    }

    fn require_capability(bit: u32, name: &str) -> Result<()> {
        let status = fs::read_to_string("/proc/self/status")
            .context("attach/readiness: read /proc/self/status capabilities")?;
        let effective = status
            .lines()
            .find_map(|line| line.strip_prefix("CapEff:"))
            .map(str::trim)
            .and_then(|value| u64::from_str_radix(value, 16).ok())
            .context("attach/readiness: parse CapEff from /proc/self/status")?;
        if effective & (1_u64 << bit) == 0 {
            bail!(
                "attach/readiness prerequisite: {name} is required (CapEff bit {bit}); run //rust/netprobe:loaded_tcp_attribution_test on the designated privileged Linux worker"
            );
        }
        Ok(())
    }

    fn tcp_close_count(metrics: &Metrics) -> Result<u64> {
        let families = metrics.registry().gather();
        let mut encoded = Vec::new();
        TextEncoder::new()
            .encode(&families, &mut encoded)
            .context("close handling: encode attribution metrics")?;
        let text = String::from_utf8(encoded).context("close handling: metrics were not UTF-8")?;

        text.lines()
            .filter(|line| {
                line.starts_with("serviceradar_netprobe_attribution_records_total{")
                    && line.contains("event_kind=\"tcp_close\"")
                    && line.contains("protocol=\"tcp\"")
                    && line.contains("outcome=\"close\"")
            })
            .map(|line| {
                line.rsplit_once(' ')
                    .context("close handling: malformed close counter")?
                    .1
                    .parse::<u64>()
                    .context("close handling: parse close counter")
            })
            .try_fold(0_u64, |total, value| {
                value.map(|value| total.saturating_add(value))
            })
    }
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
