use std::env;
use std::io;

fn main() {
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

    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();

    if let Err(err) = serviceradar_rdp_adapter::run_stdio(&mut stdin, &mut stdout) {
        eprintln!("{err}");
        std::process::exit(1);
    }
}
