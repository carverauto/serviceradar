//! Time utilities for translating SRQL presets to chrono ranges.

use crate::error::{Result, ServiceError};
use chrono::{DateTime, Duration, NaiveDateTime, Utc};

#[derive(Debug, Clone)]
pub struct TimeRange {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub enum TimeFilterSpec {
    RelativeHours(i64),
    RelativeDays(i64),
    Today,
    Yesterday,
    Absolute {
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    },
    AbsoluteOpenEnd {
        start: DateTime<Utc>,
    },
    AbsoluteOpenStart {
        end: DateTime<Utc>,
    },
}

impl TimeFilterSpec {
    pub fn resolve(&self, now: DateTime<Utc>) -> Result<TimeRange> {
        let range = match self {
            TimeFilterSpec::RelativeHours(hours) => TimeRange {
                start: now - Duration::hours(*hours),
                end: now,
            },
            TimeFilterSpec::RelativeDays(days) => TimeRange {
                start: now - Duration::days(*days),
                end: now,
            },
            TimeFilterSpec::Today => {
                let start = now.date_naive().and_hms_opt(0, 0, 0).unwrap();
                TimeRange {
                    start: DateTime::<Utc>::from_naive_utc_and_offset(start, Utc),
                    end: now,
                }
            }
            TimeFilterSpec::Yesterday => {
                let today = now.date_naive();
                let start = today
                    .pred_opt()
                    .unwrap_or(today)
                    .and_hms_opt(0, 0, 0)
                    .unwrap();
                let end = today.and_hms_opt(0, 0, 0).unwrap();
                TimeRange {
                    start: DateTime::<Utc>::from_naive_utc_and_offset(start, Utc),
                    end: DateTime::<Utc>::from_naive_utc_and_offset(end, Utc),
                }
            }
            TimeFilterSpec::Absolute { start, end } => TimeRange {
                start: *start,
                end: *end,
            },
            TimeFilterSpec::AbsoluteOpenEnd { start } => {
                if *start > now {
                    return Err(ServiceError::InvalidRequest(
                        "time range start must be before end".to_string(),
                    ));
                }
                TimeRange {
                    start: *start,
                    end: now,
                }
            }
            TimeFilterSpec::AbsoluteOpenStart { end } => TimeRange {
                start: DateTime::<Utc>::MIN_UTC,
                end: *end,
            },
        };

        if range.start > range.end {
            return Err(ServiceError::InvalidRequest(
                "time range start must be before end".to_string(),
            ));
        }
        Ok(range)
    }
}

pub fn parse_time_value(raw: &str) -> Result<TimeFilterSpec> {
    let value = raw
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .to_lowercase();

    if value.starts_with('[') && value.ends_with(']') {
        return parse_absolute_range(&value);
    }

    if let Some(spec) = parse_relative_keyword(&value) {
        return Ok(spec);
    }

    if value.contains("day") || value.contains("hour") {
        if let Some(spec) = parse_spelled_duration(&value) {
            return Ok(spec);
        }
    }

    Err(ServiceError::InvalidRequest(format!(
        "unsupported time token '{raw}'"
    )))
}

fn parse_relative_keyword(value: &str) -> Option<TimeFilterSpec> {
    if value == "today" {
        return Some(TimeFilterSpec::Today);
    }
    if value == "yesterday" {
        return Some(TimeFilterSpec::Yesterday);
    }

    let normalized = value.replace(['_', '-'], "");
    if let Some(stripped) = normalized.strip_prefix("last") {
        if let Some(spec) = parse_numeric_suffix(stripped) {
            return Some(spec);
        }
    }
    if let Some(spec) = parse_numeric_suffix(&normalized) {
        return Some(spec);
    }

    None
}

fn parse_spelled_duration(value: &str) -> Option<TimeFilterSpec> {
    let cleaned = value
        .chars()
        .filter(|ch| !ch.is_whitespace() && *ch != '"')
        .collect::<String>();
    parse_numeric_suffix(&cleaned)
}

fn parse_numeric_suffix(value: &str) -> Option<TimeFilterSpec> {
    let mut digits = String::new();
    let mut suffix = String::new();

    for ch in value.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else {
            suffix.push(ch);
        }
    }

    let amount: i64 = digits.parse().ok()?;
    let suffix = suffix.trim();

    match suffix {
        "h" | "hour" | "hours" => Some(TimeFilterSpec::RelativeHours(amount)),
        "d" | "day" | "days" => Some(TimeFilterSpec::RelativeDays(amount)),
        _ => None,
    }
}

fn parse_absolute_range(value: &str) -> Result<TimeFilterSpec> {
    let inner = value.trim_matches(['[', ']']);
    let (start_raw, end_raw) = inner
        .split_once(',')
        .ok_or_else(|| ServiceError::InvalidRequest("invalid time range".into()))?;
    let start_raw = start_raw.trim();
    let end_raw = end_raw.trim();

    match (start_raw.is_empty(), end_raw.is_empty()) {
        (false, false) => {
            let start = parse_datetime(start_raw)?;
            let end = parse_datetime(end_raw)?;
            Ok(TimeFilterSpec::Absolute { start, end })
        }
        (false, true) => {
            let start = parse_datetime(start_raw)?;
            Ok(TimeFilterSpec::AbsoluteOpenEnd { start })
        }
        (true, false) => {
            let end = parse_datetime(end_raw)?;
            Ok(TimeFilterSpec::AbsoluteOpenStart { end })
        }
        (true, true) => Err(ServiceError::InvalidRequest(
            "time range requires at least one bound".into(),
        )),
    }
}

fn parse_datetime(value: &str) -> Result<DateTime<Utc>> {
    if let Ok(dt) = DateTime::parse_from_rfc3339(value) {
        return Ok(dt.with_timezone(&Utc));
    }
    if let Ok(dt) = NaiveDateTime::parse_from_str(value, "%Y-%m-%d %H:%M:%S") {
        return Ok(DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc));
    }
    Err(ServiceError::InvalidRequest(format!(
        "invalid time literal '{value}'"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_relative_days() {
        let spec = parse_time_value("last_7d").unwrap();
        let now = Utc::now();
        let range = spec.resolve(now).unwrap();
        assert!(range.start < range.end);
    }

    #[test]
    fn parses_absolute_range() {
        let spec = parse_time_value("[2025-01-01 00:00:00,2025-01-02 00:00:00]").unwrap();
        let range = spec.resolve(Utc::now()).unwrap();
        assert_eq!(
            range.start,
            DateTime::parse_from_rfc3339("2025-01-01T00:00:00Z")
                .unwrap()
                .with_timezone(&Utc)
        );
        assert_eq!(
            range.end,
            DateTime::parse_from_rfc3339("2025-01-02T00:00:00Z")
                .unwrap()
                .with_timezone(&Utc)
        );
    }

    #[test]
    fn parses_open_end_absolute_range() {
        let spec = parse_time_value("[2025-11-16T09:06:34.543Z,]").unwrap();
        let now = DateTime::parse_from_rfc3339("2025-11-17T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let range = spec.resolve(now).unwrap();
        assert_eq!(
            range.start,
            DateTime::parse_from_rfc3339("2025-11-16T09:06:34.543Z")
                .unwrap()
                .with_timezone(&Utc)
        );
        assert_eq!(range.end, now);
    }

    #[test]
    fn parses_open_start_absolute_range() {
        let spec = parse_time_value("[,2025-11-16T09:06:34.543Z]").unwrap();
        let now = DateTime::parse_from_rfc3339("2025-11-17T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let range = spec.resolve(now).unwrap();
        assert_eq!(
            range.end,
            DateTime::parse_from_rfc3339("2025-11-16T09:06:34.543Z")
                .unwrap()
                .with_timezone(&Utc)
        );
        assert_eq!(range.start, DateTime::<Utc>::MIN_UTC);
    }
}
