use std::io;

fn main() {
    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();

    if let Err(err) = serviceradar_rdp_adapter::run_stdio(&mut stdin, &mut stdout) {
        eprintln!("{err}");
        std::process::exit(1);
    }
}
