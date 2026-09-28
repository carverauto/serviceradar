use super::LogsQuery;
use crate::parser::{OrderClause, OrderDirection};
use crate::schema::logs::dsl::severity_number as col_severity_number;
use diesel::dsl::sql;
use diesel::expression::SqlLiteral;
use diesel::prelude::*;
use diesel::sql_types::Timestamptz;

/// The column a log line is windowed and ordered by: the event time (`timestamp`).
///
/// Both backends' severity rollups bucket by `timestamp` (`logs_severity_stats_5m` on CNPG,
/// the warehouse rollup on StarRocks), so a card and a list can only agree if the raw list
/// and stats windows use the same column. `observed_timestamp` is the collection instant, kept
/// for display, not for window membership or ordering.
pub(super) fn log_timestamp_expr() -> SqlLiteral<Timestamptz> {
    sql::<Timestamptz>("timestamp")
}

pub(super) fn log_timestamp_sql() -> &'static str {
    "timestamp"
}

pub(super) fn apply_ordering<'a>(mut query: LogsQuery<'a>, order: &[OrderClause]) -> LogsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(log_timestamp_expr().asc()),
                    OrderDirection::Desc => query.order(log_timestamp_expr().desc()),
                },
                "severity_number" => match clause.direction {
                    OrderDirection::Asc => query.order(col_severity_number.asc()),
                    OrderDirection::Desc => query.order(col_severity_number.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(log_timestamp_expr().asc()),
                    OrderDirection::Desc => query.then_order_by(log_timestamp_expr().desc()),
                },
                "severity_number" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_severity_number.asc()),
                    OrderDirection::Desc => query.then_order_by(col_severity_number.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query
            .order(log_timestamp_expr().desc())
            .then_order_by(col_severity_number.desc());
    }

    query
}
