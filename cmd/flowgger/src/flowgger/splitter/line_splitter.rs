use super::Splitter;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use std::io::{stderr, BufRead, BufReader, ErrorKind, Read, Write};
use std::sync::mpsc::SyncSender;

pub struct LineSplitter;

impl<T: Read> Splitter<T> for LineSplitter {
    fn run(
        &self,
        buf_reader: BufReader<T>,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder>,
        encoder: Box<dyn Encoder>,
    ) {
        for line in buf_reader.lines() {
            let line = match line {
                Ok(line) => line,
                Err(e) => match e.kind() {
                    ErrorKind::Interrupted => continue,
                    ErrorKind::InvalidInput | ErrorKind::InvalidData => {
                        let _ = writeln!(stderr(), "Invalid UTF-8 input");
                        continue;
                    }
                    ErrorKind::WouldBlock => {
                        let _ = writeln!(
                            stderr(),
                            "Client hasn't sent any data for a while - Closing \
                             idle connection"
                        );
                        return;
                    }
                    _ => return,
                },
            };
            if let Err(e) = handle_line(&line, &tx, &decoder, &encoder) {
                let _ = writeln!(stderr(), "{}: [{}]", e, line.trim());
            }
        }
    }
}

fn handle_line(
    line: &str,
    tx: &SyncSender<Vec<u8>>,
    decoder: &Box<dyn Decoder>,
    encoder: &Box<dyn Encoder>,
) -> Result<(), &'static str> {
    let decoded = decoder.decode(line)?;
    let reencoded = encoder.encode(decoded)?;
    tx.send(reencoded).unwrap();
    Ok(())
}
