//! This module contains functions to calculate the digest of a file.
//!
//! The digest is calculated using the SHA256 algorithm.

use crate::oneio::get_reader_raw;
use crate::OneIoError;
use ring::digest::{Context, SHA256};

/// Calculate the SHA256 digest of a file.
///
/// This function takes a path to a file as input and returns the SHA256 digest of the file
/// as a hexadecimal string.
///
/// # Arguments
///
/// * `Path` - A string slice that holds the path to the file.
///
/// # Errors
///
/// This function can return an error of type `OneIoError` if there is an issue while reading the file.
/// The error can occur if the file doesn't exist, if there are permission issues, or if there are
/// issues with the underlying I/O operations.
pub fn get_sha256_digest(path: &str) -> Result<String, OneIoError> {
    let mut context = Context::new(&SHA256);
    let mut buffer = [0; 1024];

    let mut reader = get_reader_raw(path)?;
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        context.update(&buffer[..count]);
    }

    let digest = context.finish();

    Ok(hex::encode(digest.as_ref()))
}
