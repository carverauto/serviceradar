mod discovery;
mod worker;
use self::discovery::FileDiscovery;

use std::sync::mpsc::SyncSender;

use super::Input;
use crate::flowgger::config::Config;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;

#[derive(Clone)]
pub struct FileConfig {
    src: String,
}

pub struct FileInput {
    file_config: FileConfig,
}

impl FileInput {
    pub fn new(config: &Config) -> FileInput {
        let src_path = match config.lookup("input.src") {
            None => panic!("Missing file path"),
            Some(src) => src.as_str().expect("OK").to_owned(),
        };
        let file_config = FileConfig { src: src_path };
        FileInput { file_config }
    }
}

impl Input for FileInput {
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    ) {
        let mut discovery = FileDiscovery::new(&self.file_config.src, tx, decoder, encoder);
        discovery.run();
    }
}
