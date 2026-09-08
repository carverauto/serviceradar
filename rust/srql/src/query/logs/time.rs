use super::LogsQuery;
use crate::parser::{OrderClause, OrderDirection};
use crate::schema::logs::dsl::severity_number as col_severity_number;
use diesel::dsl::sql;
use diesel::expression::SqlLiteral;
use diesel::prelude::*;
use diesel::sql_types::Timestamptz;

pub(super) fn effective_timestamp_expr() -> SqlLiteral<Timestamptz> {
    sql::<Timestamptz>("COALESCE(observed_timestamp, timestamp)")
}

pub(super) fn effective_timestamp_sql() -> &'static str {
    "COALESCE(observed_timestamp, timestamp)"
}

pub(super) fn apply_ordering<'a>(mut query: LogsQuery<'a>, order: &[OrderClause]) -> LogsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(effective_timestamp_expr().asc()),
                    OrderDirection::Desc => query.order(effective_timestamp_expr().desc()),
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
                    OrderDirection::Asc => query.then_order_by(effective_timestamp_expr().asc()),
                    OrderDirection::Desc => query.then_order_by(effective_timestamp_expr().desc()),
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
            .order(effective_timestamp_expr().desc())
            .then_order_by(col_severity_number.desc());
    }

    query
}
