//! Select one analytics store for an entire query after resolving its window.

use super::{SqlDialect, cold::cold_table_for_entity, dialect};
use crate::{
    error::{Result, ServiceError},
    pagination::{CursorState, CursorStore, HybridCursor},
    parser::Entity,
    time::TimeRange,
};
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use std::collections::HashMap;

/// Existing string driver maps remain valid; hybrid adds a typed policy.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum AnalyticsDriver {
    Named(String),
    Policy(AnalyticsPolicy),
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "driver", rename_all = "snake_case", deny_unknown_fields)]
pub enum AnalyticsPolicy {
    Hybrid {
        #[serde(default = "default_hot_window_days")]
        hot_window_days: i64,
    },
}

fn default_hot_window_days() -> i64 {
    30
}

pub(crate) fn resolve(
    entity: &Entity,
    drivers: &HashMap<String, AnalyticsDriver>,
    window: Option<&TimeRange>,
    cursor: Option<&CursorState>,
    now: DateTime<Utc>,
) -> Result<(SqlDialect, Option<HybridCursor>)> {
    let table = cold_table_for_entity(entity);
    let policy = table.and_then(|table| drivers.get(table));
    if matches!(policy, Some(AnalyticsDriver::Named(name)) if name == "hybrid") {
        return Err(ServiceError::InvalidRequest(
            "hybrid driver requires a typed hot_window_days policy".into(),
        ));
    }
    let Some(AnalyticsDriver::Policy(AnalyticsPolicy::Hybrid { hot_window_days })) = policy else {
        if cursor.is_some_and(|state| state.hybrid.is_some()) {
            return Err(ServiceError::InvalidRequest(
                "hybrid cursor requires the same hybrid table policy; restart the query".into(),
            ));
        }
        let named_drivers = drivers
            .iter()
            .filter_map(|(table, driver)| match driver {
                AnalyticsDriver::Named(name) => Some((table.clone(), name.clone())),
                AnalyticsDriver::Policy(_) => None,
            })
            .collect();
        return Ok((dialect::resolve(entity, &named_drivers), None));
    };
    let table = table.expect("a hybrid policy has a physical table");
    let hot_duration = Duration::try_days(*hot_window_days)
        .filter(|_| *hot_window_days > 0)
        .ok_or_else(|| ServiceError::InvalidRequest("invalid hybrid hot_window_days".into()))?;
    let cutoff = now
        .checked_sub_signed(hot_duration)
        .ok_or_else(|| ServiceError::InvalidRequest("hybrid hot window is out of bounds".into()))?;

    let store = if let Some(state) = cursor {
        let pinned = state.hybrid.as_ref().ok_or_else(|| {
            ServiceError::InvalidRequest(
                "hybrid queries require a hybrid cursor; restart the query".into(),
            )
        })?;
        if pinned.table != table {
            return Err(ServiceError::InvalidRequest(
                "hybrid cursor table does not match this query".into(),
            ));
        }
        if pinned.store == CursorStore::Timescale && window.is_none_or(|range| range.start < cutoff)
        {
            return Err(ServiceError::InvalidRequest(
                "hybrid cursor hot window has expired; restart the query".into(),
            ));
        }
        pinned.store
    } else if window.is_some_and(|range| range.start >= cutoff) {
        CursorStore::Timescale
    } else {
        CursorStore::PgDuckdb
    };
    let dialect = match store {
        CursorStore::Timescale => SqlDialect::Postgres,
        CursorStore::PgDuckdb => SqlDialect::Duckdb,
    };
    Ok((
        dialect,
        Some(HybridCursor {
            store,
            table: table.into(),
        }),
    ))
}
