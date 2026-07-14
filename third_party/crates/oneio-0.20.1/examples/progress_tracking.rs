//! Progress Tracking Example with indicatif
//!
//! This example demonstrates how to use OneIO's progress tracking feature
//! with the indicatif library to show beautiful progress bars when downloading
//! large files.

use indicatif::{ProgressBar, ProgressDrawTarget, ProgressStyle};
use std::io::Read;
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("OneIO Progress Tracking with indicatif\n");

    // Download a large BGP data file with a progress bar
    println!("=== Downloading Large BGP Data File ===");
    download_large_file()?;

    Ok(())
}

fn download_large_file() -> Result<(), Box<dyn std::error::Error>> {
    // Real-world example: RIPE RIS BGP data file (large compressed file)
    let url = "https://data.ris.ripe.net/rrc00/2025.08/bview.20250830.1600.gz";

    println!("Downloading BGP data from RIPE RIS...");
    println!("URL: {}", url);

    // Prepare to create a progress bar only after we know the total size
    // We'll use a lazy-initialized ProgressBar to avoid rendering before size
    let pb = ProgressBar::hidden();
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{elapsed_precise}] [{wide_bar:.cyan/blue}] {bytes}/{total_bytes} ({bytes_per_sec}, {eta})")?
            .progress_chars("#>-"),
    );
    pb.set_message("Downloading BGP data file");

    // We'll show the bar once we know the size (or after the first bytes for unknown)
    let pb_clone = pb.clone();

    // Get reader with progress tracking
    let (mut reader, _total_size) =
        oneio::get_reader_with_progress(url, move |bytes_read, total_bytes| {
            // Show and set length when we know the total size
            if total_bytes > 0 {
                if pb_clone.is_hidden() {
                    pb_clone.set_draw_target(ProgressDrawTarget::stderr());
                    pb_clone.set_length(total_bytes);
                    pb_clone.enable_steady_tick(Duration::from_millis(100));
                } else if pb_clone.length().unwrap_or(0) == 0 {
                    pb_clone.set_length(total_bytes);
                }
            } else {
                // Unknown size: show spinner-like behavior lazily after first bytes
                if pb_clone.is_hidden() && bytes_read > 0 {
                    pb_clone.set_draw_target(ProgressDrawTarget::stderr());
                    pb_clone.enable_steady_tick(Duration::from_millis(100));
                }
            }
            pb_clone.set_position(bytes_read);
        })?;

    // Read the entire file to trigger download and decompression
    let mut buffer = vec![0; 8192]; // 8KB buffer
    let mut total_decompressed = 0;

    while let Ok(n) = reader.read(&mut buffer) {
        if n == 0 {
            break;
        }
        total_decompressed += n;
    }

    pb.finish_with_message("Download complete!");
    println!(
        "Total decompressed size: {:.2} MB",
        total_decompressed as f64 / 1_048_576.0
    );

    Ok(())
}
