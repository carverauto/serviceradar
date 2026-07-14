//! Basic integration tests using only default features (gz, bz, http)
//! These tests should always pass with `cargo test`

use oneio;
use std::io::{Read, Write};

const TEST_TEXT: &str = "OneIO test file.\nThis is a test.";

fn test_read(file_path: &str) {
    let mut reader = oneio::get_reader(file_path).unwrap();
    let mut text = "".to_string();
    reader.read_to_string(&mut text).unwrap();
    assert_eq!(text.as_str(), TEST_TEXT);

    assert_eq!(
        oneio::read_to_string(file_path).unwrap().as_str(),
        TEST_TEXT
    );

    let lines = oneio::read_lines(file_path)
        .unwrap()
        .map(|line| line.unwrap())
        .collect::<Vec<String>>();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0].as_str(), "OneIO test file.");
    assert_eq!(lines[1].as_str(), "This is a test.");
}

fn test_write(to_write_file: &str, to_read_file: &str) {
    let mut text = "".to_string();
    oneio::get_reader(to_read_file)
        .unwrap()
        .read_to_string(&mut text)
        .unwrap();

    let mut writer = oneio::get_writer(to_write_file).unwrap();
    writer.write_all(text.as_ref()).unwrap();
    drop(writer);

    let mut new_text = "".to_string();
    oneio::get_reader(to_write_file)
        .unwrap()
        .read_to_string(&mut new_text)
        .unwrap();

    assert_eq!(text.as_str(), new_text.as_str());
    std::fs::remove_file(to_write_file).unwrap();
}

#[test]
fn test_local_files() {
    // Test local file reading with default compression formats
    test_read("tests/test_data.txt");

    // Test gzip (default feature)
    #[cfg(feature = "any_gz")]
    test_read("tests/test_data.txt.gz");

    // Test bzip2 (default feature)
    #[cfg(feature = "bz")]
    test_read("tests/test_data.txt.bz2");
}

#[test]
fn test_writers() {
    // Test writing with default compression formats
    test_write("tests/test_write_data.txt", "tests/test_data.txt");

    #[cfg(feature = "any_gz")]
    test_write("tests/test_write_data.txt.gz", "tests/test_data.txt.gz");

    #[cfg(feature = "bz")]
    test_write("tests/test_write_data.txt.bz2", "tests/test_data.txt.bz2");
}

#[cfg(feature = "http")]
#[test]
fn test_remote_files() {
    // Test HTTP reading (default feature)
    test_read("https://spaces.bgpkit.org/oneio/test_data.txt");

    #[cfg(feature = "any_gz")]
    test_read("https://spaces.bgpkit.org/oneio/test_data.txt.gz");

    #[cfg(feature = "bz")]
    test_read("https://spaces.bgpkit.org/oneio/test_data.txt.bz2");
}

#[cfg(feature = "http")]
#[test]
fn test_404_handling() {
    let reader = oneio::get_reader("https://spaces.bgpkit.org/oneio/test_data_NOT_EXIST.json");
    assert!(reader.is_err());
    assert!(!oneio::exists("https://spaces.bgpkit.org/oneio/test_data_NOT_EXIST.json").unwrap());

    let reader = oneio::get_reader("https://spaces.bgpkit.org/oneio/test_data.json");
    assert!(reader.is_ok());
    assert!(oneio::exists("https://spaces.bgpkit.org/oneio/test_data.json").unwrap());
}
