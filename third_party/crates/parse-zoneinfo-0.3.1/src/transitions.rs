//! Generating timespan sets from a built Table.
//!
//! Once a table has been fully built, it needs to be turned into several
//! *fixed timespan sets*: a series of spans of time where the local time
//! offset remains the same throughout. One set is generated for each named
//! time zone. These timespan sets can then be iterated over to produce
//! *transitions*: when the local time changes from one offset to another.
//!
//! These sets are returned as `FixedTimespanSet` values, rather than
//! iterators, because the generation logic does not output the timespans
//! in any particular order, meaning they need to be sorted before they’re
//! returned—so we may as well just return the vector, rather than an
//! iterator over the vector.
//!
//! Similarly, there is a fixed set of years that is iterated over
//! (currently 1800..2100), rather than having an iterator that produces
//! timespans indefinitely. Not only do we need a complete set of timespans
//! for sorting, but it is not necessarily advisable to rely on offset
//! changes so far into the future!
//!
//! ### Example
//!
//! The complete definition of the `Indian/Mauritius` time zone, as
//! specified in the `africa` file in my version of the tz database, has
//! two Zone definitions, one of which refers to four Rule definitions:
//!
//! ```tz
//! # Rule      NAME    FROM    TO      TYPE    IN      ON      AT      SAVE    LETTER/S
//! Rule Mauritius      1982    only    -       Oct     10      0:00    1:00    S
//! Rule Mauritius      1983    only    -       Mar     21      0:00    0       -
//! Rule Mauritius      2008    only    -       Oct     lastSun 2:00    1:00    S
//! Rule Mauritius      2009    only    -       Mar     lastSun 2:00    0       -
//!
//! # Zone      NAME            GMTOFF  RULES   FORMAT  [UNTIL]
//! Zone Indian/Mauritius       3:50:00 -       LMT     1907   # Port Louis
//!                             4:00 Mauritius  MU%sT          # Mauritius Time
//! ```
//!
//! To generate a fixed timespan set for this timezone, we examine each of the
//! Zone definitions, generating at least one timespan for each definition.
//!
//! * The first timespan describes the *local mean time* (LMT) in Mauritius,
//!   calculated by the geographical position of Port Louis, its capital.
//!   Although it’s common to have a timespan set begin with a city’s local mean
//!   time, it is by no means necessary. This timespan has a fixed offset of
//!   three hours and fifty minutes ahead of UTC, and lasts until the beginning
//!   of 1907, at which point the second timespan kicks in.
//! * The second timespan has no ‘until’ date, so it’s in effect indefinitely.
//!   Instead of having a fixed offset, it refers to the set of rules under the
//!   name “Mauritius”, which we’ll have to consult to compute the timespans.
//!     * The first two rules refer to a summer time transition that began on
//!       the 10th of October 1982, and lasted until the 21st of March 1983. But
//!       before we get onto that, we need to add a timespan beginning at the
//!       time the last one ended (1907), up until the point Summer Time kicks
//!       in (1982), reflecting that it was four hours ahead of UTC.
//!     * After this, we add another timespan for Summer Time, when Mauritius
//!       was an extra hour ahead, bringing the total offset for that time to
//!       *five* hours.
//!     * The next (and last) two rules refer to another summer time
//!       transition from the last Sunday of October 2008 to the last Sunday of
//!       March 2009, this time at 2am local time instead of midnight. But, as
//!       before, we need to add a *standard* time timespan beginning at the
//!       time Summer Time ended (1983) up until the point the next span of
//!       Summer Time kicks in (2008), again reflecting that it was four hours
//!       ahead of UTC again.
//!     * Next, we add the Summer Time timespan, again bringing the total
//!       offset to five hours. We need to calculate when the last Sundays of
//!       the months are to get the dates correct.
//!     * Finally, we add one last standard time timespan, lasting from 2009
//!       indefinitely, as the Mauritian authorities decided not to change to
//!       Summer Time again.
//!
//! All this calculation results in the following six timespans to be added:
//!
//! | Timespan start            | Abbreviation | UTC offset         | DST? |
//! |:--------------------------|:-------------|:-------------------|:-----|
//! | *no start*                | LMT          | 3 hours 50 minutes | No   |
//! | 1906-11-31 T 20:10:00 UTC | MUT          | 4 hours            | No   |
//! | 1982-09-09 T 20:00:00 UTC | MUST         | 5 hours            | Yes  |
//! | 1983-02-20 T 19:00:00 UTC | MUT          | 4 hours            | No   |
//! | 2008-09-25 T 22:00:00 UTC | MUST         | 5 hours            | Yes  |
//! | 2009-02-28 T 21:00:00 UTC | MUT          | 4 hours            | No   |
//!
//! There are a few final things of note:
//!
//! Firstly, this library records the times that timespans *begin*, while
//! the tz data files record the times that timespans *end*. Pay attention to
//! this if the timestamps aren’t where you expect them to be! For example, in
//! the data file, the first zone rule has an ‘until’ date and the second has
//! none, whereas in the list of timespans, the last timespan has a ‘start’
//! date and the *first* has none.
//!
//! Secondly, although local mean time in Mauritius lasted until 1907, the
//! timespan is recorded as ending in 1906! Why is this? It’s because the
//! transition occurred at midnight *at the local time*, which in this case,
//! was three hours fifty minutes ahead of UTC. So that time has to be
//! *subtracted* from the date, resulting in twenty hours and ten minutes on
//! the last day of the year. Similar things happen on the rest of the
//! transitions, being either four or five hours ahead of UTC.
//!
//! The logic in this file is based off of `zic.c`, which comes with the
//! zoneinfo files and is in the public domain.

use crate::table::{RuleInfo, Saving, Table, ZoneInfo};

/// A set of timespans, separated by the instances at which the timespans
/// change over. There will always be one more timespan than transitions.
///
/// This mimics the `FixedTimespanSet` struct in `datetime::cal::zone`,
/// except it uses owned `Vec`s instead of slices.
#[derive(PartialEq, Debug, Clone)]
pub struct FixedTimespanSet {
    /// The first timespan, which is assumed to have been in effect up until
    /// the initial transition instant (if any). Each set has to have at
    /// least one timespan.
    pub first: FixedTimespan,

    /// The rest of the timespans, as a vector of tuples, each containing:
    ///
    /// 1. A transition instant at which the previous timespan ends and the
    ///    next one begins, stored as a Unix timestamp;
    /// 2. The actual timespan to transition into.
    pub rest: Vec<(i64, FixedTimespan)>,
}

/// An individual timespan with a fixed offset.
///
/// This mimics the `FixedTimespan` struct in `datetime::cal::zone`, except
/// instead of “total offset” and “is DST” fields, it has separate UTC and
/// DST fields. Also, the name is an owned `String` here instead of a slice.
#[derive(PartialEq, Debug, Clone)]
pub struct FixedTimespan {
    /// The number of seconds offset from UTC during this timespan.
    pub utc_offset: i64,

    /// The number of *extra* daylight-saving seconds during this timespan.
    pub dst_offset: i64,

    /// The abbreviation in use during this timespan.
    pub name: String,
}

impl FixedTimespan {
    /// The total offset in effect during this timespan.
    pub fn total_offset(&self) -> i64 {
        self.utc_offset + self.dst_offset
    }
}

/// Trait to put the `timespans` method on Tables.
pub trait TableTransitions {
    /// Computes a fixed timespan set for the timezone with the given name.
    /// Returns `None` if the table doesn’t contain a time zone with that name.
    fn timespans(&self, zone_name: &str) -> Option<FixedTimespanSet>;
}

impl TableTransitions for Table {
    fn timespans(&self, zone_name: &str) -> Option<FixedTimespanSet> {
        let mut builder = FixedTimespanSetBuilder::default();

        let zoneset = match self.get_zoneset(zone_name) {
            Some(zones) => zones,
            None => return None,
        };

        for (i, zone_info) in zoneset.iter().enumerate() {
            let mut dst_offset = 0;
            let use_until = i != zoneset.len() - 1;
            let utc_offset = zone_info.offset;

            let mut insert_start_transition = i > 0;
            let mut start_zone_id = None;
            let mut start_utc_offset = zone_info.offset;
            let mut start_dst_offset = 0;

            match zone_info.saving {
                Saving::NoSaving => {
                    builder.add_fixed_saving(
                        zone_info,
                        0,
                        &mut dst_offset,
                        utc_offset,
                        &mut insert_start_transition,
                        &mut start_zone_id,
                    );
                }

                Saving::OneOff(amount) => {
                    builder.add_fixed_saving(
                        zone_info,
                        amount,
                        &mut dst_offset,
                        utc_offset,
                        &mut insert_start_transition,
                        &mut start_zone_id,
                    );
                }

                Saving::Multiple(ref rules) => {
                    let rules = &self.rulesets[rules];
                    builder.add_multiple_saving(
                        zone_info,
                        rules,
                        &mut dst_offset,
                        use_until,
                        utc_offset,
                        &mut insert_start_transition,
                        &mut start_zone_id,
                        &mut start_utc_offset,
                        &mut start_dst_offset,
                    );
                }
            }

            if insert_start_transition && start_zone_id.is_some() {
                let t = (
                    builder.start_time.expect("Start time"),
                    FixedTimespan {
                        utc_offset: start_utc_offset,
                        dst_offset: start_dst_offset,
                        name: start_zone_id.clone().expect("Start zone ID"),
                    },
                );
                builder.rest.push(t);
            }

            if use_until {
                builder.start_time = Some(
                    zone_info.end_time.expect("End time").to_timestamp() - utc_offset - dst_offset,
                );
            }
        }

        Some(builder.build())
    }
}

#[derive(Debug, Default)]
struct FixedTimespanSetBuilder {
    first: Option<FixedTimespan>,
    rest: Vec<(i64, FixedTimespan)>,

    start_time: Option<i64>,
    until_time: Option<i64>,
}

impl FixedTimespanSetBuilder {
    fn add_fixed_saving(
        &mut self,
        timespan: &ZoneInfo,
        amount: i64,
        dst_offset: &mut i64,
        utc_offset: i64,
        insert_start_transition: &mut bool,
        start_zone_id: &mut Option<String>,
    ) {
        *dst_offset = amount;
        *start_zone_id = Some(timespan.format.format(*dst_offset, None));

        if *insert_start_transition {
            let time = self.start_time.unwrap();
            let timespan = FixedTimespan {
                utc_offset: timespan.offset,
                dst_offset: *dst_offset,
                name: start_zone_id.clone().unwrap_or_default(),
            };

            self.rest.push((time, timespan));
            *insert_start_transition = false;
        } else {
            self.first = Some(FixedTimespan {
                utc_offset,
                dst_offset: *dst_offset,
                name: start_zone_id.clone().unwrap_or_default(),
            });
        }
    }

    #[allow(unused_results)]
    #[allow(clippy::too_many_arguments)]
    fn add_multiple_saving(
        &mut self,
        timespan: &ZoneInfo,
        rules: &[RuleInfo],
        dst_offset: &mut i64,
        use_until: bool,
        utc_offset: i64,
        insert_start_transition: &mut bool,
        start_zone_id: &mut Option<String>,
        start_utc_offset: &mut i64,
        start_dst_offset: &mut i64,
    ) {
        use std::mem::replace;

        for year in 1800..2100 {
            if use_until && year > timespan.end_time.unwrap().year() {
                break;
            }

            let mut activated_rules = rules
                .iter()
                .filter(|r| r.applies_to_year(year))
                .collect::<Vec<_>>();

            loop {
                if use_until {
                    self.until_time =
                        Some(timespan.end_time.unwrap().to_timestamp() - utc_offset - *dst_offset);
                }

                // Find the minimum rule and its start time based on the current
                // UTC and DST offsets.
                let earliest = activated_rules
                    .iter()
                    .enumerate()
                    .map(|(i, r)| (i, r.absolute_datetime(year, utc_offset, *dst_offset)))
                    .min_by_key(|&(_, time)| time);

                let (pos, earliest_at) = match earliest {
                    Some((pos, time)) => (pos, time),
                    None => break,
                };

                let earliest_rule = activated_rules.remove(pos);

                if use_until && earliest_at >= self.until_time.unwrap() {
                    break;
                }

                *dst_offset = earliest_rule.time_to_add;

                if *insert_start_transition && earliest_at == self.start_time.unwrap() {
                    *insert_start_transition = false;
                }

                if *insert_start_transition {
                    if earliest_at < self.start_time.unwrap() {
                        let _ = replace(start_utc_offset, timespan.offset);
                        let _ = replace(start_dst_offset, *dst_offset);
                        let _ = replace(
                            start_zone_id,
                            Some(
                                timespan
                                    .format
                                    .format(*dst_offset, earliest_rule.letters.as_ref()),
                            ),
                        );
                        continue;
                    }

                    if start_zone_id.is_none()
                        && *start_utc_offset + *start_dst_offset == timespan.offset + *dst_offset
                    {
                        let _ = replace(
                            start_zone_id,
                            Some(
                                timespan
                                    .format
                                    .format(*dst_offset, earliest_rule.letters.as_ref()),
                            ),
                        );
                    }
                }

                let t = (
                    earliest_at,
                    FixedTimespan {
                        utc_offset: timespan.offset,
                        dst_offset: earliest_rule.time_to_add,
                        name: timespan
                            .format
                            .format(earliest_rule.time_to_add, earliest_rule.letters.as_ref()),
                    },
                );
                self.rest.push(t);
            }
        }
    }

    fn build(mut self) -> FixedTimespanSet {
        self.rest.sort_by(|a, b| a.0.cmp(&b.0));

        let first = match self.first {
            Some(ft) => ft,
            None => self
                .rest
                .iter()
                .find(|t| t.1.dst_offset == 0)
                .unwrap()
                .1
                .clone(),
        };

        let mut zoneset = FixedTimespanSet {
            first,
            rest: self.rest,
        };
        optimise(&mut zoneset);
        zoneset
    }
}

#[allow(unused_results)] // for remove
fn optimise(transitions: &mut FixedTimespanSet) {
    let mut from_i = 0;
    let mut to_i = 0;

    while from_i < transitions.rest.len() {
        if to_i > 1 {
            let from = transitions.rest[from_i].0;
            let to = transitions.rest[to_i - 1].0;
            if from + transitions.rest[to_i - 1].1.total_offset()
                <= to + transitions.rest[to_i - 2].1.total_offset()
            {
                transitions.rest[to_i - 1].1 = transitions.rest[from_i].1.clone();
                from_i += 1;
                continue;
            }
        }

        if to_i == 0 || transitions.rest[to_i - 1].1 != transitions.rest[from_i].1 {
            transitions.rest[to_i] = transitions.rest[from_i].clone();
            to_i += 1;
        }

        from_i += 1
    }

    transitions.rest.truncate(to_i);

    if !transitions.rest.is_empty() && transitions.first == transitions.rest[0].1 {
        transitions.rest.remove(0);
    }
}

#[cfg(test)]
mod test {
    use super::optimise;
    use super::*;

    // Allow unused results in test code, because the only ‘results’ that
    // we need to ignore are the ones from inserting and removing from
    // tables and vectors. And as we set them up ourselves, they’re bound
    // to be correct, otherwise the tests would fail!
    #[test]
    #[allow(unused_results)]
    fn optimise_macquarie() {
        let mut transitions = FixedTimespanSet {
            first: FixedTimespan {
                utc_offset: 0,
                dst_offset: 0,
                name: "zzz".to_owned(),
            },
            rest: vec![
                (
                    -2_214_259_200,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 0,
                        name: "AEST".to_owned(),
                    },
                ),
                (
                    -1_680_508_800,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 3600,
                        name: "AEDT".to_owned(),
                    },
                ),
                (
                    -1_669_892_400,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 3600,
                        name: "AEDT".to_owned(),
                    },
                ), // gets removed
                (
                    -1_665_392_400,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 0,
                        name: "AEST".to_owned(),
                    },
                ),
                (
                    -1_601_719_200,
                    FixedTimespan {
                        utc_offset: 0,
                        dst_offset: 0,
                        name: "zzz".to_owned(),
                    },
                ),
                (
                    -687_052_800,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 0,
                        name: "AEST".to_owned(),
                    },
                ),
                (
                    -94_730_400,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 0,
                        name: "AEST".to_owned(),
                    },
                ), // also gets removed
                (
                    -71_136_000,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 3600,
                        name: "AEDT".to_owned(),
                    },
                ),
                (
                    -55_411_200,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 0,
                        name: "AEST".to_owned(),
                    },
                ),
                (
                    -37_267_200,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 3600,
                        name: "AEDT".to_owned(),
                    },
                ),
                (
                    -25_776_000,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 0,
                        name: "AEST".to_owned(),
                    },
                ),
                (
                    -5_817_600,
                    FixedTimespan {
                        utc_offset: 36000,
                        dst_offset: 3600,
                        name: "AEDT".to_owned(),
                    },
                ),
            ],
        };

        let mut result = transitions.clone();
        result.rest.remove(6);
        result.rest.remove(2);

        optimise(&mut transitions);
        assert_eq!(transitions, result);
    }
}
