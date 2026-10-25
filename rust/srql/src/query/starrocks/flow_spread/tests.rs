//! Evaluates the spread the query compiles, over numbers.
//!
//! [`Eval`] implements the StarRocks functions the spread is written in, so these tests run
//! the same [`Spread`] definition that renders the SQL rather than a copy of the formula.

use std::collections::BTreeMap;

use super::{MAX_BUCKETS, Ops, Spread};

type V = Option<f64>;

/// StarRocks semantics over epoch milliseconds and doubles. NULL is `None` and propagates.
struct Eval;

fn lift(a: V, b: V, f: impl Fn(f64, f64) -> f64) -> V {
    Some(f(a?, b?))
}

fn test(a: V, b: V, f: impl Fn(f64, f64) -> bool) -> Option<bool> {
    Some(f(a?, b?))
}

impl Ops for Eval {
    type V = V;
    type B = Option<bool>;

    fn int(&self, n: i64) -> V {
        Some(n as f64)
    }
    fn time_slice(&self, t: V, seconds: i64) -> V {
        let width = (seconds * 1000) as f64;
        t.map(|t| (t / width).floor() * width)
    }
    fn seconds_add(&self, t: V, seconds: V) -> V {
        lift(t, seconds, |t, s| t + s * 1000.0)
    }
    fn seconds_sub(&self, t: V, seconds: V) -> V {
        lift(t, seconds, |t, s| t - s * 1000.0)
    }
    fn seconds_diff(&self, a: V, b: V) -> V {
        lift(a, b, |a, b| ((a - b) / 1000.0).trunc())
    }
    fn milliseconds_diff(&self, a: V, b: V) -> V {
        lift(a, b, |a, b| a - b)
    }
    fn greatest(&self, a: V, b: V) -> V {
        lift(a, b, f64::max)
    }
    fn least(&self, a: V, b: V) -> V {
        lift(a, b, f64::min)
    }
    fn double(&self, a: V) -> V {
        a
    }
    fn floor(&self, a: V) -> V {
        a.map(f64::floor)
    }
    fn mul(&self, a: V, b: V) -> V {
        lift(a, b, |a, b| a * b)
    }
    fn div(&self, a: V, b: V) -> V {
        lift(a, b, |a, b| a / b)
    }
    fn sub(&self, a: V, b: V) -> V {
        lift(a, b, |a, b| a - b)
    }
    fn is_not_null(&self, a: V) -> Option<bool> {
        Some(a.is_some())
    }
    fn lt(&self, a: V, b: V) -> Option<bool> {
        test(a, b, |a, b| a < b)
    }
    fn gt(&self, a: V, b: V) -> Option<bool> {
        test(a, b, |a, b| a > b)
    }
    fn eq(&self, a: V, b: V) -> Option<bool> {
        test(a, b, |a, b| a == b)
    }
    fn all(&self, conditions: Vec<Option<bool>>) -> Option<bool> {
        if conditions.contains(&Some(false)) {
            Some(false)
        } else if conditions.contains(&None) {
            None
        } else {
            Some(true)
        }
    }
    fn case(&self, when: Option<bool>, then: V, otherwise: V) -> V {
        if when == Some(true) { then } else { otherwise }
    }
}

/// A synthetic day, 2026-01-01T00:00:00Z, in epoch milliseconds.
const DAY: f64 = 1_767_225_600_000.0;

fn at(hour: u32, minute: u32, second: u32) -> f64 {
    DAY + f64::from(hour * 3600 + minute * 60 + second) * 1000.0
}

/// Runs one flow (stamped with its end time) through the spread as the query does: expand `k`
/// from `first_k` up to 0 one bucket at a time, then SUM each row's share into its bucket.
fn spread(value: f64, start: V, end: f64, bucket_seconds: i64, window: f64) -> BTreeMap<i64, f64> {
    let row = Spread::new(
        Eval,
        bucket_seconds,
        Some(end),
        start,
        Some(end),
        Some(window),
    );
    let first = row.first_k().expect("first offset") as i64;
    let mut buckets = BTreeMap::new();
    for k in (first..=0).step_by(bucket_seconds as usize) {
        let k = Some(k as f64);
        let bucket = row.bucket(k).expect("bucket") as i64;
        *buckets.entry(bucket).or_insert(0.0) += row.share(k, Some(value)).expect("share");
    }
    buckets
}

fn total(buckets: &BTreeMap<i64, f64>) -> f64 {
    buckets.values().sum()
}

#[test]
fn shares_follow_the_interval_and_sum_exactly_to_the_volume() {
    let five = spread(
        1_000_000_000.0,
        Some(at(10, 0, 0)),
        at(10, 5, 0),
        60,
        at(9, 0, 0),
    );
    let minutes: Vec<f64> = five.values().copied().collect();
    assert_eq!(minutes, [2e8, 2e8, 2e8, 2e8, 2e8, 0.0], "{five:?}");

    // Odd volumes over partial buckets: FLOOR per bucket would drop the residue.
    for (value, start, end, bucket) in [
        (1_000_000_007.0, at(10, 0, 20), at(10, 3, 20), 60),
        (999_999_999.0, at(10, 0, 1), at(10, 59, 59), 60),
        (7.0, at(10, 2, 30), at(10, 17, 10), 300),
        (1.0, at(10, 0, 59), at(10, 1, 1), 60),
    ] {
        let buckets = spread(value, Some(start), end, bucket, at(9, 0, 0));
        assert_eq!(
            total(&buckets),
            value,
            "{value} over {start}..{end}: {buckets:?}"
        );
        let duration = end - start;
        let width = (bucket * 1000) as f64;
        for (&lo, &share) in &buckets {
            let lo = lo as f64;
            let overlap = (end.min(lo + width) - start.max(lo)).max(0.0);
            assert_eq!(share, share.floor(), "{buckets:?}");
            assert!(
                (share - value * overlap / duration).abs() < 1.0,
                "bucket {lo} got {share} of {value}: {buckets:?}"
            );
        }
    }
}

#[test]
fn a_flow_that_does_not_cross_a_bucket_boundary_books_everything_in_its_own_bucket() {
    let end = at(10, 4, 40);
    let home = at(10, 4, 0) as i64;
    for (label, start) in [
        ("null start", None),
        ("zero length", Some(end)),
        ("start after end", Some(at(10, 6, 0))),
        ("inside one bucket", Some(at(10, 4, 10))),
        ("starts on its bucket boundary", Some(at(10, 4, 0))),
    ] {
        let buckets = spread(50.0, start, end, 60, at(9, 0, 0));
        assert_eq!(buckets, BTreeMap::from([(home, 50.0)]), "{label}");
    }
}

#[test]
fn a_flow_that_began_before_the_window_contributes_only_its_in_window_share() {
    // Ten hours, the last one inside the window: a tenth of the volume, from 10:00 on.
    let buckets = spread(
        1_000_000_000.0,
        Some(at(1, 0, 0)),
        at(11, 0, 0),
        60,
        at(10, 0, 0),
    );
    assert_eq!(total(&buckets), 100_000_000.0, "{buckets:?}");
    assert_eq!(buckets.keys().next().copied(), Some(at(10, 0, 0) as i64));
    assert_eq!(buckets.len(), 61);
}

#[test]
fn a_flow_longer_than_the_cap_folds_its_earlier_part_into_the_earliest_bucket() {
    // Six hours at one byte a second: 360 one-minute buckets, capped at MAX_BUCKETS.
    let buckets = spread(21_600.0, Some(at(10, 0, 0)), at(16, 0, 0), 60, at(9, 0, 0));
    assert_eq!(buckets.len() as i64, MAX_BUCKETS);
    assert_eq!(total(&buckets), 21_600.0);
    let mut shares = buckets.iter();
    // 12:01 is the earliest of 240 buckets ending at 16:00; it holds 10:00-12:02.
    assert_eq!(shares.next(), Some((&(at(12, 1, 0) as i64), &7_320.0)));
    assert_eq!(shares.next(), Some((&(at(12, 2, 0) as i64), &60.0)));
}
