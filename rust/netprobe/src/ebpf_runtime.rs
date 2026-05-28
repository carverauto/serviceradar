use anyhow::{Context, Result};
use aya::{
    maps::HashMap as AyaHashMap,
    programs::{tc, SchedClassifier, TcAttachType},
    Ebpf,
};
use tokio::sync::broadcast;

use std::{io, path::Path, sync::Arc};

use crate::{
    af_xdp::{self, DEFAULT_REDIRECT_BUDGET},
    af_xdp_classifier::AfXdpClassifierRuntime,
    config::Config,
    ebpf_loader::load_netprobe_ebpf,
    metrics::Metrics,
    proto::netprobe::DpiEvent,
    runtime_config::DpiEventGate,
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

pub struct NetprobeEbpfRuntime {
    _classifier_runtime: AfXdpClassifierRuntime,
    _interface_allowlist: AyaHashMap<aya::maps::MapData, u32, InterfaceConfig>,
    _ebpf: Ebpf,
}

impl NetprobeEbpfRuntime {
    pub fn start(
        object_path: &Path,
        config: &Config,
        metrics: Metrics,
        dpi_events: broadcast::Sender<DpiEvent>,
        dpi_gate: Arc<DpiEventGate>,
    ) -> Result<Self> {
        let interfaces = af_xdp::resolve_interfaces(&config.capture_interfaces)
            .context("failed to resolve AF_XDP capture interfaces")?;
        let mut ebpf = load_netprobe_ebpf(object_path, config)?;
        let interface_allowlist = populate_interface_allowlist(&mut ebpf, &interfaces)?;
        let classifier_runtime = AfXdpClassifierRuntime::start_from_ebpf(
            &config.capture_interfaces,
            &mut ebpf,
            metrics,
            dpi_events,
            dpi_gate,
        )?;
        attach_tc_programs(&mut ebpf, &config.capture_interfaces)?;

        Ok(Self {
            _classifier_runtime: classifier_runtime,
            _interface_allowlist: interface_allowlist,
            _ebpf: ebpf,
        })
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
