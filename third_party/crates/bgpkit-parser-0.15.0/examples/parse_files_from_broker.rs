use bgpkit_broker::BgpkitBroker;
use bgpkit_parser::{BgpElem, BgpkitParser};

/// This example shows how use BGPKIT Broker to retrieve a number of data file pointers that matches
/// the time range criteria, and then parse the data files for each one.
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let broker = BgpkitBroker::new()
        .ts_start("1634693400")
        .ts_end("1634693400")
        .page(1);

    for item in broker.into_iter().take(2) {
        log::info!("downloading updates file: {}", &item.url);
        let parser = BgpkitParser::new(item.url.as_str()).unwrap();

        log::info!("parsing updates file");
        // iterating through the parser. the iterator returns `BgpElem` one at a time.
        let elems = parser
            .into_elem_iter()
            .filter_map(|elem| {
                if let Some(origins) = &elem.origin_asns {
                    if origins.contains(&13335.into()) {
                        Some(elem)
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .collect::<Vec<BgpElem>>();
        log::info!("{} elems matches", elems.len());
    }
}
