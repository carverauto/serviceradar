//! # MRT Filter Archiver
//!
//! This example shows how to use the MRT encoding feature together with basic filters to create an
//! archiver for BGP messages for AS3356 (Lumen, top 1 on CAIDA AS Rank).
//!
//! The example will download the MRT file from RouteViews, filter out all the BGP messages that
//! are not originated from AS3356, and write the filtered MRT file to disk. Then it re-parses the
//! filtered MRT file and prints out the number of BGP messages.

use bgpkit_parser::Elementor;
use itertools::Itertools;
use std::io::Write;

fn main() {
    const OUTPUT_FILE: &str = "as3356_mrt.gz";

    println!("Start downloading and filtering BGP messages from AS3356");
    let mut mrt_writer = oneio::get_writer(OUTPUT_FILE).unwrap();

    let mut records_count = 0;
    let mut elems_count = 0;
    bgpkit_parser::BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2023.10/UPDATES/updates.20231029.2015.bz2",
    )
    .unwrap()
    .add_filter("origin_asn", "3356")
    .unwrap()
    .into_record_iter()
    .for_each(|record| {
        let bytes = record.encode();
        mrt_writer.write_all(&bytes).unwrap();
        records_count += 1;
        let mut elementor = Elementor::new();
        elems_count += elementor.record_to_elems(record).len();
    });
    // make sure to properly flush bytes from writer
    drop(mrt_writer);

    println!("Found and archived {records_count} MRT records, {elems_count} BGP messages");

    let elems = bgpkit_parser::BgpkitParser::new(OUTPUT_FILE)
        .unwrap()
        .into_elem_iter()
        .collect_vec();
    println!(
        "Read {} BGP messages from the newly archived MRT file.",
        elems.len()
    );
}
