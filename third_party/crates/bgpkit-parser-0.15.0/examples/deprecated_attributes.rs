//! This example shows how to iterate over all the BGP announcements with deprecated attributes.
use bgpkit_parser::BgpkitParser;
use serde_json::json;

fn main() {
    // the following file contains a number of deprecated attributes (28, BGP Entropy Label Capability)
    for elem in BgpkitParser::new(
        "https://archive.routeviews.org/route-views6/bgpdata/2023.06/UPDATES/updates.20230602.1330.bz2",
    )
    .unwrap()
    {
        if elem.deprecated.is_some() {
            println!(
                "{}",
                json!(elem)
            );
        }
    }
}
