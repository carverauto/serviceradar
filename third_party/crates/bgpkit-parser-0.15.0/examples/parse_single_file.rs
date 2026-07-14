use bgpkit_parser::BgpkitParser;

/// This example shows how to download and process a single BGP archive file with BGPKIT Parser.
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    log::info!("downloading updates file");

    // create a parser that takes the buffered reader
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap();

    log::info!("parsing updates file");
    // iterating through the parser. the iterator returns `BgpElem` one at a time.
    for elem in parser {
        log::info!("{}", &elem);
    }
    log::info!("done");
}
