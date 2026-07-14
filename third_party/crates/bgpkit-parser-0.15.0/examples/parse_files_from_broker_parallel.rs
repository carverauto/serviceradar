use bgpkit_broker::BgpkitBroker;
use bgpkit_parser::BgpkitParser;
use rayon::prelude::*;

/// This example shows how use BGPKIT Broker to retrieve a number of data file pointers that matches
/// the time range criteria, and then parse all files in parallel.
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    // retrieve 10 files from broker within the time period.
    let broker = BgpkitBroker::new()
        .ts_start("1634693400")
        .ts_end("1634693400")
        .page(1);

    let file_urls: Vec<String> = broker.into_iter().take(10).map(|x| x.url).collect();

    let total_elems_count: i32 = file_urls
        .par_iter()
        .map(|url| {
            let parser = BgpkitParser::new(url.as_str()).unwrap();
            log::info!("parsing {} ...", url.as_str());
            parser.into_elem_iter().count() as i32
        })
        .sum();

    log::info!("total of {} BGP messages parsed", total_elems_count);
}
