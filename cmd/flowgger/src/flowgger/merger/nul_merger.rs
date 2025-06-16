use super::Merger;
use crate::flowgger::config::Config;

#[derive(Clone)]
pub struct NulMerger;

impl NulMerger {
    pub fn new(_config: &Config) -> NulMerger {
        NulMerger
    }
}

impl Merger for NulMerger {
    fn frame(&self, bytes: &mut Vec<u8>) {
        bytes.push(0);
    }
}
