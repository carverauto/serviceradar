//! Utility functions for file reading and deserialization in OneIO.
//!
//! This module provides helper functions to read file contents as strings,
//! deserialize JSON files into Rust structs, and iterate over lines in files.
//! These utilities abstract over different file sources and formats,
//! simplifying common I/O operations for users of the OneIO crate.

use crate::{get_reader, OneIoError};
use std::io::{BufRead, BufReader, Lines, Read};

/// Reads the contents of a file to a string.
///
/// # Arguments
///
/// * `path` - A string slice that represents the path to the file.
///
/// # Returns
///
/// * `Result<String, OneIoError>` - A `Result` where the `Ok` variant contains
///   the contents of the file as a string if the file was successfully read, or
///   the `Err` variant contains a `OneIoError` if an I/O error occurred.
///
/// # Examples
///
/// ```rust,no_run
/// use std::fs::File;
/// use oneio::read_to_string;
///
/// let path = "path/to/file.txt";
/// let result = read_to_string(path);
/// match result {
///     Ok(content) => println!("File content: {}", content),
///     Err(error) => eprintln!("Error: {}", error),
/// }
/// ```
pub fn read_to_string(path: &str) -> Result<String, OneIoError> {
    let mut reader = get_reader(path)?;
    let mut content = String::new();
    reader.read_to_string(&mut content)?;
    Ok(content)
}

/// Reads a JSON file and deserializes it into the specified struct.
///
/// # Arguments
///
/// * `path` - A string slice representing the path to the JSON file.
///
/// # Generic Parameters
///
/// * `T` - The type of struct to deserialize the JSON into. It must implement the DeserializeOwned trait from the serde crate.
///
/// # Returns
///
/// Returns a Result containing the deserialized struct if successful, or an OneIoError if there was an error reading the file or deserializing the JSON
#[cfg(feature = "json")]
pub fn read_json_struct<T: serde::de::DeserializeOwned>(path: &str) -> Result<T, OneIoError> {
    let reader = get_reader(path)?;
    let res: T = serde_json::from_reader(reader)?;
    Ok(res)
}

/// Reads lines from a file specified by the given path.
///
/// # Arguments
///
/// * `path` - A string slice that represents the path of the file to read.
///
/// # Returns
///
/// A `Result` containing a `Lines` iterator of `String` lines or a `OneIoError` indicating the error.
///
/// # Example
///
/// ```rust,no_run
/// use std::io::BufRead;
/// use std::io::BufReader;
/// const TEST_TEXT: &str = "OneIO test file.
/// This is a test.";
///
/// let lines = oneio::read_lines("https://spaces.bgpkit.org/oneio/test_data.txt.gz").unwrap()
///     .map(|line| line.unwrap()).collect::<Vec<String>>();
///
/// assert_eq!(lines.len(), 2);
/// assert_eq!(lines[0].as_str(), "OneIO test file.");
/// assert_eq!(lines[1].as_str(), "This is a test.");
/// ```
pub fn read_lines(path: &str) -> Result<Lines<BufReader<Box<dyn Read + Send>>>, OneIoError> {
    let reader = get_reader(path)?;
    let buf_reader = BufReader::new(reader);
    Ok(buf_reader.lines())
}

#[cfg(test)]
mod tests {

    #[cfg(feature = "json")]
    #[test]
    fn test_read_json_struct() {
        #[derive(serde::Deserialize, Debug)]
        struct Data {
            purpose: String,
            version: u32,
            meta: SubData,
        }
        #[derive(serde::Deserialize, Debug)]
        struct SubData {
            float: f64,
            success: bool,
        }

        let data =
            crate::read_json_struct::<Data>("https://spaces.bgpkit.org/oneio/test_data.json")
                .unwrap();

        assert_eq!(data.purpose, "test".to_string());
        assert_eq!(data.version, 1);
        assert_eq!(data.meta.float, 1.1);
        assert_eq!(data.meta.success, true);
    }
}
