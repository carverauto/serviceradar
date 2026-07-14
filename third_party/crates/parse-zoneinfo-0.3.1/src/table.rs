//! Collecting parsed zoneinfo data lines into a set of time zone data.
//!
//! This module provides the `Table` struct, which is able to take parsed
//! lines of input from the `line` module and coalesce them into a single
//! set of data.
//!
//! It’s not as simple as it seems, because the zoneinfo data lines refer to
//! each other through strings: lines of the form “link zone A to B” could be
//! *parsed* successfully but still fail to be *interpreted* successfully if
//! “B” doesn’t exist. So it has to check every step of the way—nothing wrong
//! with this, it’s just a consequence of reading data from a text file.
//!
//! This module only deals with constructing a table from data: any analysis
//! of the data is done elsewhere.
//!
//!
//! ## Example
//!
//! ```
//! use parse_zoneinfo::line::{Zone, Line, LineParser, Link};
//! use parse_zoneinfo::table::{TableBuilder};
//!
//! let parser = LineParser::default();
//! let mut builder = TableBuilder::new();
//!
//! let zone = "Zone  Pacific/Auckland  11:39:04  -  LMT  1868  Nov  2";
//! let link = "Link  Pacific/Auckland  Antarctica/McMurdo";
//!
//! for line in [zone, link] {
//!     match parser.parse_str(&line)? {
//!         Line::Zone(zone) => builder.add_zone_line(zone).unwrap(),
//!         Line::Continuation(cont) => builder.add_continuation_line(cont).unwrap(),
//!         Line::Rule(rule) => builder.add_rule_line(rule).unwrap(),
//!         Line::Link(link) => builder.add_link_line(link).unwrap(),
//!         Line::Space => {}
//!     }
//! }
//!
//! let table = builder.build();
//!
//! assert!(table.get_zoneset("Pacific/Auckland").is_some());
//! assert!(table.get_zoneset("Antarctica/McMurdo").is_some());
//! assert!(table.get_zoneset("UTC").is_none());
//! # Ok::<(), parse_zoneinfo::line::Error>(())
//! ```

use std::collections::hash_map::{Entry, HashMap};
use std::fmt;

use crate::line::{self, ChangeTime, DaySpec, Month, TimeType, Year};

/// A **table** of all the data in one or more zoneinfo files.
#[derive(PartialEq, Debug, Default)]
pub struct Table {
    /// Mapping of ruleset names to rulesets.
    pub rulesets: HashMap<String, Vec<RuleInfo>>,

    /// Mapping of zoneset names to zonesets.
    pub zonesets: HashMap<String, Vec<ZoneInfo>>,

    /// Mapping of link timezone names, to the names they link to.
    pub links: HashMap<String, String>,
}

impl Table {
    /// Tries to find the zoneset with the given name by looking it up in
    /// either the zonesets map or the links map.
    pub fn get_zoneset(&self, zone_name: &str) -> Option<&[ZoneInfo]> {
        if self.zonesets.contains_key(zone_name) {
            Some(&*self.zonesets[zone_name])
        } else if self.links.contains_key(zone_name) {
            let target = &self.links[zone_name];
            Some(&*self.zonesets[target])
        } else {
            None
        }
    }
}

/// An owned rule definition line.
///
/// This mimics the `Rule` struct in the `line` module, only its uses owned
/// Strings instead of string slices, and has had some pre-processing
/// applied to it.
#[derive(PartialEq, Debug)]
pub struct RuleInfo {
    /// The year that this rule *starts* applying.
    pub from_year: Year,

    /// The year that this rule *finishes* applying, inclusive, or `None` if
    /// it applies up until the end of this timespan.
    pub to_year: Option<Year>,

    /// The month it applies on.
    pub month: Month,

    /// The day it applies on.
    pub day: DaySpec,

    /// The exact time it applies on.
    pub time: i64,

    /// The type of time that time is.
    pub time_type: TimeType,

    /// The amount of time to save.
    pub time_to_add: i64,

    /// Any extra letters that should be added to this time zone’s
    /// abbreviation, in place of `%s`.
    pub letters: Option<String>,
}

impl<'line> From<line::Rule<'line>> for RuleInfo {
    fn from(info: line::Rule) -> RuleInfo {
        RuleInfo {
            from_year: info.from_year,
            to_year: info.to_year,
            month: info.month,
            day: info.day,
            time: info.time.0.as_seconds(),
            time_type: info.time.1,
            time_to_add: info.time_to_add.as_seconds(),
            letters: info.letters.map(str::to_owned),
        }
    }
}

impl RuleInfo {
    /// Returns whether this rule is in effect during the given year.
    pub fn applies_to_year(&self, year: i64) -> bool {
        use line::Year::*;

        match (self.from_year, self.to_year) {
            (Number(from), None) => year == from,
            (Number(from), Some(Maximum)) => year >= from,
            (Number(from), Some(Number(to))) => year >= from && year <= to,
            _ => unreachable!(),
        }
    }

    pub fn absolute_datetime(&self, year: i64, utc_offset: i64, dst_offset: i64) -> i64 {
        let offset = match self.time_type {
            TimeType::UTC => 0,
            TimeType::Standard => utc_offset,
            TimeType::Wall => utc_offset + dst_offset,
        };

        let changetime = ChangeTime::UntilDay(Year::Number(year), self.month, self.day);
        changetime.to_timestamp() + self.time - offset
    }
}

/// An owned zone definition line.
///
/// This struct mimics the `ZoneInfo` struct in the `line` module, *not* the
/// `Zone` struct, which is the key name in the map—this is just the value.
///
/// As with `RuleInfo`, this struct uses owned Strings rather than string
/// slices.
#[derive(PartialEq, Debug)]
pub struct ZoneInfo {
    /// The number of seconds that need to be added to UTC to get the
    /// standard time in this zone.
    pub offset: i64,

    /// The name of all the rules that should apply in the time zone, or the
    /// amount of daylight-saving time to add.
    pub saving: Saving,

    /// The format for time zone abbreviations.
    pub format: Format,

    /// The time at which the rules change for this time zone, or `None` if
    /// these rules are in effect until the end of time (!).
    pub end_time: Option<ChangeTime>,
}

impl<'line> From<line::ZoneInfo<'line>> for ZoneInfo {
    fn from(info: line::ZoneInfo) -> ZoneInfo {
        ZoneInfo {
            offset: info.utc_offset.as_seconds(),
            saving: match info.saving {
                line::Saving::NoSaving => Saving::NoSaving,
                line::Saving::Multiple(s) => Saving::Multiple(s.to_owned()),
                line::Saving::OneOff(t) => Saving::OneOff(t.as_seconds()),
            },
            format: Format::new(info.format),
            end_time: info.time,
        }
    }
}

/// The amount of daylight saving time (DST) to apply to this timespan. This
/// is a special type for a certain field in a zone line, which can hold
/// different types of value.
///
/// This is the owned version of the `Saving` type in the `line` module.
#[derive(PartialEq, Debug)]
pub enum Saving {
    /// Just stick to the base offset.
    NoSaving,

    /// This amount of time should be saved while this timespan is in effect.
    /// (This is the equivalent to there being a single one-off rule with the
    /// given amount of time to save).
    OneOff(i64),

    /// All rules with the given name should apply while this timespan is in
    /// effect.
    Multiple(String),
}

/// The format string to generate a time zone abbreviation from.
#[derive(PartialEq, Debug, Clone)]
pub enum Format {
    /// A constant format, which remains the same throughout both standard
    /// and DST timespans.
    Constant(String),

    /// An alternate format, such as “PST/PDT”, which changes between
    /// standard and DST timespans.
    Alternate {
        /// Abbreviation to use during Standard Time.
        standard: String,

        /// Abbreviation to use during Summer Time.
        dst: String,
    },

    /// A format with a placeholder `%s`, which uses the `letters` field in
    /// a `RuleInfo` to generate the time zone abbreviation.
    Placeholder(String),
}

impl Format {
    /// Convert the template into one of the `Format` variants. This can’t
    /// fail, as any syntax that doesn’t match one of the two formats will
    /// just be a ‘constant’ format.
    pub fn new(template: &str) -> Format {
        if let Some(pos) = template.find('/') {
            Format::Alternate {
                standard: template[..pos].to_owned(),
                dst: template[pos + 1..].to_owned(),
            }
        } else if template.contains("%s") {
            Format::Placeholder(template.to_owned())
        } else {
            Format::Constant(template.to_owned())
        }
    }

    pub fn format(&self, dst_offset: i64, letters: Option<&String>) -> String {
        let letters = match letters {
            Some(l) => &**l,
            None => "",
        };

        match *self {
            Format::Constant(ref s) => s.clone(),
            Format::Placeholder(ref s) => s.replace("%s", letters),
            Format::Alternate { ref standard, .. } if dst_offset == 0 => standard.clone(),
            Format::Alternate { ref dst, .. } => dst.clone(),
        }
    }

    pub fn format_constant(&self) -> String {
        if let Format::Constant(ref s) = *self {
            s.clone()
        } else {
            panic!("Expected a constant formatting string");
        }
    }
}

/// A builder for `Table` values based on various line definitions.
#[derive(PartialEq, Debug)]
pub struct TableBuilder {
    /// The table that’s being built up.
    table: Table,

    /// If the last line was a zone definition, then this holds its name.
    /// `None` otherwise. This is so continuation lines can be added to the
    /// same zone as the original zone line.
    current_zoneset_name: Option<String>,
}

impl Default for TableBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl TableBuilder {
    /// Creates a new builder with an empty table.
    pub fn new() -> TableBuilder {
        TableBuilder {
            table: Table::default(),
            current_zoneset_name: None,
        }
    }

    /// Adds a new line describing a zone definition.
    ///
    /// Returns an error if there’s already a zone with the same name, or the
    /// zone refers to a ruleset that hasn’t been defined yet.
    pub fn add_zone_line<'line>(
        &mut self,
        zone_line: line::Zone<'line>,
    ) -> Result<(), Error<'line>> {
        if let line::Saving::Multiple(ruleset_name) = zone_line.info.saving {
            if !self.table.rulesets.contains_key(ruleset_name) {
                return Err(Error::UnknownRuleset(ruleset_name));
            }
        }

        let zoneset = match self.table.zonesets.entry(zone_line.name.to_owned()) {
            Entry::Occupied(_) => return Err(Error::DuplicateZone),
            Entry::Vacant(e) => e.insert(Vec::new()),
        };

        zoneset.push(zone_line.info.into());
        self.current_zoneset_name = Some(zone_line.name.to_owned());
        Ok(())
    }

    /// Adds a new line describing the *continuation* of a zone definition.
    ///
    /// Returns an error if the builder wasn’t expecting a continuation line
    /// (meaning, the previous line wasn’t a zone line)
    pub fn add_continuation_line(
        &mut self,
        continuation_line: line::ZoneInfo,
    ) -> Result<(), Error> {
        let zoneset = match self.current_zoneset_name {
            Some(ref name) => self.table.zonesets.get_mut(name).unwrap(),
            None => return Err(Error::SurpriseContinuationLine),
        };

        zoneset.push(continuation_line.into());
        Ok(())
    }

    /// Adds a new line describing one entry in a ruleset, creating that set
    /// if it didn’t exist already.
    pub fn add_rule_line(&mut self, rule_line: line::Rule) -> Result<(), Error> {
        let ruleset = self
            .table
            .rulesets
            .entry(rule_line.name.to_owned())
            .or_default();

        ruleset.push(rule_line.into());
        self.current_zoneset_name = None;
        Ok(())
    }

    /// Adds a new line linking one zone to another.
    ///
    /// Returns an error if there was already a link with that name.
    pub fn add_link_line<'line>(
        &mut self,
        link_line: line::Link<'line>,
    ) -> Result<(), Error<'line>> {
        match self.table.links.entry(link_line.new.to_owned()) {
            Entry::Occupied(_) => Err(Error::DuplicateLink(link_line.new)),
            Entry::Vacant(e) => {
                let _ = e.insert(link_line.existing.to_owned());
                self.current_zoneset_name = None;
                Ok(())
            }
        }
    }

    /// Returns the table after it’s finished being built.
    pub fn build(self) -> Table {
        self.table
    }
}

/// Something that can go wrong while constructing a `Table`.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum Error<'line> {
    /// A continuation line was passed in, but the previous line wasn’t a zone
    /// definition line.
    SurpriseContinuationLine,

    /// A zone definition referred to a ruleset that hadn’t been defined.
    UnknownRuleset(&'line str),

    /// A link line was passed in, but there’s already a link with that name.
    DuplicateLink(&'line str),

    /// A zone line was passed in, but there’s already a zone with that name.
    DuplicateZone,
}

impl<'line> fmt::Display for Error<'line> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::SurpriseContinuationLine => {
                write!(
                    f,
                    "continuation line follows line that isn't a zone definition line"
                )
            }
            Error::UnknownRuleset(_) => {
                write!(f, "zone definition refers to a ruleset that isn't defined")
            }
            Error::DuplicateLink(_) => write!(f, "link line with name that already exists"),
            Error::DuplicateZone => write!(f, "zone line with name that already exists"),
        }
    }
}

impl<'line> std::error::Error for Error<'line> {}
