use super::Merger;
use crate::flowgger::config::Config;

#[derive(Clone)]
pub struct LineMerger;

impl LineMerger {
    pub fn new(_config: &Config) -> LineMerger {
        LineMerger
    }
}

impl Merger for LineMerger {
    fn frame(&self, bytes: &mut Vec<u8>) {
        bytes.push(0x0a);
    }
}
