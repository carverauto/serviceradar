// Async integration tests for oneio async feature
// These tests are only compiled/run when the `async` feature is enabled.

#![cfg(feature = "async")]

use oneio;
use tokio::io::AsyncReadExt;

const TEST_TEXT: &str = "OneIO test file.\nThis is a test.";

#[tokio::test]
async fn async_read_local_plain() {
    let mut reader = oneio::get_reader_async("tests/test_data.txt")
        .await
        .unwrap();
    let mut content = String::new();
    reader.read_to_string(&mut content).await.unwrap();
    assert_eq!(content, TEST_TEXT);
}

#[cfg(feature = "any_gz")]
#[tokio::test]
async fn async_read_local_gzip() {
    let mut reader = oneio::get_reader_async("tests/test_data.txt.gz")
        .await
        .unwrap();
    let mut content = String::new();
    reader.read_to_string(&mut content).await.unwrap();
    assert_eq!(content, TEST_TEXT);
}

#[cfg(feature = "http")]
#[tokio::test]
async fn async_read_http_plain() {
    // Use remote small test data provided by project
    match oneio::get_reader_async("https://spaces.bgpkit.org/oneio/test_data.txt").await {
        Ok(mut reader) => {
            let mut content = String::new();
            reader.read_to_string(&mut content).await.unwrap();
            assert_eq!(content.trim(), TEST_TEXT);
        }
        Err(e) => {
            // Network may be unavailable in CI; don't fail entire suite.
            eprintln!("async_read_http_plain skipped due to error: {e}");
        }
    }
}

#[cfg(all(feature = "http", feature = "any_gz"))]
#[tokio::test]
async fn async_read_http_gzip() {
    match oneio::get_reader_async("https://spaces.bgpkit.org/oneio/test_data.txt.gz").await {
        Ok(mut reader) => {
            let mut content = String::new();
            reader.read_to_string(&mut content).await.unwrap();
            assert_eq!(content.trim(), TEST_TEXT);
        }
        Err(e) => {
            eprintln!("async_read_http_gzip skipped due to error: {e}");
        }
    }
}

#[cfg(feature = "http")]
#[tokio::test]
async fn async_download_http_to_file() {
    // Verify download_async writes content to a local file
    let tmp_path = "tests/_tmp_async_download.txt";
    // Clean up any previous run
    let _ = std::fs::remove_file(tmp_path);

    match oneio::download_async("https://spaces.bgpkit.org/oneio/test_data.txt", tmp_path).await {
        Ok(()) => {
            let text = std::fs::read_to_string(tmp_path).unwrap();
            assert_eq!(text.trim(), TEST_TEXT);
        }
        Err(e) => {
            eprintln!("async_download_http_to_file skipped due to error: {e}");
        }
    }

    let _ = std::fs::remove_file(tmp_path);
}
