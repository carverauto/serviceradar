//! Execution coverage for grouped device stats.
//!
//! These exist because the translation-only tests in `rust/srql` cannot catch
//! the failure they guard: `build_grouped_stats_query` emits `?` placeholders,
//! and only the translate path ran them through `rewrite_placeholders`. The
//! execute path handed the raw SQL to `diesel::sql_query`, whose `.bind()`
//! supplies values but never rewrites the text -- so every *filtered* grouped
//! query was a Postgres syntax error in production while the unit tests passed.
//!
//! Anything here that filters and groups at the same time is therefore load
//! bearing; an unfiltered grouped query binds nothing and would stay green.

mod support;

use srql::query::{QueryDirection, QueryRequest};
use support::{read_json, with_srql_harness};

fn request(query: &str) -> QueryRequest {
    QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    }
}

/// Pulls `{group_value: count}` out of a grouped stats response.
fn group_counts(body: &serde_json::Value, key: &str, alias: &str) -> Vec<(String, i64)> {
    let mut pairs: Vec<(String, i64)> = body["results"]
        .as_array()
        .unwrap_or_else(|| panic!("'results' missing or not an array. Body: {body}"))
        .iter()
        .map(|row| {
            let group = row[key]
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| row[key].to_string());
            let count = row[alias]
                .as_i64()
                .unwrap_or_else(|| panic!("'{alias}' missing or not an integer in {row}"));
            (group, count)
        })
        .collect();
    pairs.sort();
    pairs
}

#[tokio::test(flavor = "multi_thread")]
async fn grouped_device_stats_execute_against_postgres() {
    with_srql_harness(|harness| async move {
        // Unfiltered: binds nothing, so this passed even before the fix.
        let (status, body) = read_json(
            harness
                .query(request("in:devices stats:count() as total by type limit:100"))
                .await,
        )
        .await;
        assert_eq!(status, http::StatusCode::OK, "grouping by type: {body}");
        assert!(
            !body["results"].as_array().unwrap().is_empty(),
            "expected at least one type group: {body}"
        );

        // Grouping by a tag sub-key -- the capability this PR adds.
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices include_inactive:true stats:count() as total by tags.role limit:100",
                ))
                .await,
        )
        .await;
        assert_eq!(status, http::StatusCode::OK, "grouping by tags.role: {body}");
        assert_eq!(
            group_counts(&body, "tags.role", "total"),
            vec![
                ("Unknown".to_string(), 1),
                ("core".to_string(), 1),
                ("edge".to_string(), 2)
            ],
            "the device with no tags belongs in the Unknown bucket: {body}"
        );

        // Filter AND group: this is the combination that was a syntax error.
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices include_inactive:true tags.site:DFW stats:count() as total by tags.role limit:100",
                ))
                .await,
        )
        .await;
        assert_eq!(
            status,
            http::StatusCode::OK,
            "filtered grouped query must execute, not fail on a raw ?: {body}"
        );
        assert_eq!(
            group_counts(&body, "tags.role", "total"),
            vec![("core".to_string(), 1), ("edge".to_string(), 2)],
            "only the three DFW-tagged devices should survive the filter: {body}"
        );

        // A filter on a plain column with a grouped stats clause hit the same
        // bug, and predates the tag work entirely.
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices vendor_name:Cisco stats:count() as total by type limit:100",
                ))
                .await,
        )
        .await;
        assert_eq!(
            status,
            http::StatusCode::OK,
            "filtering by a column while grouping must execute: {body}"
        );
        assert!(
            !body["results"].as_array().unwrap().is_empty(),
            "expected Cisco devices to group by type: {body}"
        );

        // Bare `tags:<key>` existence, which the grouped path spells with
        // jsonb_exists precisely so placeholder rewriting cannot mangle it.
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices include_inactive:true tags:role stats:count() as total by type limit:100",
                ))
                .await,
        )
        .await;
        assert_eq!(
            status,
            http::StatusCode::OK,
            "tag-existence filter must execute: {body}"
        );
        let total: i64 = body["results"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["total"].as_i64().unwrap_or_default())
            .sum();
        assert_eq!(
            total, 3,
            "three devices carry a role tag; the untagged one must not count: {body}"
        );
    })
    .await;
}

/// Postgres JSONB keys are case-sensitive and the fixtures store `Gate`, not
/// `gate`. Lowercasing the key anywhere in the pipeline turns both of these
/// into silent empty/Unknown results rather than an error.
#[tokio::test(flavor = "multi_thread")]
async fn jsonb_sub_key_lookups_are_case_sensitive_end_to_end() {
    with_srql_harness(|harness| async move {
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices include_inactive:true stats:count() as total by tags.Gate limit:100",
                ))
                .await,
        )
        .await;
        assert_eq!(status, http::StatusCode::OK, "grouping by tags.Gate: {body}");
        assert_eq!(
            group_counts(&body, "tags.Gate", "total"),
            vec![
                ("A1".to_string(), 2),
                ("B2".to_string(), 1),
                ("Unknown".to_string(), 1)
            ],
            "group-by must read the key as written: {body}"
        );

        let (status, body) = read_json(
            harness
                .query(request("in:devices include_inactive:true tags.Gate:A1"))
                .await,
        )
        .await;
        assert_eq!(status, http::StatusCode::OK, "filtering by tags.Gate: {body}");
        assert_eq!(
            body["results"].as_array().unwrap().len(),
            2,
            "filter must read the key as written, matching the group-by: {body}"
        );
    })
    .await;
}

/// `tags.<key>:(a,b)` had no list form at all; only Eq/LIKE were implemented.
#[tokio::test(flavor = "multi_thread")]
async fn tag_sub_key_list_filter_executes() {
    with_srql_harness(|harness| async move {
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices include_inactive:true tags.role:(edge,core)",
                ))
                .await,
        )
        .await;
        assert_eq!(status, http::StatusCode::OK, "tags.role list form: {body}");
        assert_eq!(
            body["results"].as_array().unwrap().len(),
            3,
            "expected every role-tagged device: {body}"
        );

        // Negated: a device missing the key entirely is "not in" the list, so
        // it has to survive rather than being dropped by NULL semantics.
        let (status, body) = read_json(
            harness
                .query(request(
                    "in:devices include_inactive:true !tags.role:(edge)",
                ))
                .await,
        )
        .await;
        assert_eq!(
            status,
            http::StatusCode::OK,
            "negated tags.role list form: {body}"
        );
        assert_eq!(
            body["results"].as_array().unwrap().len(),
            2,
            "the core device and the untagged device should both remain: {body}"
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn tag_sub_key_wildcard_filter_executes_as_like() {
    with_srql_harness(|harness| async move {
        let (status, body) = read_json(
            harness
                .query(request("in:devices include_inactive:true tags.role:%dg%"))
                .await,
        )
        .await;
        assert_eq!(status, http::StatusCode::OK, "tags.role wildcard: {body}");
        assert_eq!(
            body["results"].as_array().unwrap().len(),
            2,
            "the wildcard should match both edge-tagged devices: {body}"
        );

        let (status, body) = read_json(
            harness
                .query(request("in:devices include_inactive:true !tags.role:%dg%"))
                .await,
        )
        .await;
        assert_eq!(
            status,
            http::StatusCode::OK,
            "negated tags.role wildcard: {body}"
        );
        assert_eq!(
            body["results"].as_array().unwrap().len(),
            2,
            "the core and untagged devices should survive negated LIKE: {body}"
        );
    })
    .await;
}
