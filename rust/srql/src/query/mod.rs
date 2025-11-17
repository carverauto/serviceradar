mod devices;
mod events;
mod logs;

use crate::{
    config::AppConfig,
    db::PgPool,
    error::{Result, ServiceError},
    pagination::{decode_cursor, encode_cursor},
    parser::{self, Entity, Filter, OrderClause, QueryAst},
    time::TimeRange,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;

#[derive(Clone)]
pub struct QueryEngine {
    pool: PgPool,
    config: Arc<AppConfig>,
}

impl QueryEngine {
    pub fn new(pool: PgPool, config: Arc<AppConfig>) -> Self {
        Self { pool, config }
    }

    pub fn config(&self) -> &AppConfig {
        &self.config
    }

    pub async fn execute_query(&self, request: QueryRequest) -> Result<QueryResponse> {
        let ast = parser::parse(&request.query)?;
        let plan = self.plan(&request, ast)?;
        let mut conn = self
            .pool
            .get()
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;

        let results = match plan.entity {
            Entity::Devices => devices::execute(&mut conn, &plan).await?,
            Entity::Events => events::execute(&mut conn, &plan).await?,
            Entity::Logs => logs::execute(&mut conn, &plan).await?,
        };

        let pagination = self.build_pagination(&plan, results.len() as i64);
        Ok(QueryResponse {
            results,
            pagination,
            error: None,
        })
    }

    pub async fn translate(&self, request: TranslateRequest) -> Result<TranslateResponse> {
        let ast = parser::parse(&request.query)?;
        let synthetic = QueryRequest {
            query: request.query.clone(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
        };
        let plan = self.plan(&synthetic, ast)?;

        let sql = match plan.entity {
            Entity::Devices => devices::to_debug_sql(&plan)?,
            Entity::Events => events::to_debug_sql(&plan)?,
            Entity::Logs => logs::to_debug_sql(&plan)?,
        };

        Ok(TranslateResponse {
            sql,
            params: Vec::new(),
        })
    }

    fn plan(&self, request: &QueryRequest, ast: QueryAst) -> Result<QueryPlan> {
        let limit = self.determine_limit(request.limit.or(ast.limit));
        let offset = request
            .cursor
            .as_deref()
            .map(decode_cursor)
            .transpose()?
            .unwrap_or(0)
            .max(0);
        let time_range = ast
            .time_filter
            .map(|spec| spec.resolve(Utc::now()))
            .transpose()?;

        Ok(QueryPlan {
            entity: ast.entity,
            filters: ast.filters,
            order: ast.order,
            limit,
            offset,
            time_range,
        })
    }

    fn determine_limit(&self, candidate: Option<i64>) -> i64 {
        let default = self.config.default_limit;
        let max = self.config.max_limit;
        candidate.unwrap_or(default).clamp(1, max)
    }

    fn build_pagination(&self, plan: &QueryPlan, fetched: i64) -> PaginationMeta {
        let next_cursor = if fetched >= plan.limit {
            Some(encode_cursor(plan.offset.saturating_add(plan.limit)))
        } else {
            None
        };

        let prev_cursor = if plan.offset > 0 {
            let prev = plan.offset.saturating_sub(plan.limit);
            Some(encode_cursor(prev))
        } else {
            None
        };

        PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        }
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
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum QueryDirection {
    Next,
    Prev,
}

impl Default for QueryDirection {
    fn default() -> Self {
        QueryDirection::Next
    }
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
    pub params: Vec<String>,
}
