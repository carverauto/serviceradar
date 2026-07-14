use bgpkit_broker::BgpkitBroker;
use bgpkit_parser::models::{AsPathSegment, Asn};
use bgpkit_parser::BgpkitParser;
use rayon::prelude::*;
use std::collections::HashSet;

fn main() {
    let items = BgpkitBroker::new()
        .data_type("rib")
        .project("route-views")
        .ts_start("2023-03-01T00:00:00Z")
        .ts_end("2023-03-01T00:00:00Z")
        .query()
        .unwrap();

    println!("start parsing {} ribs in parallel", items.len());
    items.par_iter().for_each(|item| {
        let parser = BgpkitParser::new(item.url.as_str()).unwrap();
        let collector = item.collector_id.clone();
        let mut origins: HashSet<Asn> = HashSet::new();
        for elem in parser {
            if !elem.elem_type.is_announce() {
                continue;
            }
            for seg in elem.as_path.as_ref().unwrap().iter_segments() {
                match seg {
                    AsPathSegment::AsSet(p) | AsPathSegment::ConfedSet(p) => {
                        // println!("{elem}");
                        origins.insert(*p.last().unwrap());
                    }
                    _ => {}
                }
            }
        }

        if !origins.is_empty() {
            println!(
                "found {} origins with AS set from {} collector",
                origins.len(),
                collector.as_str()
            );
        }
    });
}
