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

/// The SQL that expands one flow row into the buckets it overlaps.
pub(super) struct FlowSpread {
    bucket_seconds: i64,
    /// `time_slice(<row time>)`: the bucket the row is booked in without spreading.
    home: String,
    /// The row's timestamp, qualified as the FROM clause requires.
    time: String,
    /// True when the row's interval reaches into an earlier bucket than its own.
    spreads: String,
    /// The row's start column. Every share is a fraction of `[start_time, time]`.
    start_time: String,
    /// Later of `start_time` and the window's first bucket.
    credited_start: String,
    /// Seconds from `home` back to the earliest emitted bucket.
    first_offset: String,
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
        let bucket = bucket_seconds.max(1);
        let slice = |expr: &str| format!("time_slice({expr}, INTERVAL {bucket} SECOND)");
        let home = slice(time);
        let spreads = format!(
            "({start_time} IS NOT NULL AND {end_time} IS NOT NULL AND {start_time} < {end_time} \
AND milliseconds_diff({home}, {start_time}) > 0)"
        );
        let credited_start = format!(
            "GREATEST({start_time}, {first})",
            first = slice(&format!("CAST('{window_start}' AS DATETIME)"))
        );
        let first_offset = format!(
            "seconds_diff(time_slice(GREATEST({credited_start}, seconds_sub({home}, {reach})), \
INTERVAL {bucket} SECOND), {home})",
            reach = (MAX_BUCKETS - 1) * bucket
        );
        Self {
            bucket_seconds: bucket,
            home,
            time: time.to_string(),
            spreads,
            start_time: start_time.to_string(),
            credited_start,
            first_offset,
        }
    }

    /// Appended to the FROM clause: one output row per bucket the flow overlaps. `spread.k` is
    /// that bucket's offset in seconds from the row's own bucket, from the earliest credited
    /// bucket up to 0. A row that does not spread yields `k = 0` only.
    pub(super) fn lateral(&self) -> String {
        format!(
            ", generate_series(CASE WHEN {spreads} THEN {first_offset} ELSE 0 END, 0, {bucket}) \
AS spread(k)",
            spreads = self.spreads,
            first_offset = self.first_offset,
            bucket = self.bucket_seconds
        )
    }

    /// The bucket an expanded row books into.
    pub(super) fn bucket(&self) -> String {
        format!("seconds_add({}, spread.k)", self.home)
    }

    /// The share of the (already sampled) volume `value` that falls in this row's bucket.
    pub(super) fn share(&self, value: &str) -> String {
        let bucket = self.bucket();
        let start = &self.start_time;
        let duration = format!("CAST(milliseconds_diff({}, {start}) AS DOUBLE)", self.time);
        let elapsed = |boundary: String| {
            format!("FLOOR({value} * (milliseconds_diff({boundary}, {start}) / {duration}))")
        };
        let upper = elapsed(format!(
            "LEAST({}, seconds_add({bucket}, {}))",
            self.time, self.bucket_seconds
        ));
        let lower = elapsed(format!(
            "(CASE WHEN spread.k = {} THEN {} ELSE {bucket} END)",
            self.first_offset, self.credited_start
        ));
        format!(
            "(CASE WHEN {spreads} THEN {upper} - {lower} ELSE {value} END)",
            spreads = self.spreads
        )
    }

    /// `value` on the row's own bucket and NULL on the buckets it was spread into, so an
    /// aggregate that is not a volume sum sees each flow once, where it was booked.
    pub(super) fn home(&self, value: &str) -> String {
        format!("(CASE WHEN spread.k = 0 THEN {value} END)")
    }
}
