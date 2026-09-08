use std::env;
use std::io;

fn main() {
    if let Err(err) = serviceradar_rdp_adapter::harden_process_for_secrets() {
        eprintln!("failed to harden RDP helper process for secrets: {err}");
        std::process::exit(1);
    }

    let mut args = env::args().skip(1);
    if matches!(
        args.next().as_deref(),
        Some(serviceradar_rdp_adapter::HELPER_CAPABILITIES_ARG)
    ) {
        let mut stdout = io::stdout().lock();
        if let Err(err) = serviceradar_rdp_adapter::write_capabilities(&mut stdout) {
            eprintln!("{err}");
            std::process::exit(1);
        }

        return;
    }

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();

    if let Err(err) = serviceradar_rdp_adapter::run_stdio_pumped(stdin, &mut stdout) {
        eprintln!("{err}");
        std::process::exit(1);
    }
}
