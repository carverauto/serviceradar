use std;
use std::fs::File;
use std::io::prelude::*;
use std::io::stderr;
use std::io::{BufReader, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, SyncSender};
use std::time::Duration;

use notify::{watcher, RecursiveMode, Watcher};

use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;

pub struct FileWorker {
    path: PathBuf,
    tx: SyncSender<Vec<u8>>,
    decoder: Box<dyn Decoder + Send>,
    encoder: Box<dyn Encoder + Send>,
}

impl FileWorker {
    pub fn new(
        path: &Path,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    ) -> FileWorker {
        FileWorker {
            path: PathBuf::from(path),
            tx,
            decoder,
            encoder,
        }
    }

    pub fn run(&mut self, from_tail: bool) {
        let (tx, rx) = channel();
        let mut watcher = watcher(tx, Duration::from_secs(2)).expect("Cannot create file watcher");
        watcher
            .watch(&self.path, RecursiveMode::NonRecursive)
            .unwrap();

        let fr = FollowReader::new(&self.path, from_tail);
        let mut reader = BufReader::new(fr);
        let mut buffer = Vec::new();

        let (decoder, encoder): (Box<dyn Decoder>, Box<dyn Encoder>) =
            (self.decoder.clone_boxed(), self.encoder.clone_boxed());
        let mut finish = false;
        while !finish {
            match rx.recv() {
                Ok(_) => loop {
                    let r = reader.read_until(10, &mut buffer);
                    match r {
                        Ok(bytes_read) => {
                            if bytes_read == 0 {
                                break;
                            }
                        }
                        Err(_) => {
                            finish = true;
                            break;
                        }
                    }
                    if buffer[buffer.len() - 1] == 10 {
                        buffer.pop();
                        let line = String::from_utf8(buffer.clone()).unwrap();
                        buffer.truncate(0);
                        if let Err(e) = handle_record(&line, &self.tx, &decoder, &encoder) {
                            let _ = writeln!(stderr(), "{}: [{}]", e, line.trim());
                        }
                    }
                },
                Err(_) => {}
            }
        }
    }
}

pub struct FollowReader {
    file: File,
    path: PathBuf,
}

impl FollowReader {
    pub fn new(filename: &Path, from_tail: bool) -> FollowReader {
        let mut f = File::open(filename).expect("Failed to open file");
        if from_tail {
            f.seek(SeekFrom::End(0)).unwrap();
        }
        FollowReader {
            file: f,
            path: PathBuf::from(filename),
        }
    }
}

impl Read for FollowReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.path.exists() {
            self.file.sync_data().unwrap();
            self.file.read(buf)
        } else {
            Err(std::io::Error::new(std::io::ErrorKind::Other, ""))
        }
    }
}

fn handle_record(
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
