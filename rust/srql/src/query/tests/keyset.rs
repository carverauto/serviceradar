use super::*;
use crate::pagination::{KeysetDirection, decode_position, encode_keyset_cursor};

fn request(query: &str, limit: i64, cursor: Option<String>) -> QueryRequest {
    QueryRequest {
        limit: Some(limit),
        cursor,
        ..request_for(query)
    }
}

fn keyset_cursor(entity: &str, direction: KeysetDirection, key: &str) -> String {
    encode_keyset_cursor(entity, "uid", direction, key, &test_config().cursor_secret)
        .expect("keyset cursor")
}

fn translate(query: &str, cursor: Option<String>) -> crate::error::Result<TranslateResponse> {
    translate_request(&test_config(), request(query, 50, cursor))
}

#[test]
fn uid_alone_orders_are_keyset_paged_without_offset() {
    for (query, entity, direction) in [
        ("in:devices sort:uid:asc", "devices", "asc"),
        ("in:devices sort:uid:asc sort:uid:asc", "devices", "asc"),
        ("in:devices sort:device_id:desc", "devices", "desc"),
        ("in:agents sort:uid:asc", "agents", "asc"),
        ("in:devices window_scan:true sort:uid:asc", "devices", "asc"),
    ] {
        let response = translate(query, None).expect("translate");
        let keyset = response.pagination.keyset.as_ref().expect(query);
        assert_eq!(
            (keyset.entity.as_str(), keyset.column.as_str()),
            (entity, "uid")
        );
        assert_eq!(keyset.direction, direction, "{query}");
        assert_eq!(response.pagination.next_cursor, None, "{query}");
        assert_eq!(response.pagination.prev_cursor, None, "{query}");
        assert!(
            !response.sql.contains("OFFSET"),
            "{query}: {}",
            response.sql
        );
        assert!(response.sql.contains("LIMIT"), "{query}: {}", response.sql);
        assert_eq!(max_dollar_placeholder(&response.sql), response.params.len());
    }
}

#[test]
fn other_orders_keep_offset_cursors() {
    for query in [
        "in:devices",
        "in:devices sort:hostname:asc sort:uid:asc",
        "in:devices sort:uid:asc sort:uid:desc",
        "in:agents",
        "in:interfaces sort:uid:asc",
        "in:devices sort:uid:asc stats:\"count() as total\"",
    ] {
        let response = translate(query, None).expect("translate");
        assert!(response.pagination.keyset.is_none(), "{query}");
        if !query.contains("stats:") {
            assert!(response.pagination.next_cursor.is_some(), "{query}");
        }
    }
}

#[test]
fn keyset_cursor_selects_rows_strictly_after_the_last_key() {
    for (query, entity, direction, op) in [
        (
            "in:devices sort:uid:asc",
            "devices",
            KeysetDirection::Asc,
            ">",
        ),
        (
            "in:devices sort:uid:desc",
            "devices",
            KeysetDirection::Desc,
            "<",
        ),
        (
            "in:agents sort:uid:asc",
            "agents",
            KeysetDirection::Asc,
            ">",
        ),
    ] {
        let cursor = keyset_cursor(entity, direction, "sr:dev-0042");
        let response = translate(query, Some(cursor)).expect("translate");

        assert!(
            response.sql.contains(&format!("\"uid\" {op} $")),
            "{query}: {}",
            response.sql
        );
        assert!(
            !response.sql.contains("OFFSET"),
            "{query}: {}",
            response.sql
        );
        assert!(
            response
                .params
                .iter()
                .any(|param| matches!(param, BindParam::Text(key) if key == "sr:dev-0042")),
            "{query}: {:?}",
            response.params
        );
        assert!(matches!(response.params.last(), Some(BindParam::Int(50))));
        assert_eq!(max_dollar_placeholder(&response.sql), response.params.len());
    }
}

#[test]
fn keyset_cursor_is_refused_by_a_differently_ordered_query() {
    let cursor = keyset_cursor("devices", KeysetDirection::Asc, "sr:dev-0042");
    for query in [
        "in:devices sort:uid:desc",
        "in:agents sort:uid:asc",
        "in:devices",
        "in:devices sort:hostname:asc sort:uid:asc",
    ] {
        let err = translate(query, Some(cursor.clone())).expect_err(query);
        assert!(err.to_string().contains("invalid cursor"), "{query}: {err}");
    }
}

#[test]
fn keyset_cursor_is_forward_only() {
    let cursor = keyset_cursor("devices", KeysetDirection::Asc, "sr:dev-0042");
    let request = QueryRequest {
        direction: QueryDirection::Prev,
        ..request("in:devices sort:uid:asc", 50, Some(cursor))
    };
    let err = translate_request(&test_config(), request).expect_err("prev");
    assert!(err.to_string().contains("forward-only"), "{err}");
}

#[test]
fn offset_cursor_on_a_keyset_query_is_read_at_its_offset() {
    let cursor = encode_cursor(150, &test_config().cursor_secret).expect("v2 cursor");
    let response = translate("in:devices sort:uid:asc", Some(cursor)).expect("translate");

    assert!(response.sql.contains("OFFSET"), "{}", response.sql);
    assert!(matches!(
        response.params.as_slice(),
        [.., BindParam::Int(50), BindParam::Int(150)]
    ));
    // The executor mints the continuation from this page's last row: a v3 cursor.
    assert!(response.pagination.keyset.is_some());
    assert_eq!(response.pagination.next_cursor, None);
}

/// Walks a uid-ordered selection larger than the cursor window. Each page is
/// planned from the previous cursor, read from an in-memory table the way the
/// emitted `uid > $key ORDER BY uid LIMIT n` reads it, and its cursor minted by
/// the executor path from the page's last row.
#[test]
fn keyset_walk_continues_past_the_offset_window() {
    let config = AppConfig {
        max_cursor_offset: 5,
        ..test_config()
    };
    let mut table: Vec<String> = (0..23).map(|n| format!("sr:dev-{n:04}")).collect();
    table.reverse();
    let mut sorted = table.clone();
    sorted.sort();

    let query = "in:devices sort:uid:asc";
    let mut cursor = None;
    let mut seen = Vec::new();
    let mut pages = 0;
    loop {
        pages += 1;
        assert!(pages <= 20, "walk did not terminate");
        let req = request(query, 4, cursor.take());
        let plan = build_query_plan(&config, &req, parser::parse(query).unwrap()).expect("plan");
        let keyset = plan.keyset.clone().expect("keyset plan");
        assert_eq!(plan.offset, 0);

        let rows: Vec<serde_json::Value> = sorted
            .iter()
            .filter(|uid| keyset.after.as_ref().is_none_or(|after| *uid > after))
            .take(plan.limit as usize)
            .map(|uid| serde_json::json!({ "uid": uid }))
            .collect();
        seen.extend(
            rows.iter()
                .map(|row| row["uid"].as_str().unwrap().to_string()),
        );

        let pagination =
            super::super::engine::keyset_pagination(&config, &plan, &keyset, &rows).expect("page");
        match pagination.next_cursor {
            Some(next) => cursor = Some(next),
            None => {
                assert!((rows.len() as i64) < plan.limit, "full page without cursor");
                break;
            }
        }
    }

    assert!(seen.len() as i64 > config.max_cursor_offset);
    assert_eq!(seen, sorted, "every row exactly once, in uid order");
}

#[test]
fn executor_mints_the_cursor_from_the_last_row_of_a_full_page() {
    let config = test_config();
    let req = request("in:agents sort:uid:desc", 2, None);
    let plan = build_query_plan(&config, &req, parser::parse(&req.query).unwrap()).unwrap();
    let keyset = plan.keyset.clone().unwrap();

    let full = [
        serde_json::json!({ "uid": "agent-b" }),
        serde_json::json!({ "uid": "agent-a" }),
    ];
    let next = super::super::engine::keyset_pagination(&config, &plan, &keyset, &full)
        .unwrap()
        .next_cursor
        .expect("full page cursor");
    match decode_position(&next, &config.cursor_secret, 0).unwrap() {
        crate::pagination::CursorPosition::Keyset(position) => {
            assert_eq!(position.key, "agent-a");
            assert_eq!(position.entity, "agents");
            assert_eq!(position.direction, KeysetDirection::Desc);
        }
        other => panic!("expected keyset position, got {other:?}"),
    }

    let short = &full[..1];
    assert!(
        super::super::engine::keyset_pagination(&config, &plan, &keyset, short)
            .unwrap()
            .next_cursor
            .is_none()
    );

    let keyless = [serde_json::json!({ "name": "a" }), serde_json::json!({})];
    assert!(super::super::engine::keyset_pagination(&config, &plan, &keyset, &keyless).is_err());
}
