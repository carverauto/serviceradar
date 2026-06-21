use crate::error::{Result, ServiceError};

macro_rules! apply_text_filter {
    ($query:expr, $filter:expr, $column:expr) => {{
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.eq(value))
            }
            crate::parser::FilterOp::NotEq => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.ne(value)))
            }
            crate::parser::FilterOp::Like => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ilike(value))
            }
            crate::parser::FilterOp::NotLike => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.not_ilike(value)))
            }
            crate::parser::FilterOp::In => {
                let values = $filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    $query
                } else {
                    $query.filter($column.eq_any(values))
                }
            }
            crate::parser::FilterOp::NotIn => {
                let values = $filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    $query
                } else {
                    let column = $column;
                    $query.filter(column.clone().is_null().or(column.ne_all(values)))
                }
            }
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    $filter.op
                )));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

macro_rules! apply_text_filter_no_lists {
    ($query:expr, $filter:expr, $column:expr, $error:expr) => {{
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.eq(value))
            }
            crate::parser::FilterOp::NotEq => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.ne(value)))
            }
            crate::parser::FilterOp::Like => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ilike(value))
            }
            crate::parser::FilterOp::NotLike => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.not_ilike(value)))
            }
            crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
                return Err(crate::error::ServiceError::InvalidRequest($error.into()));
            }
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    $filter.op
                )));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

macro_rules! apply_eq_filter {
    ($query:expr, $filter:expr, $column:expr, $value:expr, $error:expr) => {{
        let __value = $value;
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => $query.filter($column.eq(__value.clone())),
            crate::parser::FilterOp::NotEq => $query.filter($column.ne(__value)),
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest($error.into()));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

pub(crate) fn is_negated_membership_op(op: &crate::parser::FilterOp) -> bool {
    matches!(
        op,
        &crate::parser::FilterOp::NotEq | &crate::parser::FilterOp::NotIn
    )
}

/// Normalizes a MAC address value by stripping non-hex characters and lowercasing.
///
/// When `allow_wildcards` is true, `%` and `_` (SQL LIKE wildcards) are preserved.
/// E.g. `"0E-EA-14-32-D2-78"` → `"0eea1432d278"`, `"%0e:ea%"` → `"%0eea%"`.
pub(crate) fn normalize_mac_value(raw: &str, allow_wildcards: bool) -> Result<String> {
    let mut normalized = String::with_capacity(raw.len());

    for ch in raw.chars() {
        if ch.is_ascii_hexdigit() {
            normalized.push(ch.to_ascii_lowercase());
        } else if allow_wildcards && (ch == '%' || ch == '_') {
            normalized.push(ch);
        }
    }

    if normalized.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mac filter expects hex digits".into(),
        ));
    }

    Ok(normalized)
}

pub(crate) fn build_other_rollup_sql(
    inner: &str,
    rank_order_sql: &str,
    top_json_parts: &[String],
    other_json_parts: &[String],
    output_alias: &str,
    limit: i64,
) -> String {
    let other_sort_rn = limit + 1;

    format!(
        "WITH grouped AS ({inner}), ranked AS (SELECT grouped.*, ROW_NUMBER() OVER ({rank_order_sql}) AS rn FROM grouped) SELECT {output_alias} FROM (SELECT rn AS sort_rn, jsonb_build_object({top_json_args}) AS {output_alias} FROM ranked WHERE rn <= {limit} UNION ALL SELECT {other_sort_rn} AS sort_rn, jsonb_build_object({other_json_args}) AS {output_alias} FROM ranked WHERE rn > {limit} HAVING COUNT(*) > 0) final ORDER BY sort_rn",
        top_json_args = top_json_parts.join(", "),
        other_json_args = other_json_parts.join(", "),
    )
}
