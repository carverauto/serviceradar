//! This example shows how to filter the content of a RIB file and re-encode into a new RIB file
//! with the filtered content.

use std::io::Write;
use tracing::info;

fn main() {
    tracing_subscriber::fmt::init();

    // const RIB_URL: &str = "https://data.ris.ripe.net/rrc26/2023.12/bview.20231221.1600.gz";
    const RIB_URL: &str = "unfiltered.rib.gz";
    let mut encoder = bgpkit_parser::encoder::MrtRibEncoder::new();
    let parser = bgpkit_parser::BgpkitParser::new(RIB_URL)
        .unwrap()
        .add_filter("origin_asn", "13335")
        .unwrap()
        .disable_warnings();

    info!("processing rib {}", RIB_URL);
    for elem in parser {
        encoder.process_elem(&elem);
    }

    info!("exporting filtered RIB...");
    let mut writer = oneio::get_writer("filtered-13335.rib.gz").unwrap();
    writer.write_all(encoder.export_bytes().as_ref()).unwrap();
    drop(writer);

    info!("exporting filtered RIB...done");
}
