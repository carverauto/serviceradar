use anyhow::{Context, Result};
use aya::{
    maps::{HashMap as AyaHashMap, ProgramArray},
    programs::{tc, SchedClassifier, TcAttachType, Xdp, XdpFlags},
    Ebpf,
};
use nix::libc;
use tokio::sync::broadcast;

use std::{
    collections::VecDeque,
    io,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use crate::{
    af_xdp::{self, DEFAULT_REDIRECT_BUDGET},
    af_xdp_classifier::AfXdpClassifierRuntime,
    attribution::{AyaAttributionReader, FlowAttributionRuntime},
    config::Config,
    ebpf_loader::load_netprobe_ebpf,
    event_queue::EventSender,
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
    _classifier_runtime: AfXdpClassifierRuntime,
    _p0f_runtime: P0fSignatureRuntime,
    _attribution_runtime: FlowAttributionRuntime,
    _sampling_runtime: AdaptiveSamplingRuntime,
    _ebpf: Ebpf,
}

impl NetprobeEbpfRuntime {
    pub fn start(
        object_path: &Path,
        config: &Config,
        metrics: Metrics,
        fingerprint_events: EventSender<FingerprintEvent>,
        dpi_events: EventSender<DpiEvent>,
        flow_attribution_events: broadcast::Sender<FlowAttributionEvent>,
        process_snapshots: broadcast::Sender<ProcessSnapshot>,
        fingerprint_gate: Arc<std::sync::Mutex<FingerprintEventGate>>,
        dpi_gate: Arc<DpiEventGate>,
    ) -> Result<Self> {
        let kernel = ensure_supported_kernel()?;
        log::info!(
            "netprobe eBPF capture kernel check passed: {}",
            kernel.release
        );
        let interfaces = af_xdp::resolve_interfaces(&config.capture_interfaces)
            .context("failed to resolve AF_XDP capture interfaces")?;
        let mut ebpf = load_netprobe_ebpf(object_path, config)?;
        let fingerprint_accumulator = FingerprintAccumulator::default();
        let p0f_runtime = P0fSignatureRuntime::start_from_ebpf(
            fingerprint_interface_name(config),
            &mut ebpf,
            fingerprint_events,
            fingerprint_gate,
            fingerprint_accumulator.clone(),
            metrics.clone(),
        )?;
        let attribution_reader = AyaAttributionReader::from_ebpf(&mut ebpf)?;
        let attribution_runtime = FlowAttributionRuntime::start(
            attribution_reader,
            flow_attribution_events,
            process_snapshots,
            metrics.clone(),
            process_snapshot_interval(config),
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
        // an XSKMAP). Attach after the classifier runtime has registered one XSK
        // per rx queue, so the redirect has live socket targets.
        attach_xdp_program(&mut ebpf, &config.capture_interfaces)?;

        Ok(Self {
            _classifier_runtime: classifier_runtime,
            _p0f_runtime: p0f_runtime,
            _attribution_runtime: attribution_runtime,
            _sampling_runtime: sampling_runtime,
            _ebpf: ebpf,
        })
    }
}

fn process_snapshot_interval(config: &Config) -> Option<Duration> {
    (config.process_snapshot_interval_s > 0)
        .then(|| Duration::from_secs(config.process_snapshot_interval_s))
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
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                log::warn!("AF_XDP adaptive sampling thread panicked during shutdown");
            }
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
    if value > 0 {
        value as f64
    } else {
        100.0
    }
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

fn attach_xdp_program(ebpf: &mut Ebpf, interfaces: &[String]) -> Result<()> {
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
