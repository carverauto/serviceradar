use super::Output;
use crate::flowgger::config::Config;
use crate::flowgger::merger::Merger;
use std::io::{stdout, Write};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread;

pub struct DebugOutput;

impl DebugOutput {
    pub fn new(_config: &Config) -> DebugOutput {
        DebugOutput
    }
}

impl Output for DebugOutput {
    fn start(&self, arx: Arc<Mutex<Receiver<Vec<u8>>>>, merger: Option<Box<dyn Merger>>) {
        let merger = merger.map(|merger| merger.clone_boxed());
        thread::spawn(move || loop {
            let mut bytes = match arx.lock().unwrap().recv() {
                Ok(line) => line,
                Err(_) => return,
            };
            if let Some(ref merger) = merger {
                merger.frame(&mut bytes);
            }
            let out = String::from_utf8_lossy(&bytes);
            print!("{out}");
            let _ = stdout().flush();
        });
    }
}
