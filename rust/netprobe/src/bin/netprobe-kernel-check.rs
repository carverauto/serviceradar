use anyhow::Result;
use clap::Parser;
use serviceradar_netprobe::kernel::{MIN_KERNEL_MAJOR, MIN_KERNEL_MINOR, current_kernel_version};

#[derive(Debug, Parser)]
#[command(
    author,
    version,
    about = "Report netprobe host-network-visibility kernel support"
)]
struct Args {
    /// Fail unless host-network-visibility is unavailable.
    #[arg(long)]
    expect_unavailable: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let version = current_kernel_version()?;
    let supported = version.supports_ebpf_capture();
    let state = if supported {
        "available"
    } else {
        "unavailable"
    };

    println!(
        "host-network-visibility={state} kernel_release={} minimum={}.{}",
        version.release, MIN_KERNEL_MAJOR, MIN_KERNEL_MINOR
    );
    if !supported {
        println!("reason=kernel_too_old");
    }
    if args.expect_unavailable && supported {
        anyhow::bail!(
            "expected unavailable on kernel {}, but host-network-visibility is available",
            version.release
        );
    }

    Ok(())
}
