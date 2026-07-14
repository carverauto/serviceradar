// Copyright (c) 2022, Yuri6037
//
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
// * Neither the name of time-tz nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Code inspired from https://github.com/chronotope/chrono-tz/blob/main/chrono-tz-build/src/lib.rs

use std::collections::{BTreeSet, HashMap};
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use parse_zoneinfo::line::{Line, LineParser};
use parse_zoneinfo::table::{Table, TableBuilder};
use parse_zoneinfo::transitions::TableTransitions;
use serde::Deserialize;
use serde_xml_rs::from_str;

const PARSE_FAILURE: &str = "Failed to parse one ore more tz databse file(s)";

#[derive(Debug, Deserialize, PartialEq)]
#[serde(rename = "mapZone")]
struct MapZone {
    other: String,
    territory: String,
    r#type: String
}

#[derive(Debug, Deserialize, PartialEq)]
struct MapTimezones {
    #[serde(rename = "$value")]
    content: Vec<MapZone>
}

#[derive(Debug, Deserialize, PartialEq)]
struct WindowsZones {
    #[serde(rename = "mapTimezones")]
    map_timezones: MapTimezones
}

#[derive(Debug, Deserialize, PartialEq)]
#[serde(rename = "supplementalData")]
struct SupplementalData {
    #[serde(rename = "windowsZones")]
    windows_zones: WindowsZones
}

fn parse_win_cldr_db() -> phf_codegen::Map<String> {
    let path = Path::new("win_cldr_data/windowsZones.xml");
    let data = std::fs::read_to_string(path)
        .expect("Failed to read windows CLDR database");
    let data: SupplementalData = from_str(&data)
        .expect("Failed to parse windows CLDR database");
    let mut map = phf_codegen::Map::new();
    for mapping in data.windows_zones.map_timezones.content {
        let zone_name_statics = get_zone_name_static(&mapping.r#type);
        let mut str = String::new();
        let mut split = zone_name_statics.split(" ").peekable();
        while let Some(item) = split.next() {
            str += "&internal_tz_new(&";
            str += item;
            str.push(')');
            if split.peek().is_some() {
                str += ", ";
            }
        }
        let zone_name_static = format!("&[{}]", str);
        if mapping.territory == "001" {
            map.entry(mapping.other, &zone_name_static);
        } else {
            map.entry(format!("{}/{}", mapping.other, mapping.territory), &zone_name_static);
        }
    }
    map
}

//Linked-list kind of structure: needed to support recursive module generation.
struct TimeZone<'a> {
    pub name: &'a str,
    pub name_static: String
}

struct ModuleTree<'a> {
    pub name: &'a str,
    pub items: Vec<TimeZone<'a>>,
    pub sub_modules: HashMap<&'a str, ModuleTree<'a>>
}

impl<'a> ModuleTree<'a> {
    pub fn new(name: &'a str) -> ModuleTree<'a> {
        ModuleTree {
            name,
            items: Vec::new(),
            sub_modules: HashMap::new()
        }
    }

    fn insert_zone(&mut self, item: TimeZone<'a>) {
        self.items.push(item);
    }

    pub fn insert(&mut self, zone_name: &'a str, zone_static: String) {
        let mut path = zone_name.split("/").peekable();
        let mut tree = self;
        while let Some(module) = path.next() {
            if path.peek().is_none() {
                tree.insert_zone(TimeZone {
                    name: module,
                    name_static: zone_static
                });
                break;
            } else {
                tree = tree.sub_modules.entry(module).or_insert(ModuleTree::new(module));
            }
        }
    }
}

fn intermal_write_module_tree(file: &mut BufWriter<File>, tree: &ModuleTree) -> std::io::Result<()>
{
    writeln!(file, "pub mod {} {{", tree.name.to_lowercase())?;
    for zone in &tree.items {
        writeln!(file, "pub const {}: &crate::Tz = &crate::timezone_impl::internal_tz_new(&crate::timezones::{});", zone.name
            .to_uppercase()
            .replace("-", "_")
            .replace("+", "_PLUS_"), zone.name_static)?;
    }
    for (_, subtree) in &tree.sub_modules {
        intermal_write_module_tree(file, subtree)?;
    }
    writeln!(file, "}}")?;
    Ok(())
}

fn get_zone_name_static(zone: &str) -> String
{
    zone.replace("/", "__")
        .replace("-", "_")
        .replace("+", "plus")
        .to_uppercase()
}

fn internal_write_timezones(file: &mut BufWriter<File>, table: &Table) -> std::io::Result<()>
{
    let zones: BTreeSet<&String> = table.zonesets.keys().chain(table.links.keys()).collect();
    let mut map = phf_codegen::Map::new();
    let mut root = ModuleTree::new("db");
    for zone in zones {
        let timespans = table.timespans(zone).unwrap();
        let zone_name_static = get_zone_name_static(&zone);
        writeln!(file, "const {}: FixedTimespanSet = FixedTimespanSet {{", zone_name_static)?;
        writeln!(file, "    name: \"{}\",", zone)?;
        writeln!(file, "    first: FixedTimespan {{ utc_offset: {}, dst_offset: {}, name: \"{}\" }},",
                 timespans.first.utc_offset,
                 timespans.first.dst_offset,
                 timespans.first.name)?;
        writeln!(file, "    others: &[")?;
        for (start, span) in timespans.rest {
            writeln!(file, "        ({}, FixedTimespan {{ utc_offset: {}, dst_offset: {}, name: \"{}\" }}),",
                     start,
                     span.utc_offset,
                     span.dst_offset,
                     span.name)?;
        }
        writeln!(file, "    ]")?;
        writeln!(file, "}};")?;
        map.entry(zone, &format!("&internal_tz_new(&{})", zone_name_static));
        root.insert(zone, zone_name_static);
    }
    let win_cldr_to_iana = parse_win_cldr_db();
    writeln!(file, "static WIN_TIMEZONES: Map<&'static str, &'static [&'static Tz]> = {};",
             win_cldr_to_iana.build())?;
    writeln!(file, "static TIMEZONES: Map<&'static str, &'static Tz> = {};", map.build())?;
    intermal_write_module_tree(file, &root)?;
    Ok(())
}

fn write_timezones_file(table: &Table)
{
    let path = std::env::var_os("OUT_DIR")
        .map(PathBuf::from)
        .expect("Couldn't obtain cargo OUT_DIR")
        .join("timezones.rs");
    let file = File::create(path)
        .expect("Couldn't create timezones file");
    let mut writer = BufWriter::new(file);
    internal_write_timezones(&mut writer, table).expect("Couldn't write timezones file");
}

fn main() {
    let tzfiles = [
        "tz/africa",
        "tz/antarctica",
        "tz/asia",
        "tz/australasia",
        "tz/backward",
        "tz/etcetera",
        "tz/europe",
        "tz/northamerica",
        "tz/southamerica",
    ];

    let lines = tzfiles.iter().map(Path::new)
        .map(File::open)
        .map(|v| v.expect("Failed to open one ore more tz databse file(s)"))
        .map(BufReader::new)
        .flat_map(|v| v.lines())
        .map(|v| v.expect("Filed to read one ore more tz databse file(s)"))
        .filter_map(|mut v| { //Pre-filter to get rid of comment-only lines as there are a lot.
            if let Some(i) = v.find('#') {
                v.truncate(i);
            }
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        });
    let mut builder = TableBuilder::new();
    let parser = LineParser::new();
    for line in lines {
        match parser.parse_str(&line).expect(PARSE_FAILURE) {
            Line::Space => {},
            Line::Zone(v) => builder.add_zone_line(v).expect(PARSE_FAILURE),
            Line::Continuation(v) => builder.add_continuation_line(v).expect(PARSE_FAILURE),
            Line::Rule(v) => builder.add_rule_line(v).expect(PARSE_FAILURE),
            Line::Link(v) => builder.add_link_line(v).expect(PARSE_FAILURE)
        }
    }
    let table = builder.build();
    write_timezones_file(&table);
    //Only run when tz database actually changes (avoids re-running complex logic).
    println!("cargo:rerun-if-changed=./tz");
}
