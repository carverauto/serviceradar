use super::BindParam;
use crate::error::{Result, ServiceError};
use tracing::error;

pub(crate) fn max_dollar_placeholder(sql: &str) -> usize {
    let bytes = sql.as_bytes();
    let mut max = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        if bytes[i] != b'$' {
            i += 1;
            continue;
        }

        i += 1;
        if i >= bytes.len() || !bytes[i].is_ascii_digit() {
            continue;
        }

        let mut value = 0usize;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            value = value * 10 + (bytes[i] - b'0') as usize;
            i += 1;
        }

        max = max.max(value);
    }

    max
}

pub(crate) fn reconcile_limit_offset_binds(
    sql: &str,
    params: &mut Vec<BindParam>,
    limit: i64,
    offset: i64,
) -> Result<()> {
    let expected = max_dollar_placeholder(sql);
    let current = params.len();
    if expected < current {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "sql expects {expected} binds but {current} were collected"
        )));
    }

    match expected.saturating_sub(current) {
        0 => Ok(()),
        1 => {
            params.push(BindParam::Int(limit));
            Ok(())
        }
        2 => {
            params.push(BindParam::Int(limit));
            params.push(BindParam::Int(offset));
            Ok(())
        }
        extra => Err(ServiceError::Internal(anyhow::anyhow!(
            "unexpected bind arity gap: {extra}"
        ))),
    }
}

pub(crate) fn diesel_sql<T>(query: &T) -> Result<String>
where
    T: diesel::query_builder::QueryFragment<diesel::pg::Pg>,
{
    use diesel::query_builder::QueryBuilder as _;

    let backend = diesel::pg::Pg;
    let mut query_builder = <diesel::pg::Pg as diesel::backend::Backend>::QueryBuilder::default();
    diesel::query_builder::QueryFragment::<diesel::pg::Pg>::to_sql(
        query,
        &mut query_builder,
        &backend,
    )
    .map_err(|err| {
        error!(error = ?err, "failed to serialize diesel SQL");
        ServiceError::Internal(anyhow::anyhow!("failed to serialize SQL"))
    })?;

    Ok(query_builder.finish())
}

#[cfg(any(test, debug_assertions))]
pub(crate) fn diesel_bind_count<T>(query: &T) -> Result<usize>
where
    T: diesel::query_builder::QueryFragment<diesel::pg::Pg>,
{
    let rendered = diesel::debug_query::<diesel::pg::Pg, _>(query).to_string();
    let marker = "-- binds:";
    let binds = rendered
        .split_once(marker)
        .map(|(_, suffix)| suffix.trim())
        .ok_or_else(|| ServiceError::Internal(anyhow::anyhow!("missing binds marker")))?;

    count_debug_binds_list(binds).ok_or_else(|| {
        ServiceError::Internal(anyhow::anyhow!("failed to parse diesel debug bind list"))
    })
}

#[cfg(any(test, debug_assertions))]
fn count_debug_binds_list(binds: &str) -> Option<usize> {
    let bytes = binds.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }

    if i >= bytes.len() || bytes[i] != b'[' {
        return None;
    }

    let mut bracket_depth = 0i32;
    let mut paren_depth = 0i32;
    let mut brace_depth = 0i32;
    let mut in_string = false;
    let mut escape = false;
    let mut in_item = false;
    let mut count = 0usize;

    for &b in bytes[i..].iter() {
        if in_string {
            if escape {
                escape = false;
                continue;
            }

            if b == b'\\' {
                escape = true;
                continue;
            }

            if b == b'"' {
                in_string = false;
            }

            continue;
        }

        match b {
            b'"' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                in_string = true;
            }
            b'[' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                bracket_depth += 1;
                if bracket_depth == 1 {
                    in_item = false;
                }
            }
            b']' => {
                if bracket_depth == 1 && in_item {
                    count += 1;
                    in_item = false;
                }
                bracket_depth -= 1;
                if bracket_depth <= 0 {
                    break;
                }
            }
            b'{' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                brace_depth += 1
            }
            b'}' => brace_depth -= 1,
            b'(' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                paren_depth += 1
            }
            b')' => paren_depth -= 1,
            b',' => {
                if bracket_depth == 1 && brace_depth == 0 && paren_depth == 0 && in_item {
                    count += 1;
                    in_item = false;
                }
            }
            b if b.is_ascii_whitespace() => {}
            _ => {
                if bracket_depth == 1 && !in_item {
                    in_item = true;
                }
            }
        }
    }

    Some(count)
}
