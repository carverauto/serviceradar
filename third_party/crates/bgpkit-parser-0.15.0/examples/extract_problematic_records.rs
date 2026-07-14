//! Example demonstrating how to find and extract problematic MRT records.
//!
//! This example shows how to:
//! 1. Iterate over raw MRT records
//! 2. Attempt to parse each record
//! 3. Export records that fail to parse for debugging
//!
//! This is useful for identifying malformed or unusual MRT records that
//! cause parsing issues, allowing you to analyze them with other tools
//! or report them for investigation.
//!
//! Run with: cargo run --example extract_problematic_records -- <mrt_file> [output_file]

use bgpkit_parser::BgpkitParser;
use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: {} <mrt_file> [output_file]", args[0]);
        eprintln!();
        eprintln!("Arguments:");
        eprintln!("  mrt_file    - Path or URL to the MRT file to analyze");
        eprintln!("  output_file - Optional path to export problematic records (default: problematic_records.mrt)");
        eprintln!();
        eprintln!("Example:");
        eprintln!(
            "  {} https://data.ris.ripe.net/rrc00/latest-update.gz",
            args[0]
        );
        std::process::exit(1);
    }

    let input_file = &args[1];
    let output_file = args
        .get(2)
        .map(|s| s.as_str())
        .unwrap_or("problematic_records.mrt");

    println!("Analyzing MRT file: {}", input_file);
    println!("Problematic records will be saved to: {}", output_file);
    println!();

    let parser = match BgpkitParser::new(input_file) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Failed to open MRT file: {}", e);
            std::process::exit(1);
        }
    };

    let mut total_records = 0;
    let mut parsed_ok = 0;
    let mut parse_errors = 0;
    let mut export_errors = 0;

    for raw_record in parser.into_raw_record_iter() {
        total_records += 1;

        // Try to parse the record
        match raw_record.clone().parse() {
            Ok(_parsed) => {
                parsed_ok += 1;
            }
            Err(e) => {
                parse_errors += 1;
                println!(
                    "Record #{}: Parse error at timestamp {}",
                    total_records, raw_record.common_header.timestamp
                );
                println!("  Error: {}", e);
                println!("  Header: {}", raw_record.common_header);
                println!("  Size: {} bytes", raw_record.total_bytes_len());

                // Export the problematic record
                if let Err(write_err) = raw_record.append_raw_bytes(output_file) {
                    eprintln!("  Failed to export record: {}", write_err);
                    export_errors += 1;
                } else {
                    println!("  -> Exported to {}", output_file);
                }
                println!();
            }
        }

        // Progress indicator every 100,000 records
        if total_records % 100_000 == 0 {
            eprintln!(
                "Progress: {} records processed ({} errors so far)",
                total_records, parse_errors
            );
        }
    }

    println!("=== Summary ===");
    println!("Total records processed: {}", total_records);
    println!("Successfully parsed:     {}", parsed_ok);
    println!("Parse errors:            {}", parse_errors);
    if export_errors > 0 {
        println!("Export errors:           {}", export_errors);
    }

    if parse_errors > 0 {
        println!();
        println!("Problematic records exported to: {}", output_file);
        println!();
        println!("You can analyze the exported records with:");
        println!("  - bgpdump -m {}", output_file);
        println!("  - This parser with verbose debugging");
        println!("  - Hex editor for raw byte analysis");
    } else {
        println!();
        println!("No problematic records found!");
    }
}
