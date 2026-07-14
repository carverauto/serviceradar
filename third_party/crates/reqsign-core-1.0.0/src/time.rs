//! Time related utils.

use crate::Error;
use chrono::format::Fixed;
use chrono::format::Item;
use chrono::format::Numeric;
use chrono::format::Pad;
use chrono::SecondsFormat;
use chrono::Utc;

/// DateTime is the alias for chrono::DateTime<Utc>.
pub type DateTime = chrono::DateTime<Utc>;

/// Create datetime of now.
pub fn now() -> DateTime {
    Utc::now()
}

/// DATE is a time format like `20220301`
const DATE: &[Item<'static>] = &[
    Item::Numeric(Numeric::Year, Pad::Zero),
    Item::Numeric(Numeric::Month, Pad::Zero),
    Item::Numeric(Numeric::Day, Pad::Zero),
];

/// Format time into date: `20220301`
pub fn format_date(t: DateTime) -> String {
    t.format_with_items(DATE.iter()).to_string()
}

/// ISO8601 is a time format like `20220313T072004Z`.
const ISO8601: &[Item<'static>] = &[
    Item::Numeric(Numeric::Year, Pad::Zero),
    Item::Numeric(Numeric::Month, Pad::Zero),
    Item::Numeric(Numeric::Day, Pad::Zero),
    Item::Literal("T"),
    Item::Numeric(Numeric::Hour, Pad::Zero),
    Item::Numeric(Numeric::Minute, Pad::Zero),
    Item::Numeric(Numeric::Second, Pad::Zero),
    Item::Literal("Z"),
];

/// Format time into ISO8601: `20220313T072004Z`
pub fn format_iso8601(t: DateTime) -> String {
    t.format_with_items(ISO8601.iter()).to_string()
}

/// HTTP_DATE is a time format like `Sun, 06 Nov 1994 08:49:37 GMT`.
const HTTP_DATE: &[Item<'static>] = &[
    Item::Fixed(Fixed::ShortWeekdayName),
    Item::Literal(", "),
    Item::Numeric(Numeric::Day, Pad::Zero),
    Item::Literal(" "),
    Item::Fixed(Fixed::ShortMonthName),
    Item::Literal(" "),
    Item::Numeric(Numeric::Year, Pad::Zero),
    Item::Literal(" "),
    Item::Numeric(Numeric::Hour, Pad::Zero),
    Item::Literal(":"),
    Item::Numeric(Numeric::Minute, Pad::Zero),
    Item::Literal(":"),
    Item::Numeric(Numeric::Second, Pad::Zero),
    Item::Literal(" GMT"),
];

/// Format time into http date: `Sun, 06 Nov 1994 08:49:37 GMT`
///
/// ## Note
///
/// HTTP date is slightly different from RFC2822.
///
/// - Timezone is fixed to GMT.
/// - Day must be 2 digit.
pub fn format_http_date(t: DateTime) -> String {
    t.format_with_items(HTTP_DATE.iter()).to_string()
}

/// Format time into RFC3339: `2022-03-13T07:20:04Z`
pub fn format_rfc3339(t: DateTime) -> String {
    t.to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// Parse time from RFC3339.
///
/// All of them are valid time:
///
/// - `2022-03-13T07:20:04Z`
/// - `2022-03-01T08:12:34+00:00`
/// - `2022-03-01T08:12:34.00+00:00`
pub fn parse_rfc3339(s: &str) -> crate::Result<DateTime> {
    Ok(chrono::DateTime::parse_from_rfc3339(s)
        .map_err(|err| {
            Error::unexpected(format!("parse '{}' into rfc3339 failed", s)).with_source(err)
        })?
        .with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    fn test_time() -> DateTime {
        Utc.with_ymd_and_hms(2022, 3, 1, 8, 12, 34).unwrap()
    }

    #[test]
    fn test_format_date() {
        let t = test_time();
        assert_eq!("20220301", format_date(t))
    }

    #[test]
    fn test_format_ios8601() {
        let t = test_time();
        assert_eq!("20220301T081234Z", format_iso8601(t))
    }

    #[test]
    fn test_format_http_date() {
        let t = test_time();
        assert_eq!("Tue, 01 Mar 2022 08:12:34 GMT", format_http_date(t))
    }

    #[test]
    fn test_format_rfc3339() {
        let t = test_time();
        assert_eq!("2022-03-01T08:12:34Z", format_rfc3339(t))
    }

    #[test]
    fn test_parse_rfc3339() {
        let t = test_time();

        for v in [
            "2022-03-01T08:12:34Z",
            "2022-03-01T08:12:34+00:00",
            "2022-03-01T08:12:34.00+00:00",
        ] {
            assert_eq!(t, parse_rfc3339(v).expect("must be valid time"));
        }
    }
}
