//! Async Read Example for OneIO
//!
//! Demonstrates reading a file asynchronously using OneIO's async API.
//!
//! Requires the "async" feature and an async runtime (tokio).

use oneio::get_reader_async;
use oneio::read_to_string_async;
use tokio::io::{AsyncReadExt, BufReader};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("OneIO Async Read Example\n");

    // You can use a local file or a remote URL
    let path = "tests/test_data.txt.gz";

    // --- High-level API: read_to_string_async ---
    println!("Reading file asynchronously (high-level): {}", path);
    let content = read_to_string_async(path).await?;
    println!("File content (high-level):\n{}", content);

    // --- Low-level API: get_reader_async ---
    println!(
        "\nReading file asynchronously (low-level async reader): {}",
        path
    );
    let reader = get_reader_async(path).await?;
    let mut buf_reader = BufReader::new(reader);
    let mut buffer = Vec::new();
    buf_reader.read_to_end(&mut buffer).await?;
    let content_str = String::from_utf8_lossy(&buffer);
    println!("File content (low-level):\n{}", content_str);

    Ok(())
}
