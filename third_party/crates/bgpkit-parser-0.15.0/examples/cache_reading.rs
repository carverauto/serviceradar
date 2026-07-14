use bgpkit_broker::BgpkitBroker;
use bgpkit_parser::{BgpElem, BgpkitParser};

/// This example shows how use parser's cache feature to read data files from the local disk.
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let broker = BgpkitBroker::new()
        .ts_start("2014-04-01T00:00:01Z")
        .ts_end("2014-04-01T00:04:59Z")
        .project("riperis")
        .data_type("update");

    for item in broker.query().unwrap() {
        let parser =
            BgpkitParser::new_cached(item.url.as_str(), "/tmp/bgpkit-cache-example/").unwrap();
        // iterating through the parser. the iterator returns `BgpElem` one at a time.
        let elems = parser.into_elem_iter().collect::<Vec<BgpElem>>();
        log::info!("{} {} {}", item.collector_id, item.url, elems.len());
    }
}
