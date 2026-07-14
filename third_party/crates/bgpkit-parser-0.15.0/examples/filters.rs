use bgpkit_parser::BgpkitParser;

/// This example shows how to parse a MRT file and filter by prefix.
///
/// The corresponding command line execution is:
/// ```text
/// $ bgpkit-parser-cli http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2 --prefix 211.98.251.0/24
/// A|1633046459.372282|168.209.255.56|3741|211.98.251.0/24|3741 3356 58453 9808 9394|IGP|168.209.255.56|0|0||NAG||
/// A|1633046473.592947|168.209.255.56|3741|211.98.251.0/24|3741 3356 58453 9808 9394|IGP|168.209.255.56|0|0||NAG||
/// ```
///
/// The expected output of this example is (log's timestamp will be different):
/// ```text
/// [2021-12-11T02:45:25Z INFO  filters] downloading updates file
/// [2021-12-11T02:45:25Z INFO  filters] parsing updates file
/// [2021-12-11T02:45:26Z INFO  filters] A|1633046459.372282|168.209.255.56|3741|211.98.251.0/24|3741 3356 58453 9808 9394|IGP|168.209.255.56|0|0||NAG||
/// [2021-12-11T02:45:26Z INFO  filters] A|1633046473.592947|168.209.255.56|3741|211.98.251.0/24|3741 3356 58453 9808 9394|IGP|168.209.255.56|0|0||NAG||
/// [2021-12-11T02:45:29Z INFO  filters] done
/// ```
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    log::info!("downloading updates file");

    // create a parser that takes the buffered reader
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("prefix", "211.98.251.0/24")
    .unwrap();

    log::info!("parsing updates file");
    // iterating through the parser. the iterator returns `BgpElem` one at a time.
    for elem in parser {
        log::info!("{}", &elem);
    }
    log::info!("done");
}
