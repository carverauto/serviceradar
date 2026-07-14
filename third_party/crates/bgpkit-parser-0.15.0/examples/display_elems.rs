use bgpkit_parser::BgpkitParser;

fn main() {
    let url = "http://archive.routeviews.org/bgpdata/\
        2021.10/UPDATES/updates.20211001.0000.bz2";
    for elem in BgpkitParser::new(url).unwrap() {
        println!(
            "{:?}|{:?}|{:?}|{:?}|{:?}",
            elem.elem_type, elem.timestamp, elem.prefix, elem.as_path, elem.next_hop,
        )
    }
}
