//! Bzip2 compression support for OneIO.
//!
//! This module provides bzip2 compression support for OneIO.

use crate::OneIoError;
use bzip2::read::BzDecoder;
use bzip2::write::BzEncoder;
use bzip2::Compression;
use std::fs::File;
use std::io::{BufWriter, Read, Write};

/// Returns a reader that decompresses bzip2-compressed data from the given reader.
///
/// # Arguments
/// * `raw_reader` - A boxed reader containing bzip2-compressed data.
///
/// # Returns
/// * `Ok(Box<dyn Read + Send>)` - A reader that decompresses bzip2 data on the fly.
/// * `Err(OneIoError)` - If the bzip2 decoder could not be created.
pub(crate) fn get_reader(
    raw_reader: Box<dyn Read + Send>,
) -> Result<Box<dyn Read + Send>, OneIoError> {
    Ok(Box::new(BzDecoder::new(raw_reader)))
}

/// Returns a writer that compresses data to bzip2 format.
///
/// # Arguments
/// * `raw_writer` - A buffered writer for the target file.
///
/// # Returns
/// * `Ok(Box<dyn Write>)` - A writer that compresses data to bzip2 format.
/// * `Err(OneIoError)` - If the bzip2 encoder could not be created.
pub(crate) fn get_writer(raw_writer: BufWriter<File>) -> Result<Box<dyn Write>, OneIoError> {
    Ok(Box::new(BzEncoder::new(raw_writer, Compression::default())))
}
