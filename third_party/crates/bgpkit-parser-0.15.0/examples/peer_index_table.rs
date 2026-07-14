use serde_json::{json, to_string_pretty};

/// This example reads from TableDumpV2-formatted RIB dump from RIPE RIS and print out the JSON-formatted
/// peer index table.
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("debug")).init();
    // a 1.3GB rib dump file from rrc03
    let url = "https://data.ris.ripe.net/rrc03/2021.11/bview.20211128.1600.gz";
    let parser = bgpkit_parser::BgpkitParser::new(url).unwrap();
    for record in parser.into_record_iter().take(1) {
        println!("{}", to_string_pretty(&json!(record)).unwrap());
    }
}
