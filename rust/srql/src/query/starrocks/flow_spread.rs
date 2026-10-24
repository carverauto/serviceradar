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
//! * Totals are exact. Bucket `k` receives `FLOOR(v * c(hi_k)) - FLOOR(v * c(lo_k))`, where
//!   `c` is the fraction of the interval elapsed at a boundary. Neighbouring buckets evaluate
//!   the same expression on the same boundary, so the shares telescope to
//!   `FLOOR(v * 1.0) - FLOOR(v * 0.0) = v` for an integer volume, and the rounding residue
//!   stays inside the flow.
//! * A row keeps its whole value in its own bucket unless it has a `start_time`, an
//!   `end_time` after it, and starts before its own bucket. NULL starts, zero or negative
//!   durations, and flows inside one bucket are booked exactly as before.
//! * Only the first returned bucket onward is credited: a flow that began before the window
//!   contributes the share that overlaps the window's buckets and nothing else.
//! * The fan-out is bounded twice: by the window (no bucket before the first returned one is
//!   generated) and by [`MAX_BUCKETS`]. A flow longer than that is treated as having started
//!   `MAX_BUCKETS` buckets before the one it ended in, so its whole value lands in its last
//!   `MAX_BUCKETS` buckets.
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
    /// Where the interval starts once [`MAX_BUCKETS`] is applied.
    span_start: String,
    /// Where the credited part of the interval starts: `span_start`, clamped to the first
    /// returned bucket.
    credited_start: String,
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
        let span_start = format!(
            "GREATEST({start_time}, seconds_sub({home}, {reach}))",
            reach = (MAX_BUCKETS - 1) * bucket
        );
        let credited_start = format!(
            "GREATEST({span_start}, {first})",
            first = slice(&format!("CAST('{window_start}' AS DATETIME)"))
        );
        Self {
            bucket_seconds: bucket,
            home,
            time: time.to_string(),
            spreads,
            span_start,
            credited_start,
        }
    }

    /// Appended to the FROM clause: one output row per bucket the flow overlaps. `spread.k` is
    /// that bucket's offset in seconds from the row's own bucket, from the earliest credited
    /// bucket up to 0. A row that does not spread yields `k = 0` only.
    pub(super) fn lateral(&self) -> String {
        format!(
            ", generate_series(CASE WHEN {spreads} THEN seconds_diff(time_slice({credited}, \
INTERVAL {bucket} SECOND), {home}) ELSE 0 END, 0, {bucket}) AS spread(k)",
            spreads = self.spreads,
            credited = self.credited_start,
            bucket = self.bucket_seconds,
            home = self.home
        )
    }

    /// The bucket an expanded row books into.
    pub(super) fn bucket(&self) -> String {
        format!("seconds_add({}, spread.k)", self.home)
    }

    /// The share of the (already sampled) volume `value` that falls in this row's bucket.
    pub(super) fn share(&self, value: &str) -> String {
        let bucket = self.bucket();
        let start = &self.span_start;
        let duration = format!("CAST(milliseconds_diff({}, {start}) AS DOUBLE)", self.time);
        let elapsed = |boundary: String| {
            format!("FLOOR({value} * (milliseconds_diff({boundary}, {start}) / {duration}))")
        };
        let upper = elapsed(format!(
            "LEAST({}, seconds_add({bucket}, {}))",
            self.time, self.bucket_seconds
        ));
        let lower = elapsed(format!("GREATEST({}, {bucket})", self.credited_start));
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
