use std::path::PathBuf;

#[cfg(target_os = "linux")]
use anyhow::Context;
use anyhow::Result;
use clap::Parser;

#[derive(Debug, Parser)]
#[command(
    author,
    version,
    about = "Load netprobe eBPF programs through the kernel verifier"
)]
struct Args {
    /// Path to the compiled netprobe eBPF object.
    object: PathBuf,

    /// Override the flow_table max_entries value used by the loader.
    #[arg(long, default_value_t = 65_536)]
    flow_table_max_entries: u32,

    /// Expected kernel family for CI lanes: 5.8, 5.15, or 6.x.
    #[arg(long)]
    expect_kernel: Option<String>,
}

#[cfg(target_os = "linux")]
fn main() -> Result<()> {
    use aya::programs::Program;
    use serviceradar_netprobe::{
        config::Config, ebpf_loader::load_netprobe_ebpf, kernel::current_kernel_version,
    };

    let args = Args::parse();
    if let Some(expected) = args.expect_kernel.as_deref() {
        let current = current_kernel_version()?;
        if !kernel_matches(expected, &current) {
            anyhow::bail!(
                "kernel verifier lane expected {expected}, current kernel is {}",
                current.release
            );
        }
    }

    let config = Config {
        flow_table_max_entries: args.flow_table_max_entries,
        ..Default::default()
    };
    let mut ebpf = load_netprobe_ebpf(&args.object, &config)?;
    let program_names = ebpf
        .programs()
        .map(|(name, _)| name.to_owned())
        .collect::<Vec<_>>();

    let mut loaded = Vec::with_capacity(program_names.len());
    for name in program_names {
        let program = ebpf
            .program_mut(&name)
            .with_context(|| format!("program {name} disappeared while verifying"))?;
        match program {
            Program::SchedClassifier(program) => {
                program
                    .load()
                    .with_context(|| format!("verifier rejected TC classifier {name}"))?;
            }
            Program::KProbe(program) => {
                program
                    .load()
                    .with_context(|| format!("verifier rejected kprobe/kretprobe {name}"))?;
            }
            Program::TracePoint(program) => {
                program
                    .load()
                    .with_context(|| format!("verifier rejected tracepoint {name}"))?;
            }
            Program::Xdp(program) => {
                program
                    .load()
                    .with_context(|| format!("verifier rejected XDP program {name}"))?;
            }
            other => {
                anyhow::bail!(
                    "unexpected program type for {name}: {:?}",
                    other.prog_type()
                );
            }
        }
        loaded.push(name);
    }

    loaded.sort();
    println!("verified {} netprobe eBPF program(s)", loaded.len());
    for name in loaded {
        println!("verified {name}");
    }

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() -> Result<()> {
    let _ = Args::parse();
    anyhow::bail!("netprobe eBPF verifier requires Linux")
}

#[cfg(target_os = "linux")]
fn kernel_matches(expected: &str, current: &serviceradar_netprobe::kernel::KernelVersion) -> bool {
    match expected {
        "5.8" => current.major == 5 && current.minor == 8,
        "5.15" => current.major == 5 && current.minor == 15,
        "6.x" => current.major == 6,
        _ => false,
    }
}
