//! Test the rapidhash CLI tool.
//!
//! Installation: cargo install rapidhash
//! Usage example: rapidhash --v3 [filename]

use std::fs::File;
use std::io::Write;
use assert_cmd::Command;
use tempfile::tempdir;
use rapidhash::v1::rapidhash_v1;
use rapidhash::v2::rapidhash_v2_inline;
use rapidhash::v3::rapidhash_v3;

/// Test: `echo "test input" | rapidhash --v3`
///
/// Note `echo` appends a newline character at the end of the input.
#[test]
#[cfg(feature = "std")]
fn cli_stdin() {
    let input = "test input\n";
    let expected = rapidhash_v3("test input\n".as_bytes()).to_string();

    Command::new(assert_cmd::cargo_bin!("rapidhash"))
        .args(&["--v3"])
        .write_stdin(input)
        .assert()
        .success()
        .stdout(format!("{expected}\n"));
}

/// Test: `rapidhash --v3 file.txt`
#[test]
#[cfg(feature = "std")]
fn cli_file() {
    let input = "test input\n";
    let expected = rapidhash_v3(input.as_bytes()).to_string();

    let dir = tempdir().unwrap();
    let file_path = dir.path().join("test.txt");
    let mut file = File::create_new(file_path.clone()).unwrap();
    file.write_all(input.as_bytes()).unwrap();
    file.flush().unwrap();

    Command::new(assert_cmd::cargo_bin!("rapidhash"))
        .args(&["--v3", file_path.to_str().unwrap()])
        .assert()
        .success()
        .stdout(format!("{expected}\n"));
}

/// Test all rapidhash versions.
#[test]
#[cfg(feature = "std")]
fn cli_versions() {
    let input = "test input\n".as_bytes();

    let versions = [
        ("--v1", rapidhash_v1(input).to_string()),
        ("--v2.0", rapidhash_v2_inline::<0, true, false, false>(input, &rapidhash::v2::DEFAULT_RAPID_SECRETS).to_string()),
        ("--v2.1", rapidhash_v2_inline::<1, true, false, false>(input, &rapidhash::v2::DEFAULT_RAPID_SECRETS).to_string()),
        ("--v2.2", rapidhash_v2_inline::<2, true, false, false>(input, &rapidhash::v2::DEFAULT_RAPID_SECRETS).to_string()),
        ("--v3", rapidhash_v3(input).to_string()),
    ];

    for (flag, expected) in versions {
        Command::new(assert_cmd::cargo_bin!("rapidhash"))
            .args(&[flag])
            .write_stdin(input)
            .assert()
            .success()
            .stdout(format!("{}\n", expected));
    }
}
