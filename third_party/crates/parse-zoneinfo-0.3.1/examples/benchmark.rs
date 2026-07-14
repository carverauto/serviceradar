extern crate parse_zoneinfo;

use parse_zoneinfo::line::{Line, LineParser};
use parse_zoneinfo::table::TableBuilder;

fn main() {
    let asia = std::fs::read_to_string("examples/asia").unwrap();

    for _ in 0..100 {
        let parser = LineParser::default();
        let mut builder = TableBuilder::new();
        for line in asia.lines() {
            match parser.parse_str(line).unwrap() {
                Line::Zone(zone) => builder.add_zone_line(zone).unwrap(),
                Line::Continuation(cont) => builder.add_continuation_line(cont).unwrap(),
                Line::Rule(rule) => builder.add_rule_line(rule).unwrap(),
                Line::Link(link) => builder.add_link_line(link).unwrap(),
                Line::Space => {}
            }
        }
        let _table = builder.build();
    }
}
