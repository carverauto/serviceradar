use bgpkit_parser::models::MetaCommunity;
use bgpkit_parser::BgpkitParser;

/// This example shows how to printout BGP messages with extended or large communities;
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
        if let Some(cs) = &elem.communities {
            for c in cs {
                match c {
                    MetaCommunity::Plain(_) => {}
                    MetaCommunity::Extended(_)
                    | MetaCommunity::Large(_)
                    | MetaCommunity::Ipv6Extended(_) => {
                        log::info!("{}", &elem);
                    }
                }
            }
        }
    }
    log::info!("done");
}
