//! Contract: the SQL an entity executes must carry `$n`, never `?`.
//!
//! Diesel sends `SqlQuery` text to Postgres verbatim. These entities used to
//! prepare SQL twice: tests exercised `to_sql_and_params`, while `execute`
//! bypassed it and retained `?`, including in `LIMIT ? OFFSET ?`. Build the
//! same Diesel query object that `execute` loads so this test covers the real
//! execution path.

use super::{
    addon_fleet, field_survey, flows, plan_for, public_endpoints, threat_intel_matches,
    wifi_map,
};
use diesel::{debug_query, pg::Pg};

#[test]
fn raw_sql_execute_queries_use_postgres_placeholders() {
    let cases = [
        (
            "public_endpoints",
            public_endpoints::execution_query(&plan_for("in:public_endpoints limit:10")),
        ),
        (
            "addon_fleet",
            addon_fleet::execution_query(&plan_for("in:addon_fleet limit:10")),
        ),
        (
            "field_survey",
            field_survey::execution_query(&plan_for("in:field_survey_sessions limit:10")),
        ),
        (
            "wifi_map",
            wifi_map::execution_query(&plan_for("in:wifi_sites limit:10")),
        ),
        (
            "threat_intel_matches",
            threat_intel_matches::execution_query(&plan_for("in:threat_intel_matches limit:10")),
        ),
        // Flows stats builds its own SQL rather than sharing an entity `build_sql`, and
        // `time:last_1h` is what puts `?::timestamptz` into it -- the clause the execute
        // path shipped unrewritten until this case was added.
        (
            "flows_stats",
            flows::execution_query(&plan_for(
                "in:flows time:last_1h stats:sum(bytes_total) as bytes by app",
            )),
        ),
    ];

    for (entity, query) in cases {
        let query = query.unwrap_or_else(|error| panic!("failed to build {entity} query: {error}"));
        let rendered = debug_query::<Pg, _>(&query).to_string();

        // Checked over the whole statement, not just LIMIT/OFFSET: the flows stats
        // regression put its `?` in the time-range predicate
        // (`f.time >= ?::timestamptz`), which a LIMIT-only assertion passes straight
        // over. Postgres fails at the token AFTER the placeholder, so the error names
        // neither the placeholder nor the column.
        assert!(
            !contains_bare_placeholder(&rendered),
            "{entity} execute query retained a question-mark placeholder: {rendered}"
        );
        // Control: without a `$n` the assertion above is vacuous -- a query carrying no
        // binds at all would pass it while proving nothing.
        assert!(
            rendered.contains('$'),
            "{entity} execute query bound no parameters, so the check above proves nothing: {rendered}"
        );
    }
}

/// True when `sql` still carries a placeholder Diesel will not translate.
///
/// Skips single-quoted literals, and treats `??` as the escaped jsonb-exists operator
/// rather than two placeholders, so neither produces a false positive.
fn contains_bare_placeholder(sql: &str) -> bool {
    let bytes = sql.as_bytes();
    let mut i = 0;
    let mut in_literal = false;
    while i < bytes.len() {
        match bytes[i] {
            b'\'' => in_literal = !in_literal,
            b'?' if !in_literal => {
                if bytes.get(i + 1) == Some(&b'?') {
                    i += 2;
                    continue;
                }
                return true;
            }
            _ => {}
        }
        i += 1;
    }
    false
}
