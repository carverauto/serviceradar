use bgpkit_parser::BgpkitParser;

/// an very simple example that reads a remote BGP data file and print out the message count.
fn main() {
    let url = "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2";
    let count = BgpkitParser::new(url).unwrap().into_iter().count();
    println!("{count}");
}
