//! Contract: the SQL an entity EXECUTES must carry `$n`, never `?`.
//!
//! Diesel does not translate `?` for Postgres. `SqlQuery::walk_ast` pushes the
//! query string verbatim (`out.push_sql(&self.query)`) and each bind then
//! appends its own `$n`, so a `?` written by hand survives into the statement.
//!
//! That would be survivable if it failed loudly. It does not: `?` is a valid
//! operator character in Postgres (jsonb containment), so an untranslated
//! placeholder is parsed as a prefix operator and the error lands on the NEXT
//! token, naming neither the placeholder nor the column. Measured against CNPG:
//!
//! ```text
//! ... WHERE ep.deleted_at IS NULL AND ep.ip = ? ORDER BY ep.observed_at DESC
//! ERROR:  syntax error at or near "ORDER"
//! ```
//!
//! Five entities shipped with this defect -- `public_endpoints`, `addon_fleet`,
//! `field_survey`, `wifi_map`, `threat_intel_matches`. Every query against them
//! failed, unfiltered ones included, because they all end `LIMIT ? OFFSET ?`.
//!
//! Nothing caught it, for a reason worth stating plainly: each module built its
//! SQL twice, and every unit test called `to_sql_and_params`, which was the copy
//! that rewrote correctly. So the first test below is necessary but was never
//! sufficient -- it would have passed throughout. The second is the one that
//! bites, because it asserts the *structure* that made the defect invisible:
//! there must be exactly one preparation path.

use super::plan_for;
use crate::parser::Entity;
use crate::query::{
    QueryPlan, addon_fleet, field_survey, public_endpoints, threat_intel_matches, virtualization,
    wifi_map,
};

/// One representative query per raw-SQL entity. Each module is covered by at
/// least one query carrying a bound filter, so a regression is reachable rather
/// than merely present -- an entity tested only by `LIMIT ?` would still catch
/// this defect, but not one confined to `filter_condition`.
const RAW_SQL_ENTITY_QUERIES: &[&str] = &[
    "in:public_endpoints limit:5",
    "in:addon_fleet limit:5",
    "in:field_survey_sessions limit:5",
    "in:wifi_sites limit:5",
    "in:threat_intel_matches limit:5",
    "in:virtualization_hosts limit:5",
];

#[test]
fn executed_sql_never_carries_a_bare_question_mark() {
    let mut checked = 0;

    for query in RAW_SQL_ENTITY_QUERIES {
        let plan = plan_for(query);
        let (sql, bind_count) = translate(&plan)
            .unwrap_or_else(|| panic!("{query} reached no raw-SQL module; fix the dispatch below"));

        assert!(
            !sql.contains('?'),
            "{query} would execute a bare `?`. Postgres parses that as an \
             operator and rejects the FOLLOWING token, so this ships as a \
             syntax error that names neither the placeholder nor the column: {sql}"
        );

        for n in 1..=bind_count {
            assert!(
                sql.contains(&format!("${n}")),
                "{query} binds {bind_count} values but the SQL has no ${n}: {sql}"
            );
        }

        checked += 1;
    }

    // Guards against the list silently emptying, which would make every
    // assertion above vacuous.
    assert_eq!(
        checked,
        RAW_SQL_ENTITY_QUERIES.len(),
        "not every listed query was checked"
    );
}

/// The structural half, and the one that actually prevents recurrence.
///
/// `to_sql_and_params` is the single preparation point. An `execute` that calls
/// `build_sql` itself has re-created the split that hid the original defect, and
/// the behavioural test above would keep passing while it did.
#[test]
fn no_entity_prepares_its_executed_sql_a_second_time() {
    const SOURCES: &[(&str, &str)] = &[
        ("public_endpoints", include_str!("../public_endpoints.rs")),
        ("addon_fleet", include_str!("../addon_fleet.rs")),
        ("field_survey", include_str!("../field_survey.rs")),
        ("wifi_map", include_str!("../wifi_map.rs")),
        (
            "threat_intel_matches",
            include_str!("../threat_intel_matches.rs"),
        ),
        (
            "identity/merge_audit",
            include_str!("../identity/merge_audit.rs"),
        ),
        (
            "identity/device_identifiers",
            include_str!("../identity/device_identifiers.rs"),
        ),
        (
            "identity/device_revival_audit",
            include_str!("../identity/device_revival_audit.rs"),
        ),
        (
            "identity/reconciliation_runs",
            include_str!("../identity/reconciliation_runs.rs"),
        ),
        (
            "identity/evidence_edges",
            include_str!("../identity/evidence_edges.rs"),
        ),
    ];

    for (name, source) in SOURCES {
        assert!(
            !source.contains("sql_query(&built.sql)"),
            "{name} passes `built.sql` to sql_query, so it executes SQL that \
             `to_sql_and_params` never rewrote. Call to_sql_and_params instead \
             of building a second copy."
        );
    }
}

/// Returns the translated SQL and its bind count, or `None` if the plan does not
/// belong to a raw-SQL module this contract covers.
fn translate(plan: &QueryPlan) -> Option<(String, usize)> {
    let result = match plan.entity {
        Entity::PublicEndpoints => public_endpoints::to_sql_and_params(plan),
        Entity::AddonFleet => addon_fleet::to_sql_and_params(plan),
        Entity::ThreatIntelMatches => threat_intel_matches::to_sql_and_params(plan),
        Entity::FieldSurveySessions
        | Entity::FieldSurveyRasters
        | Entity::FieldSurveyArtifacts
        | Entity::FieldSurveyRfObservations
        | Entity::FieldSurveyPoseSamples
        | Entity::FieldSurveyRfPoseMatches
        | Entity::FieldSurveySpectrumObservations => field_survey::to_sql_and_params(plan),
        Entity::WifiSites
        | Entity::WifiSiteSnapshots
        | Entity::WifiAccessPoints
        | Entity::WifiControllers
        | Entity::WifiRadiusGroups
        | Entity::WifiFleetHistory
        | Entity::WifiSiteReferences => wifi_map::to_sql_and_params(plan),
        Entity::VirtualizationHosts
        | Entity::VirtualizationClusters
        | Entity::VirtualizationGuests
        | Entity::VirtualizationDatastores
        | Entity::VirtualizationHostDisks
        | Entity::VirtualizationNetworkInterfaces
        | Entity::VirtualizationStorageSystems => virtualization::to_sql_and_params(plan),
        _ => return None,
    };

    let (sql, binds) = result.unwrap_or_else(|err| panic!("failed to translate: {err:?}"));
    Some((sql, binds.len()))
}
