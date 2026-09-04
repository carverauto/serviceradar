//! Contract: the SQL an entity executes must carry `$n`, never `?`.
//!
//! Diesel sends `SqlQuery` text to Postgres verbatim. These entities used to
//! prepare SQL twice: tests exercised `to_sql_and_params`, while `execute`
//! bypassed it and retained `?`, including in `LIMIT ? OFFSET ?`. Build the
//! same Diesel query object that `execute` loads so this test covers the real
//! execution path.

use super::{
    addon_fleet, field_survey, plan_for, public_endpoints, threat_intel_matches, wifi_map,
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
    ];

    for (entity, query) in cases {
        let query = query.unwrap_or_else(|error| panic!("failed to build {entity} query: {error}"));
        let rendered = debug_query::<Pg, _>(&query).to_string();

        assert!(
            rendered.contains("LIMIT $"),
            "{entity} execute query did not use PostgreSQL placeholders: {rendered}"
        );
        assert!(
            !rendered.contains("LIMIT ?") && !rendered.contains("OFFSET ?"),
            "{entity} execute query retained question-mark placeholders: {rendered}"
        );
    }
}
