//! The counter derivative used by both chart buckets and bounded latest-rate reads.
//! Keep backend differences here: the warehouse does not retain the producer ceiling.

pub(super) fn postgres_ceiling(metadata: &str) -> String {
    format!(
        r"CASE
      WHEN {metadata}->>'max_counter_rate_per_second' ~ '^[0-9]+(\.[0-9]+){{0,1}}$'
        THEN ({metadata}->>'max_counter_rate_per_second')::double precision
      ELSE NULL
    END"
    )
}

pub(super) fn postgres(value: &str, previous: &str, elapsed: &str) -> String {
    format!(
        "CASE
      WHEN counter_width = 32 AND ({value} >= 4294967296 OR {previous} >= 4294967296) THEN NULL
      WHEN {value} >= {previous}
        AND (max_rate_per_second IS NULL
          OR ({value} - {previous}) / {elapsed} <= max_rate_per_second)
        THEN ({value} - {previous}) / {elapsed}
      WHEN counter_width = 64 AND max_rate_per_second IS NOT NULL
        AND ({value} + 18446744073709551616 - {previous}) / {elapsed} <= max_rate_per_second
        THEN ({value} + 18446744073709551616 - {previous}) / {elapsed}
      WHEN counter_width = 32
        AND ({value} + 4294967296 - {previous}) / {elapsed} <= COALESCE(max_rate_per_second, 4294967296)
        THEN ({value} + 4294967296 - {previous}) / {elapsed}
      WHEN counter_width IS NULL AND {previous} < 4294967296
        AND ({value} + 4294967296 - {previous}) / {elapsed} <= COALESCE(max_rate_per_second, 4294967296)
        THEN ({value} + 4294967296 - {previous}) / {elapsed}
      ELSE NULL
    END"
    )
}

pub(super) fn warehouse(value: &str, previous: &str, elapsed: &str) -> String {
    let wrapped = format!("({value} + 4294967296 - {previous}) / {elapsed}");
    format!(
        "CASE \
WHEN counter_width = 32 AND ({value} >= 4294967296 OR {previous} >= 4294967296) THEN NULL \
WHEN {value} >= {previous} THEN ({value} - {previous}) / {elapsed} \
WHEN counter_width = 32 AND {wrapped} <= 4294967296 THEN {wrapped} \
WHEN counter_width IS NULL AND {previous} < 4294967296 AND {wrapped} <= 4294967296 THEN {wrapped} \
ELSE NULL END"
    )
}
