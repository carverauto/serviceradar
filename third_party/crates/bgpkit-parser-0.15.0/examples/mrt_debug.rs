//! Example demonstrating MRT debug features.
//!
//! This example shows how to:
//! 1. Display MRT records and BGP elements in JSON format for debugging
//! 2. Display MRT records in a debug-friendly format
//! 3. Export raw MRT record bytes to files for debugging
//!
//! Run with: cargo run --example mrt_debug --features serde

use bgpkit_parser::BgpkitParser;

fn main() {
    let url = "https://spaces.bgpkit.org/parser/update-example.gz";
    println!("Parsing: {}\n", url);

    println!("=== MRT Record JSON Format Examples ===\n");

    // Show first 3 MRT records in JSON format
    for (idx, record) in BgpkitParser::new(url)
        .unwrap()
        .into_record_iter()
        .take(3)
        .enumerate()
    {
        println!("[Record {}]", idx + 1);
        #[cfg(feature = "serde")]
        println!("{}", serde_json::to_string_pretty(&record).unwrap());
        #[cfg(not(feature = "serde"))]
        println!("{:?}", record);
        println!();
    }

    println!("=== BGP Element JSON Format Examples ===\n");

    // Show first 5 elements in JSON format
    for (idx, elem) in BgpkitParser::new(url)
        .unwrap()
        .into_iter()
        .take(5)
        .enumerate()
    {
        println!("[Element {}]", idx + 1);
        #[cfg(feature = "serde")]
        println!("{}", serde_json::to_string(&elem).unwrap());
        #[cfg(not(feature = "serde"))]
        println!("{:?}", elem);
    }

    println!("\n=== MRT Record Debug Display ===\n");

    // Show first 5 MRT records with debug display
    let parser = BgpkitParser::new(url).unwrap();
    for (idx, record) in parser.into_record_iter().take(5).enumerate() {
        println!("[{}] {}", idx + 1, record);
    }

    println!("\n=== Raw MRT Record Iteration ===\n");

    // Demonstrate raw record iteration and byte export
    let parser = BgpkitParser::new(url).unwrap();
    for (idx, raw_record) in parser.into_raw_record_iter().take(3).enumerate() {
        println!("[{}] Raw Record:", idx + 1);
        println!("    Header: {}", raw_record.common_header);
        println!("    Total bytes: {} bytes", raw_record.total_bytes_len());
        println!("    Header size: {} bytes", raw_record.header_bytes.len());
        println!(
            "    Message body size: {} bytes",
            raw_record.message_bytes.len()
        );

        // Demonstrate parsing the raw record
        match raw_record.clone().parse() {
            Ok(parsed) => {
                println!("    Parsed: {}", parsed);
            }
            Err(e) => {
                println!("    Parse error: {}", e);
                // In case of error, you could export the problematic record:
                // raw_record.write_raw_bytes(format!("problematic_{}.mrt", idx)).unwrap();
            }
        }
        println!();
    }

    println!("=== Exporting Raw Bytes Example ===\n");

    // Export a few records to demonstrate the functionality
    let parser = BgpkitParser::new(url).unwrap();
    let output_file = "/tmp/debug_records.mrt";

    let mut count = 0;
    for raw_record in parser.into_raw_record_iter().take(10) {
        // Append each record to the same file
        if let Err(e) = raw_record.append_raw_bytes(output_file) {
            eprintln!("Failed to write record: {}", e);
        }
        count += 1;
    }

    println!("Exported {} records to {}", count, output_file);

    // Verify by reading back
    let verify_parser = BgpkitParser::new(output_file).unwrap();
    let verify_count = verify_parser.into_record_iter().count();
    println!(
        "Verification: read back {} records from exported file",
        verify_count
    );

    // Clean up
    let _ = std::fs::remove_file(output_file);

    println!("\nDone!");
}
