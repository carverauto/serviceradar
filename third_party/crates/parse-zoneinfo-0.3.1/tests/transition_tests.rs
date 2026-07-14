extern crate parse_zoneinfo;

use parse_zoneinfo::line::{
    ChangeTime, DaySpec, Line, LineParser, Month, TimeSpec, TimeType, Weekday, Year,
};
use parse_zoneinfo::table::{Format, RuleInfo, Saving, Table, TableBuilder, ZoneInfo};
use parse_zoneinfo::transitions::{FixedTimespan, FixedTimespanSet, TableTransitions};

#[test]
fn no_transitions() {
    let zone = ZoneInfo {
        offset: 1234,
        format: Format::new("TEST"),
        saving: Saving::NoSaving,
        end_time: None,
    };

    let mut table = Table::default();
    table.zonesets.insert("Test/Zone".to_owned(), vec![zone]);

    assert_eq!(
        table.timespans("Test/Zone"),
        Some(FixedTimespanSet {
            first: FixedTimespan {
                utc_offset: 1234,
                dst_offset: 0,
                name: "TEST".to_owned()
            },
            rest: vec![],
        })
    );
}

#[test]
fn one_transition() {
    let zone_1 = ZoneInfo {
        offset: 1234,
        format: Format::new("TEST"),
        saving: Saving::NoSaving,
        end_time: Some(ChangeTime::UntilTime(
            Year::Number(1970),
            Month::January,
            DaySpec::Ordinal(2),
            TimeSpec::HoursMinutesSeconds(10, 17, 36).with_type(TimeType::UTC),
        )),
    };

    let zone_2 = ZoneInfo {
        offset: 5678,
        format: Format::new("TSET"),
        saving: Saving::NoSaving,
        end_time: None,
    };

    let mut table = Table::default();
    table
        .zonesets
        .insert("Test/Zone".to_owned(), vec![zone_1, zone_2]);

    let expected = FixedTimespanSet {
        first: FixedTimespan {
            utc_offset: 1234,
            dst_offset: 0,
            name: "TEST".to_owned(),
        },
        rest: vec![(
            122222,
            FixedTimespan {
                utc_offset: 5678,
                dst_offset: 0,
                name: "TSET".to_owned(),
            },
        )],
    };

    assert_eq!(table.timespans("Test/Zone"), Some(expected));
}

#[test]
fn two_transitions() {
    let zone_1 = ZoneInfo {
        offset: 1234,
        format: Format::new("TEST"),
        saving: Saving::NoSaving,
        end_time: Some(ChangeTime::UntilTime(
            Year::Number(1970),
            Month::January,
            DaySpec::Ordinal(2),
            TimeSpec::HoursMinutesSeconds(10, 17, 36).with_type(TimeType::Standard),
        )),
    };

    let zone_2 = ZoneInfo {
        offset: 3456,
        format: Format::new("TSET"),
        saving: Saving::NoSaving,
        end_time: Some(ChangeTime::UntilTime(
            Year::Number(1970),
            Month::January,
            DaySpec::Ordinal(3),
            TimeSpec::HoursMinutesSeconds(17, 09, 27).with_type(TimeType::Standard),
        )),
    };

    let zone_3 = ZoneInfo {
        offset: 5678,
        format: Format::new("ESTE"),
        saving: Saving::NoSaving,
        end_time: None,
    };

    let mut table = Table::default();
    table
        .zonesets
        .insert("Test/Zone".to_owned(), vec![zone_1, zone_2, zone_3]);

    let expected = FixedTimespanSet {
        first: FixedTimespan {
            utc_offset: 1234,
            dst_offset: 0,
            name: "TEST".to_owned(),
        },
        rest: vec![
            (
                122222,
                FixedTimespan {
                    utc_offset: 3456,
                    dst_offset: 0,
                    name: "TSET".to_owned(),
                },
            ),
            (
                231111,
                FixedTimespan {
                    utc_offset: 5678,
                    dst_offset: 0,
                    name: "ESTE".to_owned(),
                },
            ),
        ],
    };

    assert_eq!(table.timespans("Test/Zone"), Some(expected));
}

#[test]
fn one_rule() {
    let ruleset = vec![RuleInfo {
        from_year: Year::Number(1980),
        to_year: None,
        month: Month::February,
        day: DaySpec::Ordinal(4),
        time: 0,
        time_type: TimeType::UTC,
        time_to_add: 1000,
        letters: None,
    }];

    let lmt = ZoneInfo {
        offset: 0,
        format: Format::new("LMT"),
        saving: Saving::NoSaving,
        end_time: Some(ChangeTime::UntilYear(Year::Number(1980))),
    };

    let zone = ZoneInfo {
        offset: 2000,
        format: Format::new("TEST"),
        saving: Saving::Multiple("Dwayne".to_owned()),
        end_time: None,
    };

    let mut table = Table::default();
    table
        .zonesets
        .insert("Test/Zone".to_owned(), vec![lmt, zone]);
    table.rulesets.insert("Dwayne".to_owned(), ruleset);

    assert_eq!(
        table.timespans("Test/Zone"),
        Some(FixedTimespanSet {
            first: FixedTimespan {
                utc_offset: 0,
                dst_offset: 0,
                name: "LMT".to_owned()
            },
            rest: vec![(
                318_470_400,
                FixedTimespan {
                    utc_offset: 2000,
                    dst_offset: 1000,
                    name: "TEST".to_owned()
                }
            )],
        })
    );
}

#[test]
fn two_rules() {
    let ruleset = vec![
        RuleInfo {
            from_year: Year::Number(1980),
            to_year: None,
            month: Month::February,
            day: DaySpec::Ordinal(4),
            time: 0,
            time_type: TimeType::UTC,
            time_to_add: 1000,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1989),
            to_year: None,
            month: Month::January,
            day: DaySpec::Ordinal(12),
            time: 0,
            time_type: TimeType::UTC,
            time_to_add: 1500,
            letters: None,
        },
    ];

    let lmt = ZoneInfo {
        offset: 0,
        format: Format::new("LMT"),
        saving: Saving::NoSaving,
        end_time: Some(ChangeTime::UntilYear(Year::Number(1980))),
    };

    let zone = ZoneInfo {
        offset: 2000,
        format: Format::new("TEST"),
        saving: Saving::Multiple("Dwayne".to_owned()),
        end_time: None,
    };

    let mut table = Table::default();
    table
        .zonesets
        .insert("Test/Zone".to_owned(), vec![lmt, zone]);
    table.rulesets.insert("Dwayne".to_owned(), ruleset);

    assert_eq!(
        table.timespans("Test/Zone"),
        Some(FixedTimespanSet {
            first: FixedTimespan {
                utc_offset: 0,
                dst_offset: 0,
                name: "LMT".to_owned()
            },
            rest: vec![
                (
                    318_470_400,
                    FixedTimespan {
                        utc_offset: 2000,
                        dst_offset: 1000,
                        name: "TEST".to_owned()
                    }
                ),
                (
                    600_566_400,
                    FixedTimespan {
                        utc_offset: 2000,
                        dst_offset: 1500,
                        name: "TEST".to_owned()
                    }
                ),
            ],
        })
    );
}

#[test]
fn tripoli() {
    let libya = vec![
        RuleInfo {
            from_year: Year::Number(1951),
            to_year: None,
            month: Month::October,
            day: DaySpec::Ordinal(14),
            time: 7200,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1952),
            to_year: None,
            month: Month::January,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1953),
            to_year: None,
            month: Month::October,
            day: DaySpec::Ordinal(9),
            time: 7200,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1954),
            to_year: None,
            month: Month::January,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1955),
            to_year: None,
            month: Month::September,
            day: DaySpec::Ordinal(30),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1956),
            to_year: None,
            month: Month::January,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1982),
            to_year: Some(Year::Number(1984)),
            month: Month::April,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1982),
            to_year: Some(Year::Number(1985)),
            month: Month::October,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1985),
            to_year: None,
            month: Month::April,
            day: DaySpec::Ordinal(6),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1986),
            to_year: None,
            month: Month::April,
            day: DaySpec::Ordinal(4),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1986),
            to_year: None,
            month: Month::October,
            day: DaySpec::Ordinal(3),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1987),
            to_year: Some(Year::Number(1989)),
            month: Month::April,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1987),
            to_year: Some(Year::Number(1989)),
            month: Month::October,
            day: DaySpec::Ordinal(1),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(1997),
            to_year: None,
            month: Month::April,
            day: DaySpec::Ordinal(4),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(1997),
            to_year: None,
            month: Month::October,
            day: DaySpec::Ordinal(4),
            time: 0,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
        RuleInfo {
            from_year: Year::Number(2013),
            to_year: None,
            month: Month::March,
            day: DaySpec::Last(Weekday::Friday),
            time: 3600,
            time_type: TimeType::Wall,
            time_to_add: 3600,
            letters: Some("S".to_owned()),
        },
        RuleInfo {
            from_year: Year::Number(2013),
            to_year: None,
            month: Month::October,
            day: DaySpec::Last(Weekday::Friday),
            time: 7200,
            time_type: TimeType::Wall,
            time_to_add: 0,
            letters: None,
        },
    ];

    let zone = vec![
        ZoneInfo {
            offset: 3164,
            format: Format::new("LMT"),
            saving: Saving::NoSaving,
            end_time: Some(ChangeTime::UntilYear(Year::Number(1920))),
        },
        ZoneInfo {
            offset: 3600,
            format: Format::new("CE%sT"),
            saving: Saving::Multiple("Libya".to_owned()),
            end_time: Some(ChangeTime::UntilYear(Year::Number(1959))),
        },
        ZoneInfo {
            offset: 7200,
            format: Format::new("EET"),
            saving: Saving::NoSaving,
            end_time: Some(ChangeTime::UntilYear(Year::Number(1982))),
        },
        ZoneInfo {
            offset: 3600,
            format: Format::new("CE%sT"),
            saving: Saving::Multiple("Libya".to_owned()),
            end_time: Some(ChangeTime::UntilDay(
                Year::Number(1990),
                Month::May,
                DaySpec::Ordinal(4),
            )),
        },
        ZoneInfo {
            offset: 7200,
            format: Format::new("EET"),
            saving: Saving::NoSaving,
            end_time: Some(ChangeTime::UntilDay(
                Year::Number(1996),
                Month::September,
                DaySpec::Ordinal(30),
            )),
        },
        ZoneInfo {
            offset: 3600,
            format: Format::new("CE%sT"),
            saving: Saving::Multiple("Libya".to_owned()),
            end_time: Some(ChangeTime::UntilDay(
                Year::Number(1997),
                Month::October,
                DaySpec::Ordinal(4),
            )),
        },
        ZoneInfo {
            offset: 7200,
            format: Format::new("EET"),
            saving: Saving::NoSaving,
            end_time: Some(ChangeTime::UntilTime(
                Year::Number(2012),
                Month::November,
                DaySpec::Ordinal(10),
                TimeSpec::HoursMinutes(2, 0).with_type(TimeType::Wall),
            )),
        },
        ZoneInfo {
            offset: 3600,
            format: Format::new("CE%sT"),
            saving: Saving::Multiple("Libya".to_owned()),
            end_time: Some(ChangeTime::UntilTime(
                Year::Number(2013),
                Month::October,
                DaySpec::Ordinal(25),
                TimeSpec::HoursMinutes(2, 0).with_type(TimeType::Wall),
            )),
        },
        ZoneInfo {
            offset: 7200,
            format: Format::new("EET"),
            saving: Saving::NoSaving,
            end_time: None,
        },
    ];

    let mut table = Table::default();
    table.zonesets.insert("Test/Zone".to_owned(), zone);
    table.rulesets.insert("Libya".to_owned(), libya);

    assert_eq!(
        table.timespans("Test/Zone"),
        Some(FixedTimespanSet {
            first: FixedTimespan {
                utc_offset: 3164,
                dst_offset: 0,
                name: "LMT".to_owned()
            },
            rest: vec![
                (
                    -1_577_926_364,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    -574_902_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    -568_087_200,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    -512_175_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    -504_928_800,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    -449_888_400,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    -441_856_800,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    -347_158_800,
                    FixedTimespan {
                        utc_offset: 7200,
                        dst_offset: 0,
                        name: "EET".to_owned()
                    }
                ),
                (
                    378_684_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    386_463_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    402_271_200,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    417_999_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    433_807_200,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    449_622_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    465_429_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    481_590_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    496_965_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    512_953_200,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    528_674_400,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    544_230_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    560_037_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    575_852_400,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    591_660_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    607_388_400,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    623_196_000,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    641_775_600,
                    FixedTimespan {
                        utc_offset: 7200,
                        dst_offset: 0,
                        name: "EET".to_owned()
                    }
                ),
                (
                    844_034_400,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    860_108_400,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    875_916_000,
                    FixedTimespan {
                        utc_offset: 7200,
                        dst_offset: 0,
                        name: "EET".to_owned()
                    }
                ),
                (
                    1_352_505_600,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 0,
                        name: "CET".to_owned()
                    }
                ),
                (
                    1_364_515_200,
                    FixedTimespan {
                        utc_offset: 3600,
                        dst_offset: 3600,
                        name: "CEST".to_owned()
                    }
                ),
                (
                    1_382_659_200,
                    FixedTimespan {
                        utc_offset: 7200,
                        dst_offset: 0,
                        name: "EET".to_owned()
                    }
                ),
            ],
        })
    );
}

#[test]
fn dushanbe() {
    static ZONEINFO: &str = r#"
Zone    Asia/Dushanbe   4:35:12 -   LMT 1924 May  2
            5:00    1:00    +05/+06 1991 Sep  9  2:00s
"#;

    let mut table = TableBuilder::new();
    let parser = LineParser::default();
    for line in ZONEINFO.lines() {
        let line = parser.parse_str(line).unwrap();
        match line {
            Line::Zone(zone) => table.add_zone_line(zone).unwrap(),
            Line::Continuation(cont) => table.add_continuation_line(cont).unwrap(),
            Line::Rule(rule) => table.add_rule_line(rule).unwrap(),
            Line::Link(link) => table.add_link_line(link).unwrap(),
            Line::Space => {}
        }
    }
    let table = table.build();
    let _ = table.timespans("Asia/Dushanbe").unwrap();
}
