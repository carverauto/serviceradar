use super::enforce_list_limit;
use super::stats::SqlBindValue;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
};

pub(super) fn build_text_clause(
    column: &str,
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} <> ?")
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} NOT ILIKE ?")
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, values.len())?;
            let mut placeholders = Vec::new();
            for value in values {
                placeholders.push("?".to_string());
                binds.push(SqlBindValue::Text(value));
            }
            let operator = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!("{column} {operator} ({})", placeholders.join(", "))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "text filter {column} does not support operator {:?}",
                filter.op
            )));
        }
    };

    Ok(Some((clause, binds)))
}

/// Case-insensitive variant of [`build_text_clause`]: equality and IN-list
/// comparisons wrap both the column and each placeholder in `lower()`, while
/// LIKE keeps ILIKE (already case-insensitive). Used for severity_text so the
/// raw-SQL stats path matches the diesel path and the lower()-grouped CAGG.
pub(super) fn build_lowered_text_clause(
    column: &str,
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("lower({column}) = lower(?)")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("lower({column}) <> lower(?)")
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} NOT ILIKE ?")
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, values.len())?;
            let mut placeholders = Vec::new();
            for value in values {
                placeholders.push("lower(?)".to_string());
                binds.push(SqlBindValue::Text(value));
            }
            let operator = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!("lower({column}) {operator} ({})", placeholders.join(", "))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "text filter {column} does not support operator {:?}",
                filter.op
            )));
        }
    };

    Ok(Some((clause, binds)))
}

pub(super) fn build_numeric_clause(
    column: &str,
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("invalid integer value".into()))?;
            binds.push(SqlBindValue::Int(value));
            if matches!(filter.op, FilterOp::Eq) {
                format!("{column} = ?")
            } else {
                format!("{column} <> ?")
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, values.len())?;
            let mut placeholders = Vec::new();
            for raw in values {
                let parsed = raw
                    .parse::<i32>()
                    .map_err(|_| ServiceError::InvalidRequest("invalid integer value".into()))?;
                placeholders.push("?".to_string());
                binds.push(SqlBindValue::Int(parsed));
            }
            let operator = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!("{column} {operator} ({})", placeholders.join(", "))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "severity_number only supports equality or IN comparisons".into(),
            ));
        }
    };

    Ok(Some((clause, binds)))
}
