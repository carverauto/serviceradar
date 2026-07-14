//! Gzip compression support for OneIO.
//!
//! This module provides gzip compression support for OneIO.

use crate::OneIoError;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use std::fs::File;
use std::io::{BufWriter, Read, Write};

/// Returns a reader that decompresses gzip-compressed data from the given reader.
///
/// # Arguments
/// * `raw_reader` - A boxed reader containing gzip-compressed data.
///
/// # Returns
/// * `Ok(Box<dyn Read + Send>)` - A reader that decompresses gzip data on the fly.
/// * `Err(OneIoError)` - If the gzip decoder could not be created.
pub(crate) fn get_reader(
    raw_reader: Box<dyn Read + Send>,
) -> Result<Box<dyn Read + Send>, OneIoError> {
    Ok(Box::new(GzDecoder::new(raw_reader)))
}

/// Returns a writer that compresses data to gzip format.
///
/// # Arguments
/// * `raw_writer` - A buffered writer for the target file.
///
/// # Returns
/// * `Ok(Box<dyn Write>)` - A writer that compresses data to gzip format.
/// * `Err(OneIoError)` - If the gzip encoder could not be created.
pub(crate) fn get_writer(raw_writer: BufWriter<File>) -> Result<Box<dyn Write>, OneIoError> {
    // see libflate docs on the reasons of using [AutoFinishUnchecked].
    let encoder = GzEncoder::new(raw_writer, Compression::default());
    Ok(Box::new(encoder))
}
