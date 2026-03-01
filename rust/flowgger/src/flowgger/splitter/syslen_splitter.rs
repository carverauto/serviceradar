use super::Splitter;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use std::io::{stderr, BufRead, BufReader, Read, Write};
use std::str;
use std::sync::mpsc::SyncSender;

pub struct SyslenSplitter;

impl<T: Read> Splitter<T> for SyslenSplitter {
    fn run(
        &self,
        buf_reader: BufReader<T>,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder>,
        encoder: Box<dyn Encoder>,
    ) {
        let mut buf_reader = buf_reader;
        loop {
            let size = match read_msglen(&mut buf_reader) {
                Ok(size) => size,
                Err(_) => {
                    let _ = writeln!(stderr(), "Can't read message's length");
                    return;
                }
            };
            let mut buffer = vec![0; size];
            if let Err(e) = buf_reader.read_exact(&mut buffer) {
                let _ = writeln!(stderr(), "{e}");
                return;
            }

            let buffer = String::from_utf8(buffer).unwrap();

            if let Err(e) = handle_line(&buffer, &tx, decoder.as_ref(), encoder.as_ref()) {
                let _ = writeln!(stderr(), "{}: [{}]", e, buffer.trim());
            }
        }
    }
}

fn read_msglen(reader: &mut dyn BufRead) -> Result<usize, &'static str> {
    let mut nbytes_v = Vec::with_capacity(16);
    let nbytes_vl = match reader.read_until(b' ', &mut nbytes_v) {
        Err(_) | Ok(0) | Ok(1) => return Err("Connection closed"),
        Ok(nbytes_vl) => nbytes_vl,
    };
    let nbytes_s = match str::from_utf8(&nbytes_v[..nbytes_vl - 1]) {
        Err(_) => return Err("Invalid or missing message length. Disable framing, maybe?"),
        Ok(nbytes_s) => nbytes_s,
    };
    let nbytes: usize = match nbytes_s.parse() {
        Err(_) => return Err("Invalid message length. Disable framing, maybe?"),
        Ok(nbytes) => nbytes,
    };
    Ok(nbytes)
}

fn handle_line(
    line: &str,
    tx: &SyncSender<Vec<u8>>,
    decoder: &dyn Decoder,
    encoder: &dyn Encoder,
) -> Result<(), &'static str> {
    let decoded = decoder.decode(line)?;
    let reencoded = encoder.encode(decoded)?;
    tx.send(reencoded).unwrap();
    Ok(())
}
