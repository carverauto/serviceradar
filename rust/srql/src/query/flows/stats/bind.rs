use super::*;
// Imported directly rather than via `use super::*`: stats.rs no longer references these
// itself, so an unused-import cleanup there silently breaks this file.
use crate::jsonb::DbJson;
use diesel::sql_types::{Jsonb, Nullable};

#[derive(Debug, Clone)]
pub(in crate::query::flows) enum FlowSqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Int(i64),
    IntArray(Vec<i64>),
    Timestamp(chrono::DateTime<chrono::Utc>),
}

impl FlowSqlBindValue {
    pub(in crate::query::flows) fn apply<'a>(
        &self,
        query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    ) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            FlowSqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            FlowSqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            FlowSqlBindValue::Int(value) => query.bind::<BigInt, _>(*value),
            FlowSqlBindValue::IntArray(values) => query.bind::<Array<BigInt>, _>(values.clone()),
            FlowSqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

pub(in crate::query::flows) fn bind_param_from_flow_stats(value: FlowSqlBindValue) -> BindParam {
    match value {
        FlowSqlBindValue::Text(v) => BindParam::Text(v),
        FlowSqlBindValue::TextArray(v) => BindParam::TextArray(v),
        FlowSqlBindValue::Int(v) => BindParam::Int(v),
        FlowSqlBindValue::IntArray(v) => BindParam::IntArray(v),
        FlowSqlBindValue::Timestamp(v) => BindParam::timestamptz(v),
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(in crate::query::flows) struct FlowStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(in crate::query::flows) result: Option<DbJson>,
}

pub(in crate::query::flows) struct FlowGroupedStatsSql {
    pub(in crate::query::flows) sql: String, // uses '?' placeholders for Diesel binds
    pub(in crate::query::flows) binds: Vec<FlowSqlBindValue>,
}

/// Rewrites ? placeholders to $1, $2, etc. for PostgreSQL (embedded/NIF mode).
pub(in crate::query::flows) fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}
