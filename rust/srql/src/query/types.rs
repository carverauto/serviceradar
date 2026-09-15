use crate::{
    parser::{Entity, Filter, OrderClause},
    time::TimeRange,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "t", content = "v", rename_all = "snake_case")]
pub enum BindParam {
    Text(String),
    TextArray(Vec<String>),
    IntArray(Vec<i64>),
    Bool(bool),
    Int(i64),
    Float(f64),
    Timestamptz(String),
    Uuid(uuid::Uuid),
    Date(String),
}

impl BindParam {
    pub(crate) fn timestamptz(value: chrono::DateTime<Utc>) -> Self {
        Self::Timestamptz(value.to_rfc3339())
    }

    /// A `date` bind, formatted `YYYY-MM-DD` (ISO 8601), for entities such
    /// as `sweep_coverage` whose time column is a real `date` column rather
    /// than `timestamptz` (issue 4167).
    pub(crate) fn date(value: chrono::NaiveDate) -> Self {
        Self::Date(value.format("%Y-%m-%d").to_string())
    }
}

#[derive(Debug, Clone)]
pub struct QueryPlan {
    pub entity: Entity,
    pub filters: Vec<Filter>,
    pub order: Vec<OrderClause>,
    pub limit: i64,
    pub offset: i64,
    pub time_range: Option<TimeRange>,
    pub stats: Option<crate::parser::StatsSpec>,
    pub downsample: Option<crate::parser::DownsampleSpec>,
    /// Rollup stats type for querying pre-computed CAGGs (e.g., "severity", "summary", "availability")
    pub rollup_stats: Option<String>,
    pub other: bool,
    pub include_deleted: bool,
    /// SQL dialect for this plan. Default postgres keeps existing builders
    /// byte-identical. DuckDB is set from the caller's per-entity driver map.
    pub dialect: SqlDialect,
}

/// SQL dialect selected from the analytics-store driver map.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SqlDialect {
    #[default]
    Postgres,
    Duckdb,
}

impl SqlDialect {
    pub(crate) fn is_postgres(&self) -> bool {
        matches!(self, Self::Postgres)
    }

    pub(crate) fn is_duckdb(&self) -> bool {
        matches!(self, Self::Duckdb)
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum QueryDirection {
    #[default]
    Next,
    Prev,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct QueryRequest {
    pub query: String,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub direction: QueryDirection,
    #[serde(default)]
    pub mode: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TranslateRequest {
    pub query: String,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub direction: QueryDirection,
    #[serde(default)]
    pub mode: Option<String>,
}

impl From<TranslateRequest> for QueryRequest {
    fn from(request: TranslateRequest) -> Self {
        Self {
            query: request.query,
            limit: request.limit,
            cursor: request.cursor,
            direction: request.direction,
            mode: request.mode,
        }
    }
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct PaginationMeta {
    pub next_cursor: Option<String>,
    pub prev_cursor: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct QueryResponse {
    pub results: Vec<Value>,
    pub pagination: PaginationMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranslateResponse {
    pub sql: String,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub params: Vec<BindParam>,
    pub pagination: PaginationMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub viz: Option<super::viz::VizMeta>,
    /// Omitted when postgres so existing JSON stays byte-identical.
    #[serde(skip_serializing_if = "SqlDialect::is_postgres")]
    pub dialect: SqlDialect,
    /// Concrete hybrid route. Omitted for the existing single-store modes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub read_store: Option<crate::pagination::CursorStore>,
    /// Physical source and resolved window for manifest-backed Parquet reads.
    /// The caller must choose files before the analytics head plans the SQL.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analytics_table: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_range: Option<TimeRange>,
}
