use bgpkit_parser::BgpkitParser;

/// Example demonstrating how to use fallible iterators to handle parsing errors explicitly
fn main() {
    // Example with fallible record iterator
    println!("=== Fallible Record Iterator Example ===");

    let parser =
        BgpkitParser::new("https://data.ris.ripe.net/rrc00/2021.11/updates.20211101.0000.gz")
            .unwrap()
            .disable_warnings();

    let mut success_count = 0;
    let mut error_count = 0;

    for (idx, result) in parser.into_fallible_record_iter().enumerate() {
        match result {
            Ok(record) => {
                success_count += 1;
                if idx < 5 {
                    println!(
                        "Record {}: timestamp={}, type={:?}",
                        idx, record.common_header.timestamp, record.common_header.entry_type
                    );
                }
            }
            Err(e) => {
                error_count += 1;
                println!("Error parsing record {}: {}", idx, e);
            }
        }

        // Stop after processing first 100 records for demo
        if idx >= 100 {
            break;
        }
    }

    println!(
        "\nProcessed {} records successfully, {} errors",
        success_count, error_count
    );

    // Example with fallible element iterator
    println!("\n=== Fallible Element Iterator Example ===");

    let parser =
        BgpkitParser::new("https://data.ris.ripe.net/rrc00/2021.11/updates.20211101.0000.gz")
            .unwrap()
            .disable_warnings();

    let mut elem_count = 0;
    let mut elem_errors = 0;

    for result in parser.into_fallible_elem_iter().take(100) {
        match result {
            Ok(elem) => {
                elem_count += 1;
                if elem_count <= 5 {
                    println!(
                        "Element {}: {} -> {} via {:?}",
                        elem_count, elem.peer_ip, elem.prefix, elem.next_hop
                    );
                }
            }
            Err(e) => {
                elem_errors += 1;
                println!("Error parsing element: {}", e);
            }
        }
    }

    println!(
        "\nProcessed {} elements successfully, {} errors",
        elem_count, elem_errors
    );
}
