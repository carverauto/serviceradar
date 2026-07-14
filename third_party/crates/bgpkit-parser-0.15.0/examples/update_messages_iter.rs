//! Example demonstrating the use of `into_update_iter()` for processing BGP announcements.
//!
//! The `UpdateIterator` provides a middle ground between `RecordIterator` and `ElemIterator`:
//! - More focused than `RecordIterator` as it only yields BGP announcements
//! - More efficient than `ElemIterator` as it avoids duplicating attributes for each prefix
//!
//! This iterator handles both:
//! - **BGP4MP UPDATE messages** from UPDATES files (real-time updates)
//! - **TableDumpV2 RIB entries** from RIB dump files (routing table snapshots)
//!
//! This example compares the performance of `UpdateIterator` vs `ElemIterator` when counting
//! announced and withdrawn prefixes, and verifies that both approaches yield the same results.
//!
//! Run with: cargo run --example update_messages_iter --release

use bgpkit_parser::models::{AttributeValue, ElemType};
use bgpkit_parser::{BgpkitParser, MrtUpdate};
use std::time::Instant;

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    // You can test with either an UPDATES file or a RIB dump file:
    // UPDATES file (BGP4MP messages):
    // let url = "https://archive.routeviews.org/bgpdata/2024.11/UPDATES/updates.20241101.0000.bz2";
    // RIB dump file (TableDumpV2 messages):
    let url = "https://archive.routeviews.org/bgpdata/2024.11/RIBS/rib.20241101.0000.bz2";

    log::info!("Parsing MRT file: {}", url);
    log::info!("");

    // ========================================
    // Method 1: Using UpdateIterator
    // ========================================
    log::info!("=== Method 1: UpdateIterator ===");

    let start = Instant::now();
    let parser = BgpkitParser::new(url).unwrap();

    let mut bgp4mp_update_count = 0;
    let mut rib_entry_count = 0;
    let mut table_dump_v1_count = 0;
    let mut update_iter_announced = 0;
    let mut update_iter_withdrawn = 0;

    for update in parser.into_update_iter() {
        match update {
            MrtUpdate::Bgp4MpUpdate(update) => {
                bgp4mp_update_count += 1;

                // Count announced prefixes (both from announced_prefixes and MP_REACH_NLRI)
                let announced_count = update.message.announced_prefixes.len();
                let mp_reach_count: usize = update
                    .message
                    .attributes
                    .iter()
                    .filter_map(|attr| {
                        if let AttributeValue::MpReachNlri(nlri) = attr {
                            Some(nlri.prefixes.len())
                        } else {
                            None
                        }
                    })
                    .sum();
                update_iter_announced += announced_count + mp_reach_count;

                // Count withdrawn prefixes (both from withdrawn_prefixes and MP_UNREACH_NLRI)
                let withdrawn_count = update.message.withdrawn_prefixes.len();
                let mp_unreach_count: usize = update
                    .message
                    .attributes
                    .iter()
                    .filter_map(|attr| {
                        if let AttributeValue::MpUnreachNlri(nlri) = attr {
                            Some(nlri.prefixes.len())
                        } else {
                            None
                        }
                    })
                    .sum();
                update_iter_withdrawn += withdrawn_count + mp_unreach_count;
            }
            MrtUpdate::TableDumpV2Entry(entry) => {
                rib_entry_count += 1;
                // In TableDumpV2, each entry represents ONE prefix with multiple RIB entries (one per peer)
                // Each RIB entry is an announcement of that prefix
                update_iter_announced += entry.rib_entries.len();
            }
            MrtUpdate::TableDumpMessage(_msg) => {
                table_dump_v1_count += 1;
                // Legacy TableDump v1: one record = one prefix = one announcement
                update_iter_announced += 1;
            }
        }
    }

    let update_iter_duration = start.elapsed();

    log::info!("Message counts:");
    log::info!("  - BGP4MP UPDATE messages: {}", bgp4mp_update_count);
    log::info!("  - TableDumpV2 RIB entries: {}", rib_entry_count);
    log::info!("  - TableDump v1 messages: {}", table_dump_v1_count);
    log::info!("Total announced prefixes: {}", update_iter_announced);
    log::info!("Total withdrawn prefixes: {}", update_iter_withdrawn);
    log::info!("Time elapsed: {:?}", update_iter_duration);
    log::info!("");

    // ========================================
    // Method 2: Using ElemIterator
    // ========================================
    log::info!("=== Method 2: ElemIterator ===");

    let start = Instant::now();
    let parser = BgpkitParser::new(url).unwrap();

    let mut elem_count = 0;
    let mut elem_iter_announced = 0;
    let mut elem_iter_withdrawn = 0;

    for elem in parser.into_elem_iter() {
        elem_count += 1;

        match elem.elem_type {
            ElemType::ANNOUNCE => elem_iter_announced += 1,
            ElemType::WITHDRAW => elem_iter_withdrawn += 1,
        }
    }

    let elem_iter_duration = start.elapsed();

    log::info!("Total BGP elements: {}", elem_count);
    log::info!("Total announced prefixes: {}", elem_iter_announced);
    log::info!("Total withdrawn prefixes: {}", elem_iter_withdrawn);
    log::info!("Time elapsed: {:?}", elem_iter_duration);
    log::info!("");

    // ========================================
    // Comparison
    // ========================================
    log::info!("=== Comparison ===");

    let announced_match = update_iter_announced == elem_iter_announced;
    let withdrawn_match = update_iter_withdrawn == elem_iter_withdrawn;

    log::info!(
        "Announced prefixes match: {} (UpdateIter: {}, ElemIter: {})",
        if announced_match { "✓" } else { "✗" },
        update_iter_announced,
        elem_iter_announced
    );
    log::info!(
        "Withdrawn prefixes match: {} (UpdateIter: {}, ElemIter: {})",
        if withdrawn_match { "✓" } else { "✗" },
        update_iter_withdrawn,
        elem_iter_withdrawn
    );

    if update_iter_duration.as_nanos() > 0 {
        let speedup = elem_iter_duration.as_secs_f64() / update_iter_duration.as_secs_f64();
        log::info!(
            "Performance: UpdateIterator is {:.2}x {} than ElemIterator",
            if speedup >= 1.0 {
                speedup
            } else {
                1.0 / speedup
            },
            if speedup >= 1.0 { "faster" } else { "slower" }
        );
    }
    log::info!("  - UpdateIterator: {:?}", update_iter_duration);
    log::info!("  - ElemIterator:   {:?}", elem_iter_duration);

    // Assert counts match
    assert_eq!(
        update_iter_announced, elem_iter_announced,
        "Announced prefix counts should match!"
    );
    assert_eq!(
        update_iter_withdrawn, elem_iter_withdrawn,
        "Withdrawn prefix counts should match!"
    );

    log::info!("");
    log::info!("All counts verified successfully!");
}
