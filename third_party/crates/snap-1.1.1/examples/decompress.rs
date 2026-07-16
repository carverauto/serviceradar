use snap;

use std::io;

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();

    // Wrap the stdin reader in a Snappy reader.
    let mut rdr = snap::read::FrameDecoder::new(stdin.lock());
    let mut wtr = stdout.lock();
    io::copy(&mut rdr, &mut wtr).expect("I/O operation failed");
}
