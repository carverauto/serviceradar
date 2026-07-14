//! Parsing zoneinfo data files, line-by-line.
//!
//! This module provides functions that take a line of input from a zoneinfo
//! data file and attempts to parse it, returning the details of the line if
//! it gets parsed successfully. It classifies them as `Rule`, `Link`,
//! `Zone`, or `Continuation` lines.
//!
//! `Line` is the type that parses and holds zoneinfo line data. To try to
//! parse a string, use the `Line::from_str` constructor. (This isn’t the
//! `FromStr` trait, so you can’t use `parse` on a string. Sorry!)
//!
//! ## Examples
//!
//! Parsing a `Rule` line:
//!
//! ```
//! use parse_zoneinfo::line::*;
//!
//! let parser = LineParser::default();
//! let line = parser.parse_str("Rule  EU  1977    1980    -   Apr Sun>=1   1:00u  1:00    S");
//!
//! assert_eq!(line, Ok(Line::Rule(Rule {
//!     name:         "EU",
//!     from_year:    Year::Number(1977),
//!     to_year:      Some(Year::Number(1980)),
//!     month:        Month::April,
//!     day:          DaySpec::FirstOnOrAfter(Weekday::Sunday, 1),
//!     time:         TimeSpec::HoursMinutes(1, 0).with_type(TimeType::UTC),
//!     time_to_add:  TimeSpec::HoursMinutes(1, 0),
//!     letters:      Some("S"),
//! })));
//! ```
//!
//! Parsing a `Zone` line:
//!
//! ```
//! use parse_zoneinfo::line::*;
//!
//! let parser = LineParser::default();
//! let line = parser.parse_str("Zone  Australia/Adelaide  9:30  Aus  AC%sT  1971 Oct 31  2:00:00");
//!
//! assert_eq!(line, Ok(Line::Zone(Zone {
//!     name: "Australia/Adelaide",
//!     info: ZoneInfo {
//!         utc_offset:  TimeSpec::HoursMinutes(9, 30),
//!         saving:      Saving::Multiple("Aus"),
//!         format:      "AC%sT",
//!         time:        Some(ChangeTime::UntilTime(
//!                         Year::Number(1971),
//!                         Month::October,
//!                         DaySpec::Ordinal(31),
//!                         TimeSpec::HoursMinutesSeconds(2, 0, 0).with_type(TimeType::Wall))
//!                      ),
//!     },
//! })));
//! ```
//!
//! Parsing a `Link` line:
//!
//! ```
//! use parse_zoneinfo::line::*;
//!
//! let parser = LineParser::default();
//! let line = parser.parse_str("Link  Europe/Istanbul  Asia/Istanbul");
//! assert_eq!(line, Ok(Line::Link(Link {
//!     existing:  "Europe/Istanbul",
//!     new:       "Asia/Istanbul",
//! })));
//! ```

use std::fmt;
use std::str::FromStr;

use regex::{Captures, Regex};

pub struct LineParser {
    rule_line: Regex,
    day_field: Regex,
    hm_field: Regex,
    hms_field: Regex,
    zone_line: Regex,
    continuation_line: Regex,
    link_line: Regex,
    empty_line: Regex,
}

#[derive(PartialEq, Debug, Clone)]
pub enum Error {
    FailedYearParse(String),
    FailedMonthParse(String),
    FailedWeekdayParse(String),
    InvalidLineType(String),
    TypeColumnContainedNonHyphen(String),
    CouldNotParseSaving(String),
    InvalidDaySpec(String),
    InvalidTimeSpecAndType(String),
    NonWallClockInTimeSpec(String),
    NotParsedAsRuleLine,
    NotParsedAsZoneLine,
    NotParsedAsLinkLine,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::FailedYearParse(s) => write!(f, "failed to parse as a year value: \"{}\"", s),
            Error::FailedMonthParse(s) => write!(f, "failed to parse as a month value: \"{}\"", s),
            Error::FailedWeekdayParse(s) => {
                write!(f, "failed to parse as a weekday value: \"{}\"", s)
            }
            Error::InvalidLineType(s) => write!(f, "line with invalid format: \"{}\"", s),
            Error::TypeColumnContainedNonHyphen(s) => {
                write!(
                    f,
                    "'type' column is not a hyphen but has the value: \"{}\"",
                    s
                )
            }
            Error::CouldNotParseSaving(s) => write!(f, "failed to parse RULES column: \"{}\"", s),
            Error::InvalidDaySpec(s) => write!(f, "invalid day specification ('ON'): \"{}\"", s),
            Error::InvalidTimeSpecAndType(s) => write!(f, "invalid time: \"{}\"", s),
            Error::NonWallClockInTimeSpec(s) => {
                write!(f, "time value not given as wall time: \"{}\"", s)
            }
            Error::NotParsedAsRuleLine => write!(f, "failed to parse line as a rule"),
            Error::NotParsedAsZoneLine => write!(f, "failed to parse line as a zone"),
            Error::NotParsedAsLinkLine => write!(f, "failed to parse line as a link"),
        }
    }
}

impl std::error::Error for Error {}

impl Default for LineParser {
    fn default() -> Self {
        LineParser {
            rule_line: Regex::new(
                r##"(?x) ^
                Rule \s+
                ( ?P<name>    \S+)  \s+
                ( ?P<from>    \S+)  \s+
                ( ?P<to>      \S+)  \s+
                ( ?P<type>    \S+)  \s+
                ( ?P<in>      \S+)  \s+
                ( ?P<on>      \S+)  \s+
                ( ?P<at>      \S+)  \s+
                ( ?P<save>    \S+)  \s+
                ( ?P<letters> \S+)  \s*
                (\#.*)?
            $ "##,
            )
            .unwrap(),

            day_field: Regex::new(
                r##"(?x) ^
                ( ?P<weekday> \w+ )
                ( ?P<sign>    [<>] = )
                ( ?P<day>     \d+ )
            $ "##,
            )
            .unwrap(),

            hm_field: Regex::new(
                r##"(?x) ^
                ( ?P<sign> -? )
                ( ?P<hour> \d{1,2} ) : ( ?P<minute> \d{2} )
                ( ?P<flag> [wsugz] )?
            $ "##,
            )
            .unwrap(),

            hms_field: Regex::new(
                r##"(?x) ^
                ( ?P<sign> -? )
                ( ?P<hour> \d{1,2} ) : ( ?P<minute> \d{2} ) : ( ?P<second> \d{2} )
                ( ?P<flag> [wsugz] )?
            $ "##,
            )
            .unwrap(),

            zone_line: Regex::new(
                r##"(?x) ^
                Zone \s+
                ( ?P<name> [A-Za-z0-9/_+-]+ )  \s+
                ( ?P<gmtoff>     \S+ )  \s+
                ( ?P<rulessave>  \S+ )  \s+
                ( ?P<format>     \S+ )  \s*
                ( ?P<year>       [0-9]+)? \s*
                ( ?P<month>      [A-Za-z]+)? \s*
                ( ?P<day>        [A-Za-z0-9><=]+ )? \s*
                ( ?P<time>       [0-9:]+[suwz]? )? \s*
                (\#.*)?
            $ "##,
            )
            .unwrap(),

            continuation_line: Regex::new(
                r##"(?x) ^
                \s+
                ( ?P<gmtoff>     \S+ )  \s+
                ( ?P<rulessave>  \S+ )  \s+
                ( ?P<format>     \S+ )  \s*
                ( ?P<year>       [0-9]+)? \s*
                ( ?P<month>      [A-Za-z]+)? \s*
                ( ?P<day>        [A-Za-z0-9><=]+ )? \s*
                ( ?P<time>       [0-9:]+[suwz]? )? \s*
                (\#.*)?
            $ "##,
            )
            .unwrap(),

            link_line: Regex::new(
                r##"(?x) ^
                Link  \s+
                ( ?P<target>  \S+ )  \s+
                ( ?P<name>    \S+ )  \s*
                (\#.*)?
            $ "##,
            )
            .unwrap(),

            empty_line: Regex::new(
                r##"(?x) ^
                \s*
                (\#.*)?
            $"##,
            )
            .unwrap(),
        }
    }
}

/// A **year** definition field.
///
/// A year has one of the following representations in a file:
///
/// - `min` or `minimum`, the minimum year possible, for when a rule needs to
///   apply up until the first rule with a specific year;
/// - `max` or `maximum`, the maximum year possible, for when a rule needs to
///   apply after the last rule with a specific year;
/// - a year number, referring to a specific year.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum Year {
    /// The minimum year possible: `min` or `minimum`.
    Minimum,
    /// The maximum year possible: `max` or `maximum`.
    Maximum,
    /// A specific year number.
    Number(i64),
}

impl FromStr for Year {
    type Err = Error;

    fn from_str(input: &str) -> Result<Year, Self::Err> {
        Ok(match &*input.to_ascii_lowercase() {
            "min" | "minimum" => Year::Minimum,
            "max" | "maximum" => Year::Maximum,
            year => match year.parse() {
                Ok(year) => Year::Number(year),
                Err(_) => return Err(Error::FailedYearParse(input.to_string())),
            },
        })
    }
}

/// A **month** field, which is actually just a wrapper around
/// `datetime::Month`.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum Month {
    January = 1,
    February = 2,
    March = 3,
    April = 4,
    May = 5,
    June = 6,
    July = 7,
    August = 8,
    September = 9,
    October = 10,
    November = 11,
    December = 12,
}

impl Month {
    fn length(self, is_leap: bool) -> i8 {
        match self {
            Month::January => 31,
            Month::February if is_leap => 29,
            Month::February => 28,
            Month::March => 31,
            Month::April => 30,
            Month::May => 31,
            Month::June => 30,
            Month::July => 31,
            Month::August => 31,
            Month::September => 30,
            Month::October => 31,
            Month::November => 30,
            Month::December => 31,
        }
    }

    /// Get the next calendar month, with an error going from Dec->Jan
    fn next_in_year(self) -> Result<Month, &'static str> {
        Ok(match self {
            Month::January => Month::February,
            Month::February => Month::March,
            Month::March => Month::April,
            Month::April => Month::May,
            Month::May => Month::June,
            Month::June => Month::July,
            Month::July => Month::August,
            Month::August => Month::September,
            Month::September => Month::October,
            Month::October => Month::November,
            Month::November => Month::December,
            Month::December => Err("Cannot wrap year from dec->jan")?,
        })
    }

    /// Get the previous calendar month, with an error going from Jan->Dec
    fn prev_in_year(self) -> Result<Month, &'static str> {
        Ok(match self {
            Month::January => Err("Cannot wrap years from jan->dec")?,
            Month::February => Month::January,
            Month::March => Month::February,
            Month::April => Month::March,
            Month::May => Month::April,
            Month::June => Month::May,
            Month::July => Month::June,
            Month::August => Month::July,
            Month::September => Month::August,
            Month::October => Month::September,
            Month::November => Month::October,
            Month::December => Month::November,
        })
    }
}

impl FromStr for Month {
    type Err = Error;

    /// Attempts to parse the given string into a value of this type.
    fn from_str(input: &str) -> Result<Month, Self::Err> {
        Ok(match &*input.to_ascii_lowercase() {
            "jan" | "january" => Month::January,
            "feb" | "february" => Month::February,
            "mar" | "march" => Month::March,
            "apr" | "april" => Month::April,
            "may" => Month::May,
            "jun" | "june" => Month::June,
            "jul" | "july" => Month::July,
            "aug" | "august" => Month::August,
            "sep" | "september" => Month::September,
            "oct" | "october" => Month::October,
            "nov" | "november" => Month::November,
            "dec" | "december" => Month::December,
            other => return Err(Error::FailedMonthParse(other.to_string())),
        })
    }
}

/// A **weekday** field, which is actually just a wrapper around
/// `datetime::Weekday`.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum Weekday {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
}

impl FromStr for Weekday {
    type Err = Error;

    fn from_str(input: &str) -> Result<Weekday, Self::Err> {
        Ok(match &*input.to_ascii_lowercase() {
            "mon" | "monday" => Weekday::Monday,
            "tue" | "tuesday" => Weekday::Tuesday,
            "wed" | "wednesday" => Weekday::Wednesday,
            "thu" | "thursday" => Weekday::Thursday,
            "fri" | "friday" => Weekday::Friday,
            "sat" | "saturday" => Weekday::Saturday,
            "sun" | "sunday" => Weekday::Sunday,
            other => return Err(Error::FailedWeekdayParse(other.to_string())),
        })
    }
}

/// A **day** definition field.
///
/// This can be given in either absolute terms (such as “the fifth day of the
/// month”), or relative terms (such as “the last Sunday of the month”, or
/// “the last Friday before or including the 13th”).
///
/// Note that in the last example, it’s allowed for that particular Friday to
/// *be* the 13th in question.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum DaySpec {
    /// A specific day of the month, given by its number.
    Ordinal(i8),
    /// The last day of the month with a specific weekday.
    Last(Weekday),
    /// The **last** day with the given weekday **before** (or including) a
    /// day with a specific number.
    LastOnOrBefore(Weekday, i8),
    /// The **first** day with the given weekday **after** (or including) a
    /// day with a specific number.
    FirstOnOrAfter(Weekday, i8),
}

impl Weekday {
    fn calculate(year: i64, month: Month, day: i8) -> Weekday {
        let m = month as i64;
        let y = if m < 3 { year - 1 } else { year };
        let d = day as i64;
        const T: [i64; 12] = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
        match (y + y / 4 - y / 100 + y / 400 + T[m as usize - 1] + d) % 7 {
            0 => Weekday::Sunday,
            1 => Weekday::Monday,
            2 => Weekday::Tuesday,
            3 => Weekday::Wednesday,
            4 => Weekday::Thursday,
            5 => Weekday::Friday,
            6 => Weekday::Saturday,
            _ => panic!("why is negative modulus designed so?"),
        }
    }
}

#[cfg(test)]
#[test]
fn weekdays() {
    assert_eq!(
        Weekday::calculate(1970, Month::January, 1),
        Weekday::Thursday
    );
    assert_eq!(
        Weekday::calculate(2017, Month::February, 11),
        Weekday::Saturday
    );
    assert_eq!(Weekday::calculate(1890, Month::March, 2), Weekday::Sunday);
    assert_eq!(Weekday::calculate(2100, Month::April, 20), Weekday::Tuesday);
    assert_eq!(Weekday::calculate(2009, Month::May, 31), Weekday::Sunday);
    assert_eq!(Weekday::calculate(2001, Month::June, 9), Weekday::Saturday);
    assert_eq!(Weekday::calculate(1995, Month::July, 21), Weekday::Friday);
    assert_eq!(Weekday::calculate(1982, Month::August, 8), Weekday::Sunday);
    assert_eq!(
        Weekday::calculate(1962, Month::September, 6),
        Weekday::Thursday
    );
    assert_eq!(
        Weekday::calculate(1899, Month::October, 14),
        Weekday::Saturday
    );
    assert_eq!(
        Weekday::calculate(2016, Month::November, 18),
        Weekday::Friday
    );
    assert_eq!(
        Weekday::calculate(2010, Month::December, 19),
        Weekday::Sunday
    );
    assert_eq!(
        Weekday::calculate(2016, Month::February, 29),
        Weekday::Monday
    );
}

fn is_leap(year: i64) -> bool {
    // Leap year rules: years which are factors of 4, except those divisible
    // by 100, unless they are divisible by 400.
    //
    // We test most common cases first: 4th year, 100th year, then 400th year.
    //
    // We factor out 4 from 100 since it was already tested, leaving us checking
    // if it's divisible by 25. Afterwards, we do the same, factoring 25 from
    // 400, leaving us with 16.
    //
    // Factors of 4 and 16 can quickly be found with bitwise AND.
    year & 3 == 0 && (year % 25 != 0 || year & 15 == 0)
}

#[cfg(test)]
#[test]
fn leap_years() {
    assert!(!is_leap(1900));
    assert!(is_leap(1904));
    assert!(is_leap(1964));
    assert!(is_leap(1996));
    assert!(!is_leap(1997));
    assert!(!is_leap(1997));
    assert!(!is_leap(1999));
    assert!(is_leap(2000));
    assert!(is_leap(2016));
    assert!(!is_leap(2100));
}

impl DaySpec {
    /// Converts this day specification to a concrete date, given the year and
    /// month it should occur in.
    pub fn to_concrete_day(&self, year: i64, month: Month) -> (Month, i8) {
        let leap = is_leap(year);
        let length = month.length(leap);
        // we will never hit the 0 because we unwrap prev_in_year below
        let prev_length = month.prev_in_year().map(|m| m.length(leap)).unwrap_or(0);

        match *self {
            DaySpec::Ordinal(day) => (month, day),
            DaySpec::Last(weekday) => (
                month,
                (1..length + 1)
                    .rev()
                    .find(|&day| Weekday::calculate(year, month, day) == weekday)
                    .unwrap(),
            ),
            DaySpec::LastOnOrBefore(weekday, day) => (-7..day + 1)
                .rev()
                .flat_map(|inner_day| {
                    if inner_day >= 1 && Weekday::calculate(year, month, inner_day) == weekday {
                        Some((month, inner_day))
                    } else if inner_day < 1
                        && Weekday::calculate(
                            year,
                            month.prev_in_year().unwrap(),
                            prev_length + inner_day,
                        ) == weekday
                    {
                        // inner_day is negative, so this is subtraction
                        Some((month.prev_in_year().unwrap(), prev_length + inner_day))
                    } else {
                        None
                    }
                })
                .next()
                .unwrap(),
            DaySpec::FirstOnOrAfter(weekday, day) => (day..day + 8)
                .flat_map(|inner_day| {
                    if inner_day <= length && Weekday::calculate(year, month, inner_day) == weekday
                    {
                        Some((month, inner_day))
                    } else if inner_day > length
                        && Weekday::calculate(
                            year,
                            month.next_in_year().unwrap(),
                            inner_day - length,
                        ) == weekday
                    {
                        Some((month.next_in_year().unwrap(), inner_day - length))
                    } else {
                        None
                    }
                })
                .next()
                .unwrap(),
        }
    }
}

/// A **time** definition field.
///
/// A time must have an hours component, with optional minutes and seconds
/// components. It can also be negative with a starting ‘-’.
///
/// Hour 0 is midnight at the start of the day, and Hour 24 is midnight at the
/// end of the day.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum TimeSpec {
    /// A number of hours.
    Hours(i8),
    /// A number of hours and minutes.
    HoursMinutes(i8, i8),
    /// A number of hours, minutes, and seconds.
    HoursMinutesSeconds(i8, i8, i8),
    /// Zero, or midnight at the start of the day.
    Zero,
}

impl TimeSpec {
    /// Returns the number of seconds past midnight that this time spec
    /// represents.
    pub fn as_seconds(self) -> i64 {
        match self {
            TimeSpec::Hours(h) => h as i64 * 60 * 60,
            TimeSpec::HoursMinutes(h, m) => h as i64 * 60 * 60 + m as i64 * 60,
            TimeSpec::HoursMinutesSeconds(h, m, s) => h as i64 * 60 * 60 + m as i64 * 60 + s as i64,
            TimeSpec::Zero => 0,
        }
    }
}

#[derive(PartialEq, Debug, Copy, Clone)]
pub enum TimeType {
    Wall,
    Standard,
    UTC,
}

#[derive(PartialEq, Debug, Copy, Clone)]
pub struct TimeSpecAndType(pub TimeSpec, pub TimeType);

impl TimeSpec {
    pub fn with_type(self, timetype: TimeType) -> TimeSpecAndType {
        TimeSpecAndType(self, timetype)
    }
}

/// The time at which the rules change for a location.
///
/// This is described with as few units as possible: a change that occurs at
/// the beginning of the year lists only the year, a change that occurs on a
/// particular day has to list the year, month, and day, and one that occurs
/// at a particular second has to list everything.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum ChangeTime {
    /// The earliest point in a particular **year**.
    UntilYear(Year),
    /// The earliest point in a particular **month**.
    UntilMonth(Year, Month),
    /// The earliest point in a particular **day**.
    UntilDay(Year, Month, DaySpec),
    /// The earliest point in a particular **hour, minute, or second**.
    UntilTime(Year, Month, DaySpec, TimeSpecAndType),
}

impl ChangeTime {
    /// Convert this change time to an absolute timestamp, as the number of
    /// seconds since the Unix epoch that the change occurs at.
    pub fn to_timestamp(&self) -> i64 {
        fn seconds_in_year(year: i64) -> i64 {
            if is_leap(year) {
                366 * 24 * 60 * 60
            } else {
                365 * 24 * 60 * 60
            }
        }

        fn seconds_until_start_of_year(year: i64) -> i64 {
            if year >= 1970 {
                (1970..year).map(seconds_in_year).sum()
            } else {
                -(year..1970).map(seconds_in_year).sum::<i64>()
            }
        }

        fn time_to_timestamp(
            year: i64,
            month: i8,
            day: i8,
            hour: i8,
            minute: i8,
            second: i8,
        ) -> i64 {
            const MONTHS_NON_LEAP: [i64; 12] = [
                0,
                31,
                31 + 28,
                31 + 28 + 31,
                31 + 28 + 31 + 30,
                31 + 28 + 31 + 30 + 31,
                31 + 28 + 31 + 30 + 31 + 30,
                31 + 28 + 31 + 30 + 31 + 30 + 31,
                31 + 28 + 31 + 30 + 31 + 30 + 31 + 31,
                31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
                31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
                31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30,
            ];
            const MONTHS_LEAP: [i64; 12] = [
                0,
                31,
                31 + 29,
                31 + 29 + 31,
                31 + 29 + 31 + 30,
                31 + 29 + 31 + 30 + 31,
                31 + 29 + 31 + 30 + 31 + 30,
                31 + 29 + 31 + 30 + 31 + 30 + 31,
                31 + 29 + 31 + 30 + 31 + 30 + 31 + 31,
                31 + 29 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
                31 + 29 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
                31 + 29 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30,
            ];
            seconds_until_start_of_year(year)
                + 60 * 60
                    * 24
                    * if is_leap(year) {
                        MONTHS_LEAP[month as usize - 1]
                    } else {
                        MONTHS_NON_LEAP[month as usize - 1]
                    }
                + 60 * 60 * 24 * (day as i64 - 1)
                + 60 * 60 * hour as i64
                + 60 * minute as i64
                + second as i64
        }

        match *self {
            ChangeTime::UntilYear(Year::Number(y)) => time_to_timestamp(y, 1, 1, 0, 0, 0),
            ChangeTime::UntilMonth(Year::Number(y), m) => time_to_timestamp(y, m as i8, 1, 0, 0, 0),
            ChangeTime::UntilDay(Year::Number(y), m, d) => {
                let (m, wd) = d.to_concrete_day(y, m);
                time_to_timestamp(y, m as i8, wd, 0, 0, 0)
            }
            ChangeTime::UntilTime(Year::Number(y), m, d, time) => match time.0 {
                TimeSpec::Zero => {
                    let (m, wd) = d.to_concrete_day(y, m);
                    time_to_timestamp(y, m as i8, wd, 0, 0, 0)
                }
                TimeSpec::Hours(h) => {
                    let (m, wd) = d.to_concrete_day(y, m);
                    time_to_timestamp(y, m as i8, wd, h, 0, 0)
                }
                TimeSpec::HoursMinutes(h, min) => {
                    let (m, wd) = d.to_concrete_day(y, m);
                    time_to_timestamp(y, m as i8, wd, h, min, 0)
                }
                TimeSpec::HoursMinutesSeconds(h, min, s) => {
                    let (m, wd) = d.to_concrete_day(y, m);
                    time_to_timestamp(y, m as i8, wd, h, min, s)
                }
            },
            _ => unreachable!(),
        }
    }

    pub fn year(&self) -> i64 {
        match *self {
            ChangeTime::UntilYear(Year::Number(y)) => y,
            ChangeTime::UntilMonth(Year::Number(y), ..) => y,
            ChangeTime::UntilDay(Year::Number(y), ..) => y,
            ChangeTime::UntilTime(Year::Number(y), ..) => y,
            _ => unreachable!(),
        }
    }
}

/// The information contained in both zone lines *and* zone continuation lines.
#[derive(PartialEq, Debug, Copy, Clone)]
pub struct ZoneInfo<'a> {
    /// The amount of time that needs to be added to UTC to get the standard
    /// time in this zone.
    pub utc_offset: TimeSpec,
    /// The name of all the rules that should apply in the time zone, or the
    /// amount of time to add.
    pub saving: Saving<'a>,
    /// The format for time zone abbreviations, with `%s` as the string marker.
    pub format: &'a str,
    /// The time at which the rules change for this location, or `None` if
    /// these rules are in effect until the end of time (!).
    pub time: Option<ChangeTime>,
}

/// The amount of daylight saving time (DST) to apply to this timespan. This
/// is a special type for a certain field in a zone line, which can hold
/// different types of value.
#[derive(PartialEq, Debug, Copy, Clone)]
pub enum Saving<'a> {
    /// Just stick to the base offset.
    NoSaving,
    /// This amount of time should be saved while this timespan is in effect.
    /// (This is the equivalent to there being a single one-off rule with the
    /// given amount of time to save).
    OneOff(TimeSpec),
    /// All rules with the given name should apply while this timespan is in
    /// effect.
    Multiple(&'a str),
}

/// A **rule** definition line.
///
/// According to the `zic(8)` man page, a rule line has this form, along with
/// an example:
///
/// ```text
///     Rule  NAME  FROM  TO    TYPE  IN   ON       AT    SAVE  LETTER/S
///     Rule  US    1967  1973  ‐     Apr  lastSun  2:00  1:00  D
/// ```
///
/// Apart from the opening `Rule` to specify which kind of line this is, and
/// the `type` column, every column in the line has a field in this struct.
#[derive(PartialEq, Debug, Copy, Clone)]
pub struct Rule<'a> {
    /// The name of the set of rules that this rule is part of.
    pub name: &'a str,
    /// The first year in which the rule applies.
    pub from_year: Year,
    /// The final year, or `None` if’s ‘only’.
    pub to_year: Option<Year>,
    /// The month in which the rule takes effect.
    pub month: Month,
    /// The day on which the rule takes effect.
    pub day: DaySpec,
    /// The time of day at which the rule takes effect.
    pub time: TimeSpecAndType,
    /// The amount of time to be added when the rule is in effect.
    pub time_to_add: TimeSpec,
    /// The variable part of time zone abbreviations to be used when this rule
    /// is in effect, if any.
    pub letters: Option<&'a str>,
}

/// A **zone** definition line.
///
/// According to the `zic(8)` man page, a zone line has this form, along with
/// an example:
///
/// ```text
///     Zone  NAME                GMTOFF  RULES/SAVE  FORMAT  [UNTILYEAR [MONTH [DAY [TIME]]]]
///     Zone  Australia/Adelaide  9:30    Aus         AC%sT   1971       Oct    31   2:00
/// ```
///
/// The opening `Zone` identifier is ignored, and the last four columns are
/// all optional, with their variants consolidated into a `ChangeTime`.
///
/// The `Rules/Save` column, if it contains a value, *either* contains the
/// name of the rules to use for this zone, *or* contains a one-off period of
/// time to save.
///
/// A continuation rule line contains all the same fields apart from the
/// `Name` column and the opening `Zone` identifier.
#[derive(PartialEq, Debug, Copy, Clone)]
pub struct Zone<'a> {
    /// The name of the time zone.
    pub name: &'a str,
    /// All the other fields of info.
    pub info: ZoneInfo<'a>,
}

#[derive(PartialEq, Debug, Copy, Clone)]
pub struct Link<'a> {
    pub existing: &'a str,
    pub new: &'a str,
}

#[derive(PartialEq, Debug, Copy, Clone)]
pub enum Line<'a> {
    /// This line is empty.
    Space,
    /// This line contains a **zone** definition.
    Zone(Zone<'a>),
    /// This line contains a **continuation** of a zone definition.
    Continuation(ZoneInfo<'a>),
    /// This line contains a **rule** definition.
    Rule(Rule<'a>),
    /// This line contains a **link** definition.
    Link(Link<'a>),
}

fn parse_time_type(c: &str) -> Option<TimeType> {
    Some(match c {
        "w" => TimeType::Wall,
        "s" => TimeType::Standard,
        "u" | "g" | "z" => TimeType::UTC,
        _ => return None,
    })
}

impl LineParser {
    #[deprecated]
    pub fn new() -> Self {
        Self::default()
    }

    fn parse_timespec_and_type(&self, input: &str) -> Result<TimeSpecAndType, Error> {
        if input == "-" {
            Ok(TimeSpecAndType(TimeSpec::Zero, TimeType::Wall))
        } else if input.chars().all(|c| c == '-' || c.is_ascii_digit()) {
            Ok(TimeSpecAndType(
                TimeSpec::Hours(input.parse().unwrap()),
                TimeType::Wall,
            ))
        } else if let Some(caps) = self.hm_field.captures(input) {
            let sign: i8 = if caps.name("sign").unwrap().as_str() == "-" {
                -1
            } else {
                1
            };
            let hour: i8 = caps.name("hour").unwrap().as_str().parse().unwrap();
            let minute: i8 = caps.name("minute").unwrap().as_str().parse().unwrap();
            let flag = caps
                .name("flag")
                .and_then(|c| parse_time_type(&c.as_str()[0..1]))
                .unwrap_or(TimeType::Wall);

            Ok(TimeSpecAndType(
                TimeSpec::HoursMinutes(hour * sign, minute * sign),
                flag,
            ))
        } else if let Some(caps) = self.hms_field.captures(input) {
            let sign: i8 = if caps.name("sign").unwrap().as_str() == "-" {
                -1
            } else {
                1
            };
            let hour: i8 = caps.name("hour").unwrap().as_str().parse().unwrap();
            let minute: i8 = caps.name("minute").unwrap().as_str().parse().unwrap();
            let second: i8 = caps.name("second").unwrap().as_str().parse().unwrap();
            let flag = caps
                .name("flag")
                .and_then(|c| parse_time_type(&c.as_str()[0..1]))
                .unwrap_or(TimeType::Wall);

            Ok(TimeSpecAndType(
                TimeSpec::HoursMinutesSeconds(hour * sign, minute * sign, second * sign),
                flag,
            ))
        } else {
            Err(Error::InvalidTimeSpecAndType(input.to_string()))
        }
    }

    fn parse_timespec(&self, input: &str) -> Result<TimeSpec, Error> {
        match self.parse_timespec_and_type(input) {
            Ok(TimeSpecAndType(spec, TimeType::Wall)) => Ok(spec),
            Ok(TimeSpecAndType(_, _)) => Err(Error::NonWallClockInTimeSpec(input.to_string())),
            Err(e) => Err(e),
        }
    }

    fn parse_dayspec(&self, input: &str) -> Result<DaySpec, Error> {
        // Parse the field as a number if it vaguely resembles one.
        if input.chars().all(|c| c.is_ascii_digit()) {
            Ok(DaySpec::Ordinal(input.parse().unwrap()))
        }
        // Check if it stars with ‘last’, and trim off the first four bytes if
        // it does. (Luckily, the file is ASCII, so ‘last’ is four bytes)
        else if let Some(remainder) = input.strip_prefix("last") {
            let weekday = remainder.parse()?;
            Ok(DaySpec::Last(weekday))
        }
        // Check if it’s a relative expression with the regex.
        else if let Some(caps) = self.day_field.captures(input) {
            let weekday = caps.name("weekday").unwrap().as_str().parse().unwrap();
            let day = caps.name("day").unwrap().as_str().parse().unwrap();

            match caps.name("sign").unwrap().as_str() {
                "<=" => Ok(DaySpec::LastOnOrBefore(weekday, day)),
                ">=" => Ok(DaySpec::FirstOnOrAfter(weekday, day)),
                _ => unreachable!("The regex only matches one of those two!"),
            }
        }
        // Otherwise, give up.
        else {
            Err(Error::InvalidDaySpec(input.to_string()))
        }
    }

    fn parse_rule<'a>(&self, input: &'a str) -> Result<Rule<'a>, Error> {
        if let Some(caps) = self.rule_line.captures(input) {
            let name = caps.name("name").unwrap().as_str();

            let from_year = caps.name("from").unwrap().as_str().parse()?;

            // The end year can be ‘only’ to indicate that this rule only
            // takes place on that year.
            let to_year = match caps.name("to").unwrap().as_str() {
                "only" => None,
                to => Some(to.parse()?),
            };

            // According to the spec, the only value inside the ‘type’ column
            // should be “-”, so throw an error if it isn’t. (It only exists
            // for compatibility with old versions that used to contain year
            // types.) Sometimes “‐”, a Unicode hyphen, is used as well.
            let t = caps.name("type").unwrap().as_str();
            if t != "-" && t != "\u{2010}" {
                return Err(Error::TypeColumnContainedNonHyphen(t.to_string()));
            }

            let month = caps.name("in").unwrap().as_str().parse()?;
            let day = self.parse_dayspec(caps.name("on").unwrap().as_str())?;
            let time = self.parse_timespec_and_type(caps.name("at").unwrap().as_str())?;
            let time_to_add = self.parse_timespec(caps.name("save").unwrap().as_str())?;
            let letters = match caps.name("letters").unwrap().as_str() {
                "-" => None,
                l => Some(l),
            };

            Ok(Rule {
                name,
                from_year,
                to_year,
                month,
                day,
                time,
                time_to_add,
                letters,
            })
        } else {
            Err(Error::NotParsedAsRuleLine)
        }
    }

    fn saving_from_str<'a>(&self, input: &'a str) -> Result<Saving<'a>, Error> {
        if input == "-" {
            Ok(Saving::NoSaving)
        } else if input
            .chars()
            .all(|c| c == '-' || c == '_' || c.is_alphabetic())
        {
            Ok(Saving::Multiple(input))
        } else if self.hm_field.is_match(input) {
            let time = self.parse_timespec(input)?;
            Ok(Saving::OneOff(time))
        } else {
            Err(Error::CouldNotParseSaving(input.to_string()))
        }
    }

    fn zoneinfo_from_captures<'a>(&self, caps: Captures<'a>) -> Result<ZoneInfo<'a>, Error> {
        let utc_offset = self.parse_timespec(caps.name("gmtoff").unwrap().as_str())?;
        let saving = self.saving_from_str(caps.name("rulessave").unwrap().as_str())?;
        let format = caps.name("format").unwrap().as_str();

        // The year, month, day, and time fields are all optional, meaning
        // that it should be impossible to, say, have a defined month but not
        // a defined year.
        let time = match (
            caps.name("year"),
            caps.name("month"),
            caps.name("day"),
            caps.name("time"),
        ) {
            (Some(y), Some(m), Some(d), Some(t)) => Some(ChangeTime::UntilTime(
                y.as_str().parse()?,
                m.as_str().parse()?,
                self.parse_dayspec(d.as_str())?,
                self.parse_timespec_and_type(t.as_str())?,
            )),
            (Some(y), Some(m), Some(d), _) => Some(ChangeTime::UntilDay(
                y.as_str().parse()?,
                m.as_str().parse()?,
                self.parse_dayspec(d.as_str())?,
            )),
            (Some(y), Some(m), _, _) => Some(ChangeTime::UntilMonth(
                y.as_str().parse()?,
                m.as_str().parse()?,
            )),
            (Some(y), _, _, _) => Some(ChangeTime::UntilYear(y.as_str().parse()?)),
            (None, None, None, None) => None,
            _ => unreachable!("Out-of-order capturing groups!"),
        };

        Ok(ZoneInfo {
            utc_offset,
            saving,
            format,
            time,
        })
    }

    fn parse_zone<'a>(&self, input: &'a str) -> Result<Zone<'a>, Error> {
        if let Some(caps) = self.zone_line.captures(input) {
            let name = caps.name("name").unwrap().as_str();
            let info = self.zoneinfo_from_captures(caps)?;
            Ok(Zone { name, info })
        } else {
            Err(Error::NotParsedAsZoneLine)
        }
    }

    fn parse_link<'a>(&self, input: &'a str) -> Result<Link<'a>, Error> {
        if let Some(caps) = self.link_line.captures(input) {
            let target = caps.name("target").unwrap().as_str();
            let name = caps.name("name").unwrap().as_str();
            Ok(Link {
                existing: target,
                new: name,
            })
        } else {
            Err(Error::NotParsedAsLinkLine)
        }
    }

    /// Attempt to parse this line, returning a `Line` depending on what
    /// type of line it was, or an `Error` if it couldn't be parsed.
    pub fn parse_str<'a>(&self, input: &'a str) -> Result<Line<'a>, Error> {
        if self.empty_line.is_match(input) {
            return Ok(Line::Space);
        }

        match self.parse_zone(input) {
            Err(Error::NotParsedAsZoneLine) => {}
            result => return result.map(Line::Zone),
        }

        match self.continuation_line.captures(input) {
            None => {}
            Some(caps) => return self.zoneinfo_from_captures(caps).map(Line::Continuation),
        }

        match self.parse_rule(input) {
            Err(Error::NotParsedAsRuleLine) => {}
            result => return result.map(Line::Rule),
        }

        match self.parse_link(input) {
            Err(Error::NotParsedAsLinkLine) => {}
            result => return result.map(Line::Link),
        }

        Err(Error::InvalidLineType(input.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn last_monday() {
        let dayspec = DaySpec::Last(Weekday::Monday);
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::January),
            (Month::January, 25)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::February),
            (Month::February, 29)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::March),
            (Month::March, 28)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::April),
            (Month::April, 25)
        );
        assert_eq!(dayspec.to_concrete_day(2016, Month::May), (Month::May, 30));
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::June),
            (Month::June, 27)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::July),
            (Month::July, 25)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::August),
            (Month::August, 29)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::September),
            (Month::September, 26)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::October),
            (Month::October, 31)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::November),
            (Month::November, 28)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::December),
            (Month::December, 26)
        );
    }

    #[test]
    fn first_monday_on_or_after() {
        let dayspec = DaySpec::FirstOnOrAfter(Weekday::Monday, 20);
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::January),
            (Month::January, 25)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::February),
            (Month::February, 22)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::March),
            (Month::March, 21)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::April),
            (Month::April, 25)
        );
        assert_eq!(dayspec.to_concrete_day(2016, Month::May), (Month::May, 23));
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::June),
            (Month::June, 20)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::July),
            (Month::July, 25)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::August),
            (Month::August, 22)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::September),
            (Month::September, 26)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::October),
            (Month::October, 24)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::November),
            (Month::November, 21)
        );
        assert_eq!(
            dayspec.to_concrete_day(2016, Month::December),
            (Month::December, 26)
        );
    }

    // A couple of specific timezone transitions that we care about
    #[test]
    fn first_sunday_in_toronto() {
        let dayspec = DaySpec::FirstOnOrAfter(Weekday::Sunday, 25);
        assert_eq!(dayspec.to_concrete_day(1932, Month::April), (Month::May, 1));
        // asia/zion
        let dayspec = DaySpec::LastOnOrBefore(Weekday::Friday, 1);
        assert_eq!(
            dayspec.to_concrete_day(2012, Month::April),
            (Month::March, 30)
        );
    }

    #[test]
    fn to_timestamp() {
        let time = ChangeTime::UntilYear(Year::Number(1970));
        assert_eq!(time.to_timestamp(), 0);
        let time = ChangeTime::UntilYear(Year::Number(2016));
        assert_eq!(time.to_timestamp(), 1451606400);
        let time = ChangeTime::UntilYear(Year::Number(1900));
        assert_eq!(time.to_timestamp(), -2208988800);
        let time = ChangeTime::UntilTime(
            Year::Number(2000),
            Month::February,
            DaySpec::Last(Weekday::Sunday),
            TimeSpecAndType(TimeSpec::Hours(9), TimeType::Wall),
        );
        assert_eq!(time.to_timestamp(), 951642000);
    }

    macro_rules! test {
        ($name:ident: $input:expr => $result:expr) => {
            #[test]
            fn $name() {
                let parser = LineParser::default();
                assert_eq!(parser.parse_str($input), $result);
            }
        };
    }

    test!(empty:    ""          => Ok(Line::Space));
    test!(spaces:   "        "  => Ok(Line::Space));

    test!(rule_1: "Rule  US    1967  1973  ‐     Apr  lastSun  2:00  1:00  D" => Ok(Line::Rule(Rule {
        name:         "US",
        from_year:    Year::Number(1967),
        to_year:      Some(Year::Number(1973)),
        month:        Month::April,
        day:          DaySpec::Last(Weekday::Sunday),
        time:         TimeSpec::HoursMinutes(2, 0).with_type(TimeType::Wall),
        time_to_add:  TimeSpec::HoursMinutes(1, 0),
        letters:      Some("D"),
    })));

    test!(rule_2: "Rule	Greece	1976	only	-	Oct	10	2:00s	0	-" => Ok(Line::Rule(Rule {
        name:         "Greece",
        from_year:    Year::Number(1976),
        to_year:      None,
        month:        Month::October,
        day:          DaySpec::Ordinal(10),
        time:         TimeSpec::HoursMinutes(2, 0).with_type(TimeType::Standard),
        time_to_add:  TimeSpec::Hours(0),
        letters:      None,
    })));

    test!(rule_3: "Rule	EU	1977	1980	-	Apr	Sun>=1	 1:00u	1:00	S" => Ok(Line::Rule(Rule {
        name:         "EU",
        from_year:    Year::Number(1977),
        to_year:      Some(Year::Number(1980)),
        month:        Month::April,
        day:          DaySpec::FirstOnOrAfter(Weekday::Sunday, 1),
        time:         TimeSpec::HoursMinutes(1, 0).with_type(TimeType::UTC),
        time_to_add:  TimeSpec::HoursMinutes(1, 0),
        letters:      Some("S"),
    })));

    test!(no_hyphen: "Rule	EU	1977	1980	HEY	Apr	Sun>=1	 1:00u	1:00	S"         => Err(Error::TypeColumnContainedNonHyphen("HEY".to_string())));
    test!(bad_month: "Rule	EU	1977	1980	-	Febtober	Sun>=1	 1:00u	1:00	S" => Err(Error::FailedMonthParse("febtober".to_string())));

    test!(zone: "Zone  Australia/Adelaide  9:30    Aus         AC%sT   1971 Oct 31  2:00:00" => Ok(Line::Zone(Zone {
        name: "Australia/Adelaide",
        info: ZoneInfo {
            utc_offset:  TimeSpec::HoursMinutes(9, 30),
            saving:      Saving::Multiple("Aus"),
            format:      "AC%sT",
            time:        Some(ChangeTime::UntilTime(Year::Number(1971), Month::October, DaySpec::Ordinal(31), TimeSpec::HoursMinutesSeconds(2, 0, 0).with_type(TimeType::Wall))),
        },
    })));

    test!(continuation_1: "                          9:30    Aus         AC%sT   1971 Oct 31  2:00:00" => Ok(Line::Continuation(ZoneInfo {
        utc_offset:  TimeSpec::HoursMinutes(9, 30),
        saving:      Saving::Multiple("Aus"),
        format:      "AC%sT",
        time:        Some(ChangeTime::UntilTime(Year::Number(1971), Month::October, DaySpec::Ordinal(31), TimeSpec::HoursMinutesSeconds(2, 0, 0).with_type(TimeType::Wall))),
    })));

    test!(continuation_2: "			1:00	C-Eur	CE%sT	1943 Oct 25" => Ok(Line::Continuation(ZoneInfo {
        utc_offset:  TimeSpec::HoursMinutes(1, 00),
        saving:      Saving::Multiple("C-Eur"),
        format:      "CE%sT",
        time:        Some(ChangeTime::UntilDay(Year::Number(1943), Month::October, DaySpec::Ordinal(25))),
    })));

    test!(zone_hyphen: "Zone Asia/Ust-Nera\t 9:32:54 -\tLMT\t1919" => Ok(Line::Zone(Zone {
        name: "Asia/Ust-Nera",
        info: ZoneInfo {
            utc_offset:  TimeSpec::HoursMinutesSeconds(9, 32, 54),
            saving:      Saving::NoSaving,
            format:      "LMT",
            time:        Some(ChangeTime::UntilYear(Year::Number(1919))),
        },
    })));

    #[test]
    fn negative_offsets() {
        static LINE: &str = "Zone    Europe/London   -0:01:15 -  LMT 1847 Dec  1  0:00s";
        let parser = LineParser::default();
        let zone = parser.parse_zone(LINE).unwrap();
        assert_eq!(
            zone.info.utc_offset,
            TimeSpec::HoursMinutesSeconds(0, -1, -15)
        );
    }

    #[test]
    fn negative_offsets_2() {
        static LINE: &str =
            "Zone        Europe/Madrid   -0:14:44 -      LMT     1901 Jan  1  0:00s";
        let parser = LineParser::default();
        let zone = parser.parse_zone(LINE).unwrap();
        assert_eq!(
            zone.info.utc_offset,
            TimeSpec::HoursMinutesSeconds(0, -14, -44)
        );
    }

    #[test]
    fn negative_offsets_3() {
        static LINE: &str = "Zone America/Danmarkshavn -1:14:40 -    LMT 1916 Jul 28";
        let parser = LineParser::default();
        let zone = parser.parse_zone(LINE).unwrap();
        assert_eq!(
            zone.info.utc_offset,
            TimeSpec::HoursMinutesSeconds(-1, -14, -40)
        );
    }

    test!(link: "Link  Europe/Istanbul  Asia/Istanbul" => Ok(Line::Link(Link {
        existing:  "Europe/Istanbul",
        new:       "Asia/Istanbul",
    })));

    #[test]
    fn month() {
        assert_eq!(Month::from_str("Aug"), Ok(Month::August));
        assert_eq!(Month::from_str("December"), Ok(Month::December));
    }

    test!(golb: "GOLB" => Err(Error::InvalidLineType("GOLB".to_string())));

    test!(comment: "# this is a comment" => Ok(Line::Space));
    test!(another_comment: "     # so is this" => Ok(Line::Space));
    test!(multiple_hash: "     # so is this ## " => Ok(Line::Space));
    test!(non_comment: " this is not a # comment" => Err(Error::InvalidTimeSpecAndType("this".to_string())));

    test!(comment_after: "Link  Europe/Istanbul  Asia/Istanbul #with a comment after" => Ok(Line::Link(Link {
        existing:  "Europe/Istanbul",
        new:       "Asia/Istanbul",
    })));

    test!(two_comments_after: "Link  Europe/Istanbul  Asia/Istanbul   # comment ## comment" => Ok(Line::Link(Link {
        existing:  "Europe/Istanbul",
        new:       "Asia/Istanbul",
    })));
}
