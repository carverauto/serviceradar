#![allow(dead_code)]

/// compress-escaped is a utility program that accepts a single command line
/// parameter, compresses it and prints it to stdout after escaping it.

extern crate snap;

use std::env;
use std::io::{self, Write};
use std::process;

fn main() {
    let bytes = match env::args().nth(1) {
        None => {
            writeln!(
                &mut io::stderr(), "Usage: compress-escaped string").unwrap();
            process::exit(1);
        }
        Some(arg) => arg.into_bytes(),
    };
    let compressed = frame_press(&bytes);
    println!("{}", escape(&compressed));
    println!("{}", escape(&frame_depress(&compressed)));
}

fn press(bytes: &[u8]) -> Vec<u8> {
    use snap::Encoder;
    Encoder::new().compress_vec(bytes).unwrap()
}

fn frame_press(bytes: &[u8]) -> Vec<u8> {
    use std::io::Write;
    use snap::Writer;

    let mut wtr = Writer::new(vec![]);
    wtr.write_all(bytes).unwrap();
    wtr.into_inner().unwrap()
}

fn frame_depress(bytes: &[u8]) -> Vec<u8> {
    use std::io::Read;
    use snap::Reader;

    let mut buf = vec![];
    Reader::new(bytes).read_to_end(&mut buf).unwrap();
    buf
}

fn escape(bytes: &[u8]) -> String {
    use std::ascii::escape_default;
    bytes.iter().flat_map(|&b| escape_default(b)).map(|b| b as char).collect()
}
