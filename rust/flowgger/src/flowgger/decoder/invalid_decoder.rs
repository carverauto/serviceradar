use super::Decoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::Record;

#[derive(Clone)]
pub struct InvalidDecoder;

impl InvalidDecoder {
    pub fn new(_config: &Config) -> InvalidDecoder {
        InvalidDecoder
    }
}

impl Decoder for InvalidDecoder {
    fn decode(&self, _line: &str) -> Result<Record, &'static str> {
        panic!("Unsupported input format for this input type");
    }
}
