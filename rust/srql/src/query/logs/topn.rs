use super::{
    RECOGNIZED_SEVERITY_TEXTS, build_query, collect_base_params, enforce_list_limit,
    severity_match_any,
};
use crate::{
    error::{Result, ServiceError},
    models::LogRow,
    parser::{Filter, FilterOp, FilterValue, OrderDirection},
    query::{
        BindParam, QueryPlan, bind_sql_param, max_dollar_placeholder, reconcile_limit_offset_binds,
        shift_dollar_placeholders,
    },
    schema::logs::dsl::id as col_id,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

const MAX_TOPN_SEVERITY_VALUES: usize = 16;
const MAX_TOPN_SEVERITY_ANY_BRANCHES: usize = 32;
const MAX_TOPN_CANDIDATE_ROWS: i64 = 100_000;
const TOPN_ALIAS: &str = "severity_topn";

struct TopNBranch {
    plan: QueryPlan,
    numeric_fallback: bool,
}

struct SeverityAnyValues {
    text_filter_index: usize,
    number_filter_index: usize,
    text_values: Vec<String>,
    number_values: Vec<i32>,
}

pub(super) struct SeverityTopNQuery {
    sql: String,
    params: Vec<BindParam>,
}

impl SeverityTopNQuery {
    pub(super) fn into_parts(self) -> (String, Vec<BindParam>) {
        (self.sql, self.params)
    }

    pub(super) async fn load(self, conn: &mut AsyncPgConnection) -> Result<Vec<LogRow>> {
        let mut query: BoxedSqlQuery<'_, Pg, SqlQuery> = sql_query(self.sql).into_boxed::<Pg>();
        for param in self.params {
            query = bind_sql_param(query, param)?;
        }

        query
            .load::<LogRow>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))
    }
}

/// Build an index-friendly top-N query for timestamp-sorted, multi-severity logs.
///
/// PostgreSQL cannot preserve effective-timestamp ordering across multiple values
/// of the leading `lower(severity_text)` index key. The ordinary `= ANY($n)`
/// plan therefore favors the timestamp-only index and filters millions of rows.
/// Each scalar text or numeric-fallback branch can use its corresponding
/// severity/effective-timestamp index in order; merging the bounded, disjoint
/// branch heads preserves the exact global top-N result.
pub(super) fn build(plan: &QueryPlan) -> Result<Option<SeverityTopNQuery>> {
    if !has_supported_timestamp_order(plan) {
        return Ok(None);
    }

    let Some(mut branches) = severity_branches(plan)? else {
        return Ok(None);
    };

    let Some(branch_limit) = plan.limit.checked_add(plan.offset) else {
        return Ok(None);
    };
    if branch_limit <= 0 {
        return Ok(None);
    }
    let Some(candidate_rows) = branch_limit.checked_mul(branches.len() as i64) else {
        return Ok(None);
    };
    if candidate_rows > MAX_TOPN_CANDIDATE_ROWS {
        return Ok(None);
    }

    let mut sql_branches = Vec::with_capacity(branches.len());
    let mut params = Vec::new();

    for branch in &mut branches {
        branch.plan.limit = branch_limit;
        branch.plan.offset = 0;

        let query = build_query(&branch.plan)?;
        let query = if branch.numeric_fallback {
            super::filters::apply_numeric_severity_fallback_guard(query)
        } else {
            query
        };
        let query = match primary_timestamp_direction(plan) {
            OrderDirection::Asc => query.then_order_by(col_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_id.desc()),
        }
        .limit(branch_limit)
        .offset(0);
        let branch_sql = crate::query::diesel_sql(&query)?;
        let mut branch_params = collect_base_params(&branch.plan)?;
        if branch.numeric_fallback {
            branch_params.push(BindParam::TextArray(
                RECOGNIZED_SEVERITY_TEXTS
                    .iter()
                    .map(|value| (*value).to_string())
                    .collect(),
            ));
        }
        reconcile_limit_offset_binds(&branch_sql, &mut branch_params, branch_limit, 0)?;

        let expected = max_dollar_placeholder(&branch_sql);
        if expected != branch_params.len() {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "severity top-N branch expects {expected} binds but {} were collected",
                branch_params.len()
            )));
        }

        sql_branches.push(format!(
            "({})",
            shift_dollar_placeholders(&branch_sql, params.len())
        ));
        params.extend(branch_params);
    }

    let limit_placeholder = params.len() + 1;
    let offset_placeholder = params.len() + 2;
    let sql = format!(
        "SELECT {TOPN_ALIAS}.* FROM ({}) AS {TOPN_ALIAS} ORDER BY {} LIMIT ${limit_placeholder} OFFSET ${offset_placeholder}",
        sql_branches.join(" UNION ALL "),
        outer_order_sql(plan)
    );
    params.push(BindParam::Int(plan.limit));
    params.push(BindParam::Int(plan.offset));

    let expected = max_dollar_placeholder(&sql);
    if expected != params.len() {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "severity top-N query expects {expected} binds but {} were collected",
            params.len()
        )));
    }

    Ok(Some(SeverityTopNQuery { sql, params }))
}

fn severity_branches(plan: &QueryPlan) -> Result<Option<Vec<TopNBranch>>> {
    if severity_match_any(plan) {
        return severity_any_branches(plan);
    }

    let Some((filter_index, values)) = severity_values(plan)? else {
        return Ok(None);
    };

    Ok(Some(
        values
            .into_iter()
            .map(|value| {
                let mut branch = plan.clone();
                branch.filters[filter_index] = Filter {
                    field: branch.filters[filter_index].field.clone(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar(value),
                };
                TopNBranch {
                    plan: branch,
                    numeric_fallback: false,
                }
            })
            .collect(),
    ))
}

fn severity_any_branches(plan: &QueryPlan) -> Result<Option<Vec<TopNBranch>>> {
    let Some(values) = severity_any_values(plan)? else {
        return Ok(None);
    };
    let branch_count = values
        .text_values
        .len()
        .saturating_add(values.number_values.len());
    if branch_count > MAX_TOPN_SEVERITY_ANY_BRANCHES {
        return Ok(None);
    }

    let mut branches = Vec::with_capacity(branch_count);
    for value in values.text_values {
        branches.push(TopNBranch {
            plan: severity_any_branch_plan(
                plan,
                values.text_filter_index,
                values.number_filter_index,
                Filter {
                    field: plan.filters[values.text_filter_index].field.clone(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar(value),
                },
                true,
            ),
            numeric_fallback: false,
        });
    }
    for value in values.number_values {
        branches.push(TopNBranch {
            plan: severity_any_branch_plan(
                plan,
                values.text_filter_index,
                values.number_filter_index,
                Filter {
                    field: "severity_number".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar(value.to_string()),
                },
                false,
            ),
            numeric_fallback: true,
        });
    }

    Ok(Some(branches))
}

fn severity_any_branch_plan(
    plan: &QueryPlan,
    text_filter_index: usize,
    number_filter_index: usize,
    replacement: Filter,
    text_branch: bool,
) -> QueryPlan {
    let replacement_index = if text_branch {
        text_filter_index
    } else {
        number_filter_index
    };
    let removed_index = if text_branch {
        number_filter_index
    } else {
        text_filter_index
    };
    let mut branch = plan.clone();
    branch.filters = plan
        .filters
        .iter()
        .enumerate()
        .filter_map(|(index, filter)| {
            if index == replacement_index {
                Some(replacement.clone())
            } else if index == removed_index || filter.field == "severity_match" {
                None
            } else {
                Some(filter.clone())
            }
        })
        .collect();
    branch
}

fn severity_any_values(plan: &QueryPlan) -> Result<Option<SeverityAnyValues>> {
    let mut text_match = None;
    let mut number_match = None;

    for (index, filter) in plan.filters.iter().enumerate() {
        if is_severity_field(&filter.field) {
            if text_match.is_some() || !matches!(filter.op, FilterOp::In) {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, filter.value.as_list()?.len())?;
            let mut values = Vec::new();
            for value in filter.value.as_list()? {
                let normalized = value.to_lowercase();
                if !values.contains(&normalized) {
                    values.push(normalized);
                }
            }
            text_match = Some((index, values));
        } else if filter.field == "severity_number" {
            if number_match.is_some() || !matches!(filter.op, FilterOp::In) {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, filter.value.as_list()?.len())?;
            let mut values = Vec::new();
            for value in filter.value.as_list()? {
                let parsed = value.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("severity_number list must be integers".into())
                })?;
                if !values.contains(&parsed) {
                    values.push(parsed);
                }
            }
            number_match = Some((index, values));
        }
    }

    let (Some((text_filter_index, text_values)), Some((number_filter_index, number_values))) =
        (text_match, number_match)
    else {
        return Ok(None);
    };
    if text_values.is_empty() || number_values.is_empty() {
        return Ok(None);
    }
    // Numeric fallback intentionally includes unrecognized text. If a caller
    // also selected that same unrecognized text explicitly, UNION ALL could
    // return the row from both branches. The card helpers only emit canonical
    // recognized values, so keep that common path indexable and let custom
    // values use the ordinary OR query.
    if text_values
        .iter()
        .any(|value| !RECOGNIZED_SEVERITY_TEXTS.contains(&value.as_str()))
    {
        return Ok(None);
    }

    Ok(Some(SeverityAnyValues {
        text_filter_index,
        number_filter_index,
        text_values,
        number_values,
    }))
}

fn has_supported_timestamp_order(plan: &QueryPlan) -> bool {
    matches!(plan.order.as_slice().first(), Some(first) if first.field == "timestamp")
        && plan
            .order
            .iter()
            .all(|clause| clause.field == "timestamp" || clause.field == "severity_number")
}

fn primary_timestamp_direction(plan: &QueryPlan) -> OrderDirection {
    plan.order
        .as_slice()
        .first()
        .expect("top-N eligibility requires timestamp ordering")
        .direction
}

fn severity_values(plan: &QueryPlan) -> Result<Option<(usize, Vec<String>)>> {
    let mut matched = None;

    for (index, filter) in plan.filters.iter().enumerate() {
        if !is_severity_field(&filter.field) {
            continue;
        }
        if matched.is_some() || !matches!(filter.op, FilterOp::In) {
            return Ok(None);
        }

        enforce_list_limit(&filter.field, filter.value.as_list()?.len())?;
        let mut values = Vec::new();
        for value in filter.value.as_list()? {
            let normalized = value.to_lowercase();
            if !values.contains(&normalized) {
                values.push(normalized);
            }
        }

        if values.is_empty() || values.len() > MAX_TOPN_SEVERITY_VALUES {
            return Ok(None);
        }
        matched = Some((index, values));
    }

    Ok(matched)
}

fn is_severity_field(field: &str) -> bool {
    matches!(field, "severity_text" | "severity" | "level")
}

fn outer_order_sql(plan: &QueryPlan) -> String {
    let mut order = plan
        .order
        .iter()
        .map(|clause| {
            let expression = match clause.field.as_str() {
                "timestamp" => {
                    format!("COALESCE({TOPN_ALIAS}.observed_timestamp, {TOPN_ALIAS}.\"timestamp\")")
                }
                "severity_number" => format!("{TOPN_ALIAS}.severity_number"),
                _ => unreachable!("top-N eligibility rejects unsupported ordering"),
            };
            let direction = match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            format!("{expression} {direction}")
        })
        .collect::<Vec<_>>();
    let tie_direction = match primary_timestamp_direction(plan) {
        OrderDirection::Asc => "ASC",
        OrderDirection::Desc => "DESC",
    };
    order.push(format!("{TOPN_ALIAS}.id {tie_direction}"));
    order.join(", ")
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_TOPN_CANDIDATE_ROWS, MAX_TOPN_SEVERITY_ANY_BRANCHES, MAX_TOPN_SEVERITY_VALUES, build,
    };
    use crate::{
        parser::{Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
        query::{BindParam, logs::test_support::data_plan, max_dollar_placeholder},
    };

    fn severity_filter(values: &[&str]) -> Filter {
        Filter {
            field: "severity_text".into(),
            op: FilterOp::In,
            value: FilterValue::List(values.iter().map(|value| (*value).to_string()).collect()),
        }
    }

    fn timestamp_order(direction: OrderDirection) -> OrderClause {
        OrderClause {
            field: "timestamp".into(),
            direction,
        }
    }

    #[test]
    fn builds_indexable_union_and_deduplicates_case_aliases() {
        let mut plan = data_plan(vec![severity_filter(&[
            "fatal", "FATAL", "critical", "Critical",
        ])]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];
        plan.limit = 20;

        let built = build(&plan).unwrap().expect("top-N query");
        let (sql, params) = built.into_parts();

        assert_eq!(sql.matches(" UNION ALL ").count(), 1, "{sql}");
        assert_eq!(
            sql.matches("lower(\"logs\".\"severity_text\") = lower(")
                .count(),
            2,
            "{sql}"
        );
        assert!(!sql.contains(" = ANY("), "{sql}");
        assert!(
            sql.contains(
                "ORDER BY COALESCE(severity_topn.observed_timestamp, severity_topn.\"timestamp\") DESC, severity_topn.id DESC"
            ),
            "{sql}"
        );
        assert_eq!(
            sql.matches("\"logs\".\"id\" DESC").count(),
            2,
            "every scalar branch must use the same unique tie-breaker: {sql}"
        );
        assert_eq!(
            params
                .iter()
                .filter_map(|param| match param {
                    BindParam::Text(value) => Some(value.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>(),
            vec!["fatal", "critical"]
        );
        assert_eq!(max_dollar_placeholder(&sql), params.len());
    }

    #[test]
    fn preserves_offset_with_branch_cap_and_outer_pagination() {
        let mut plan = data_plan(vec![severity_filter(&["fatal", "critical"])]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];
        plan.limit = 20;
        plan.offset = 40;

        let (sql, params) = build(&plan).unwrap().unwrap().into_parts();

        assert_eq!(
            params
                .iter()
                .filter(|param| matches!(param, BindParam::Int(60)))
                .count(),
            2,
            "each branch must retain limit + offset rows"
        );
        assert_eq!(
            params
                .iter()
                .filter(|param| matches!(param, BindParam::Int(0)))
                .count(),
            2,
            "branch offsets must start at zero"
        );
        assert!(matches!(
            params.get(params.len() - 2),
            Some(BindParam::Int(20))
        ));
        assert!(matches!(params.last(), Some(BindParam::Int(40))));
        assert_eq!(max_dollar_placeholder(&sql), params.len());
    }

    #[test]
    fn supports_ascending_and_descending_timestamp_order() {
        for (direction, expected) in [(OrderDirection::Asc, "ASC"), (OrderDirection::Desc, "DESC")]
        {
            let mut plan = data_plan(vec![severity_filter(&["fatal", "critical"])]);
            plan.order = vec![timestamp_order(direction)];

            let (sql, _) = build(&plan).unwrap().unwrap().into_parts();
            assert!(
                sql.contains(&format!(
                    "ORDER BY COALESCE(severity_topn.observed_timestamp, severity_topn.\"timestamp\") {expected}, severity_topn.id {expected}"
                )),
                "{sql}"
            );
            assert_eq!(
                sql.matches(&format!("\"logs\".\"id\" {expected}")).count(),
                2,
                "every scalar branch must use the primary timestamp direction: {sql}"
            );
        }
    }

    #[test]
    fn repeats_extra_filters_in_each_branch_with_contiguous_binds() {
        let mut plan = data_plan(vec![
            severity_filter(&["fatal", "critical"]),
            Filter {
                field: "source".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("internal".into()),
            },
        ]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];

        let (sql, params) = build(&plan).unwrap().unwrap().into_parts();

        assert_eq!(
            params
                .iter()
                .filter(|param| matches!(param, BindParam::Text(value) if value == "internal"))
                .count(),
            2
        );
        assert_eq!(max_dollar_placeholder(&sql), params.len());
        for placeholder in 1..=params.len() {
            assert!(
                sql.contains(&format!("${placeholder}")),
                "missing ${placeholder}: {sql}"
            );
        }
    }

    #[test]
    fn falls_back_for_more_than_bounded_unique_values() {
        let values = (0..=MAX_TOPN_SEVERITY_VALUES)
            .map(|index| format!("severity-{index}"))
            .collect::<Vec<_>>();
        let mut plan = data_plan(vec![Filter {
            field: "severity_text".into(),
            op: FilterOp::In,
            value: FilterValue::List(values),
        }]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];

        assert!(build(&plan).unwrap().is_none());
    }

    #[test]
    fn bounds_total_rows_materialized_across_branches() {
        let mut plan = data_plan(vec![severity_filter(&["fatal", "critical"])]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];
        plan.limit = MAX_TOPN_CANDIDATE_ROWS / 2;

        assert!(build(&plan).unwrap().is_some());

        plan.limit += 1;
        assert!(build(&plan).unwrap().is_none());

        plan.limit = i64::MAX;
        plan.offset = 1;
        assert!(build(&plan).unwrap().is_none());
    }

    #[test]
    fn falls_back_without_explicit_timestamp_first_order() {
        let mut plan = data_plan(vec![severity_filter(&["fatal", "critical"])]);
        assert!(build(&plan).unwrap().is_none());

        plan.order = vec![OrderClause {
            field: "severity_number".into(),
            direction: OrderDirection::Desc,
        }];
        assert!(build(&plan).unwrap().is_none());
    }

    #[test]
    fn falls_back_when_another_severity_filter_is_present() {
        let mut plan = data_plan(vec![
            severity_filter(&["fatal", "critical"]),
            Filter {
                field: "level".into(),
                op: FilterOp::NotEq,
                value: FilterValue::Scalar("debug".into()),
            },
        ]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];

        assert!(build(&plan).unwrap().is_none());
    }

    #[test]
    fn builds_disjoint_text_and_numeric_fallback_branches() {
        let mut plan = data_plan(vec![
            severity_filter(&["error", "severity_number_error"]),
            Filter {
                field: "severity_number".into(),
                op: FilterOp::In,
                value: FilterValue::List(vec!["17".into(), "18".into(), "17".into()]),
            },
            Filter {
                field: "severity_match".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("any".into()),
            },
        ]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];

        let (sql, params) = build(&plan).unwrap().unwrap().into_parts();

        assert_eq!(sql.matches(" UNION ALL ").count(), 3, "{sql}");
        assert_eq!(
            sql.matches("lower(\"logs\".\"severity_text\") = lower(")
                .count(),
            2,
            "text matches must be scalar branches: {sql}"
        );
        assert_eq!(
            sql.matches("\"logs\".\"severity_number\" = $").count(),
            2,
            "numeric matches must be scalar branches: {sql}"
        );
        assert_eq!(
            sql.matches("\"logs\".\"severity_text\" IS NULL").count(),
            2,
            "each numeric branch must allow absent text: {sql}"
        );
        assert_eq!(
            sql.matches("lower(\"logs\".\"severity_text\") != ALL(")
                .count(),
            2,
            "each numeric branch must reject recognized text: {sql}"
        );
        assert!(
            !sql.contains("lower(\"logs\".\"severity_text\") = ANY(")
                && !sql.contains("\"logs\".\"severity_number\" = ANY("),
            "branches replace the broad selected-text/numeric OR scan: {sql}"
        );
        assert_eq!(
            params
                .iter()
                .filter(|param| matches!(param, BindParam::TextArray(values) if values.len() == 38))
                .count(),
            2,
            "each numeric fallback branch binds the recognized-text guard"
        );
        assert_eq!(max_dollar_placeholder(&sql), params.len());
    }

    #[test]
    fn repeats_service_filter_with_correct_branch_bind_order() {
        let mut plan = data_plan(vec![
            severity_filter(&["error"]),
            Filter {
                field: "severity_number".into(),
                op: FilterOp::In,
                value: FilterValue::List(vec!["17".into()]),
            },
            Filter {
                field: "severity_match".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("any".into()),
            },
            Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("serviceradar-core".into()),
            },
        ]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];

        let (sql, params) = build(&plan).unwrap().unwrap().into_parts();

        assert_eq!(
            sql.matches("\"logs\".\"service_name\" = $").count(),
            2,
            "{sql}"
        );
        assert_eq!(max_dollar_placeholder(&sql), params.len());
        assert!(matches!(&params[2], BindParam::Text(value) if value == "error"));
        assert!(matches!(&params[3], BindParam::Text(value) if value == "serviceradar-core"));
        assert!(matches!(&params[8], BindParam::Int(17)));
        assert!(matches!(&params[9], BindParam::Text(value) if value == "serviceradar-core"));
        assert!(matches!(&params[10], BindParam::TextArray(values) if values.len() == 38));
    }

    #[test]
    fn falls_back_when_any_text_is_unrecognized_or_branch_count_is_excessive() {
        let mut custom = data_plan(vec![
            severity_filter(&["custom-severity"]),
            Filter {
                field: "severity_number".into(),
                op: FilterOp::In,
                value: FilterValue::List(vec!["17".into()]),
            },
            Filter {
                field: "severity_match".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("any".into()),
            },
        ]);
        custom.order = vec![timestamp_order(OrderDirection::Desc)];
        assert!(build(&custom).unwrap().is_none());

        let text_count = MAX_TOPN_SEVERITY_ANY_BRANCHES / 2;
        let number_count = MAX_TOPN_SEVERITY_ANY_BRANCHES - text_count + 1;
        let mut excessive = data_plan(vec![
            severity_filter(&super::super::RECOGNIZED_SEVERITY_TEXTS[..text_count]),
            Filter {
                field: "severity_number".into(),
                op: FilterOp::In,
                value: FilterValue::List(
                    (0..number_count).map(|value| value.to_string()).collect(),
                ),
            },
            Filter {
                field: "severity_match".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("any".into()),
            },
        ]);
        excessive.order = vec![timestamp_order(OrderDirection::Desc)];
        assert!(build(&excessive).unwrap().is_none());
    }

    #[test]
    fn retains_existing_error_for_more_than_global_list_limit() {
        let mut plan = data_plan(vec![severity_filter(&vec![
            "FATAL";
            super::super::MAX_LIST_FILTER_VALUES
                + 1
        ])]);
        plan.order = vec![timestamp_order(OrderDirection::Desc)];

        assert!(build(&plan).is_err());
    }
}
