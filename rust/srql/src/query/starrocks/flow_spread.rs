//! Spreads a flow's volume over the buckets its interval covers.
//!
//! A flow row is stamped with its end time (`choose_timestamp` in the EventWriter flow
//! processor), so bucketing by `time` books a long flow's whole byte and packet count into the
//! bucket it ended in: a five-minute transfer draws as one spike five times its real rate. A
//! bucketed volume sum therefore spreads each row's value over the buckets its
//! `[start_time, time]` interval overlaps, in proportion to the overlap. The row's own
//! timestamp closes the interval, so the last bucket is always the one the row is booked in
//! today and the window predicate on `time` stays exact.
//!
//! * Totals are exact. A bucket spanning `[lo, hi)` receives
//!   `FLOOR(v * c(hi)) - FLOOR(v * c(lo))`, where `c` is the fraction of the interval elapsed
//!   at a boundary. Neighbouring buckets evaluate the same expression on the same boundary,
//!   so the shares telescope to
//!   `FLOOR(v * 1.0) - FLOOR(v * 0.0) = v` for an integer volume, and the rounding residue
//!   stays inside the flow.
//! * A row keeps its whole value in its own bucket unless it has a `start_time`, an
//!   `end_time` after it, and starts before its own bucket. NULL starts, zero or negative
//!   durations, and flows inside one bucket are booked exactly as before.
//! * The in-window share is always measured against the real `[start_time, time]` interval.
//!   A flow that began before the window contributes only the share from the window's first
//!   bucket onward.
//! * [`MAX_BUCKETS`] limits the expansion to that many rows per flow. When a window holds more
//!   buckets than that and a flow is longer, the in-window part before its earliest emitted
//!   bucket is added to that bucket.
//! * Sampling is applied once: the value handed in is already the sampled volume.
//!
//! Only bucketed SUMs of a flow volume column spread. Other aggregates in the same `stats`
//! query read the row only in its own bucket (`home`), so a count still counts each flow once,
//! where it ended.

/// The most buckets one flow row expands into. A NetFlow chart asks for about 120 points, so a
/// chart never reaches this bound; it limits the expansion of a hand-written query with a fine
/// bucket over a long window.
pub(super) const MAX_BUCKETS: i64 = 240;

/// The flow columns whose value is a volume that accrues over the flow's interval.
pub(super) const VOLUME_FIELDS: &[&str] = &[
    "bytes_total",
    "packets_total",
    "bytes_in",
    "bytes_out",
    "packets_in",
    "packets_out",
];

pub(super) fn is_volume_field(field: &str) -> bool {
    VOLUME_FIELDS.contains(&field)
}

/// The operations the spread is written in. [`Sql`] renders them as the StarRocks expressions
/// a query runs. The tests evaluate the same [`Spread`] over numbers, so the arithmetic they
/// check is the arithmetic the query uses.
trait Ops {
    /// A datetime or a number, possibly NULL.
    type V: Clone;
    /// A condition.
    type B: Clone;
    fn int(&self, n: i64) -> Self::V;
    fn time_slice(&self, t: Self::V, seconds: i64) -> Self::V;
    fn seconds_add(&self, t: Self::V, seconds: Self::V) -> Self::V;
    fn seconds_sub(&self, t: Self::V, seconds: Self::V) -> Self::V;
    fn seconds_diff(&self, a: Self::V, b: Self::V) -> Self::V;
    fn milliseconds_diff(&self, a: Self::V, b: Self::V) -> Self::V;
    fn greatest(&self, a: Self::V, b: Self::V) -> Self::V;
    fn least(&self, a: Self::V, b: Self::V) -> Self::V;
    fn double(&self, a: Self::V) -> Self::V;
    fn floor(&self, a: Self::V) -> Self::V;
    fn mul(&self, a: Self::V, b: Self::V) -> Self::V;
    fn div(&self, a: Self::V, b: Self::V) -> Self::V;
    fn sub(&self, a: Self::V, b: Self::V) -> Self::V;
    fn is_not_null(&self, a: Self::V) -> Self::B;
    fn lt(&self, a: Self::V, b: Self::V) -> Self::B;
    fn gt(&self, a: Self::V, b: Self::V) -> Self::B;
    fn eq(&self, a: Self::V, b: Self::V) -> Self::B;
    fn all(&self, conditions: Vec<Self::B>) -> Self::B;
    fn case(&self, when: Self::B, then: Self::V, otherwise: Self::V) -> Self::V;
}

/// One flow row's spread, written once over [`Ops`].
struct Spread<O: Ops> {
    ops: O,
    bucket_seconds: i64,
    /// The row's timestamp, which closes its interval.
    time: O::V,
    /// The row's start column. Every share is a fraction of `[start_time, time]`.
    start_time: O::V,
    /// `time_slice(time)`: the bucket the row is booked in without spreading.
    home: O::V,
    /// True when the row's interval reaches into an earlier bucket than its own.
    spreads: O::B,
    /// Later of `start_time` and the window's first bucket.
    credited_start: O::V,
    /// Seconds from `home` back to the earliest emitted bucket.
    first_offset: O::V,
}

impl<O: Ops> Spread<O> {
    fn new(
        ops: O,
        bucket_seconds: i64,
        time: O::V,
        start_time: O::V,
        end_time: O::V,
        window_start: O::V,
    ) -> Self {
        let o = &ops;
        let bucket = bucket_seconds.max(1);
        let home = o.time_slice(time.clone(), bucket);
        let spreads = o.all(vec![
            o.is_not_null(start_time.clone()),
            o.is_not_null(end_time.clone()),
            o.lt(start_time.clone(), end_time),
            o.gt(
                o.milliseconds_diff(home.clone(), start_time.clone()),
                o.int(0),
            ),
        ]);
        let credited_start = o.greatest(start_time.clone(), o.time_slice(window_start, bucket));
        let reach = o.int((MAX_BUCKETS - 1) * bucket);
        let earliest = o.greatest(credited_start.clone(), o.seconds_sub(home.clone(), reach));
        let first_offset = o.seconds_diff(o.time_slice(earliest, bucket), home.clone());
        Self {
            ops,
            bucket_seconds: bucket,
            time,
            start_time,
            home,
            spreads,
            credited_start,
            first_offset,
        }
    }

    /// The first offset `k` the row expands into; the expansion runs up to 0 in steps of one
    /// bucket. A row that does not spread yields `k = 0` only.
    fn first_k(&self) -> O::V {
        let o = &self.ops;
        o.case(self.spreads.clone(), self.first_offset.clone(), o.int(0))
    }

    /// The bucket the expanded row at offset `k` books into.
    fn bucket(&self, k: O::V) -> O::V {
        self.ops.seconds_add(self.home.clone(), k)
    }

    /// The share of the (already sampled) volume `value` that falls in the bucket at offset `k`.
    fn share(&self, k: O::V, value: O::V) -> O::V {
        let o = &self.ops;
        let start = || self.start_time.clone();
        let duration = o.double(o.milliseconds_diff(self.time.clone(), start()));
        let elapsed = |boundary: O::V| {
            let fraction = o.div(o.milliseconds_diff(boundary, start()), duration.clone());
            o.floor(o.mul(value.clone(), fraction))
        };
        let bucket = self.bucket(k.clone());
        let upper = o.least(
            self.time.clone(),
            o.seconds_add(bucket.clone(), o.int(self.bucket_seconds)),
        );
        let lower = o.case(
            o.eq(k, self.first_offset.clone()),
            self.credited_start.clone(),
            bucket,
        );
        o.case(
            self.spreads.clone(),
            o.sub(elapsed(upper), elapsed(lower)),
            value.clone(),
        )
    }
}

/// A StarRocks expression and how tightly it binds, so an operand is parenthesized only
/// where precedence requires it.
#[derive(Clone)]
struct Expr {
    text: String,
    precedence: u8,
}

const ADDITIVE: u8 = 0;
const MULTIPLICATIVE: u8 = 1;
const ATOM: u8 = 2;

impl Expr {
    /// A column, literal, function call, or already parenthesized expression.
    fn atom(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            precedence: ATOM,
        }
    }

    /// Left-associative: the right operand needs parentheses at equal precedence.
    fn binary(lhs: Self, op: &str, rhs: Self, precedence: u8) -> Self {
        let wrap = |e: Self, min: u8| {
            if e.precedence >= min {
                e.text
            } else {
                format!("({})", e.text)
            }
        };
        Self {
            text: format!(
                "{} {op} {}",
                wrap(lhs, precedence),
                wrap(rhs, precedence + 1)
            ),
            precedence,
        }
    }
}

/// Renders [`Ops`] as StarRocks SQL.
struct Sql;

impl Ops for Sql {
    type V = Expr;
    type B = String;

    fn int(&self, n: i64) -> Expr {
        Expr::atom(n.to_string())
    }
    fn time_slice(&self, t: Expr, seconds: i64) -> Expr {
        Expr::atom(format!("time_slice({}, INTERVAL {seconds} SECOND)", t.text))
    }
    fn seconds_add(&self, t: Expr, seconds: Expr) -> Expr {
        Expr::atom(format!("seconds_add({}, {})", t.text, seconds.text))
    }
    fn seconds_sub(&self, t: Expr, seconds: Expr) -> Expr {
        Expr::atom(format!("seconds_sub({}, {})", t.text, seconds.text))
    }
    fn seconds_diff(&self, a: Expr, b: Expr) -> Expr {
        Expr::atom(format!("seconds_diff({}, {})", a.text, b.text))
    }
    fn milliseconds_diff(&self, a: Expr, b: Expr) -> Expr {
        Expr::atom(format!("milliseconds_diff({}, {})", a.text, b.text))
    }
    fn greatest(&self, a: Expr, b: Expr) -> Expr {
        Expr::atom(format!("GREATEST({}, {})", a.text, b.text))
    }
    fn least(&self, a: Expr, b: Expr) -> Expr {
        Expr::atom(format!("LEAST({}, {})", a.text, b.text))
    }
    fn double(&self, a: Expr) -> Expr {
        Expr::atom(format!("CAST({} AS DOUBLE)", a.text))
    }
    fn floor(&self, a: Expr) -> Expr {
        Expr::atom(format!("FLOOR({})", a.text))
    }
    fn mul(&self, a: Expr, b: Expr) -> Expr {
        Expr::binary(a, "*", b, MULTIPLICATIVE)
    }
    fn div(&self, a: Expr, b: Expr) -> Expr {
        Expr::binary(a, "/", b, MULTIPLICATIVE)
    }
    fn sub(&self, a: Expr, b: Expr) -> Expr {
        Expr::binary(a, "-", b, ADDITIVE)
    }
    fn is_not_null(&self, a: Expr) -> String {
        format!("{} IS NOT NULL", a.text)
    }
    fn lt(&self, a: Expr, b: Expr) -> String {
        format!("{} < {}", a.text, b.text)
    }
    fn gt(&self, a: Expr, b: Expr) -> String {
        format!("{} > {}", a.text, b.text)
    }
    fn eq(&self, a: Expr, b: Expr) -> String {
        format!("{} = {}", a.text, b.text)
    }
    fn all(&self, conditions: Vec<String>) -> String {
        format!("({})", conditions.join(" AND "))
    }
    fn case(&self, when: String, then: Expr, otherwise: Expr) -> Expr {
        Expr::atom(format!(
            "(CASE WHEN {when} THEN {} ELSE {} END)",
            then.text, otherwise.text
        ))
    }
}

/// The SQL that expands one flow row into the buckets it overlaps.
pub(super) struct FlowSpread(Spread<Sql>);

/// The lateral column holding an expanded row's bucket offset.
fn spread_k() -> Expr {
    Expr::atom("spread.k")
}

impl FlowSpread {
    /// `time`, `start_time` and `end_time` are the row's columns as the FROM clause names
    /// them. `window_start` is the query window's lower bound, as a StarRocks datetime literal.
    pub(super) fn new(
        bucket_seconds: i64,
        time: &str,
        start_time: &str,
        end_time: &str,
        window_start: &str,
    ) -> Self {
        Self(Spread::new(
            Sql,
            bucket_seconds,
            Expr::atom(time),
            Expr::atom(start_time),
            Expr::atom(end_time),
            Expr::atom(format!("CAST('{window_start}' AS DATETIME)")),
        ))
    }

    /// Appended to the FROM clause: one output row per bucket the flow overlaps. `spread.k` is
    /// that bucket's offset in seconds from the row's own bucket, from the earliest credited
    /// bucket up to 0. A row that does not spread yields `k = 0` only.
    pub(super) fn lateral(&self) -> String {
        format!(
            ", generate_series({}, 0, {}) AS spread(k)",
            self.0.first_k().text,
            self.0.bucket_seconds
        )
    }

    /// The bucket an expanded row books into.
    pub(super) fn bucket(&self) -> String {
        self.0.bucket(spread_k()).text
    }

    /// The share of the (already sampled) volume `value` that falls in this row's bucket.
    pub(super) fn share(&self, value: &str) -> String {
        self.0.share(spread_k(), Expr::atom(value)).text
    }

    /// `value` on the row's own bucket and NULL on the buckets it was spread into, so an
    /// aggregate that is not a volume sum sees each flow once, where it was booked.
    pub(super) fn home(&self, value: &str) -> String {
        format!("(CASE WHEN spread.k = 0 THEN {value} END)")
    }
}

#[cfg(test)]
mod tests;
