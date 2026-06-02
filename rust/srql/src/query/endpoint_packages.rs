//! Query execution for endpoint package inventory rows.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EndpointPackageRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::endpoint_inventory_packages::dsl::{
        agent_id as col_agent_id, architecture as col_architecture, cpes as col_cpes,
        current as col_current, device_uid as col_device_uid, ecosystem as col_ecosystem,
        endpoint_inventory_packages, inserted_at as col_inserted_at, license as col_license,
        name as col_name, package_manager as col_package_manager, purl as col_purl,
        purl_canonical as col_purl_canonical, source as col_source, supplier as col_supplier,
        updated_at as col_updated_at, version as col_version,
    },
    time::TimeRange,
};
use diesel::dsl::not;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::{PgArrayExpressionMethods, PgTextExpressionMethods};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type EndpointPackagesTable = crate::schema::endpoint_inventory_packages::table;
type EndpointPackagesFromClause = FromClause<EndpointPackagesTable>;
type EndpointPackagesQuery<'a> = BoxedSelectStatement<
    'a,
    <EndpointPackagesTable as AsQuery>::SqlType,
    EndpointPackagesFromClause,
    Pg,
>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<EndpointPackageRow> = query
        .select(EndpointPackageRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EndpointPackageRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(EndpointPackageRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    super::reconcile_limit_offset_binds(&sql, &mut params, plan.limit, plan.offset)?;

    #[cfg(any(test, debug_assertions))]
    {
        let bind_count = super::diesel_bind_count(&query)?;
        if bind_count != params.len() {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "bind count mismatch (diesel {bind_count} vs params {})",
                params.len()
            )));
        }
    }

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::EndpointPackages => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by endpoint_packages query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<EndpointPackagesQuery<'static>> {
    let mut query = endpoint_inventory_packages.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_inserted_at.ge(*start).and(col_inserted_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    match filter.field.as_str() {
        "device_uid" | "device_id" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "name" | "package" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "version" => {
            query = apply_text_filter!(query, filter, col_version)?;
        }
        "architecture" | "arch" => {
            query = apply_text_filter!(query, filter, col_architecture)?;
        }
        "package_manager" | "manager" => {
            query = apply_text_filter!(query, filter, col_package_manager)?;
        }
        "ecosystem" => {
            query = apply_text_filter!(query, filter, col_ecosystem)?;
        }
        "purl" | "purl_canonical" | "canonical_purl" => {
            query = apply_text_filter!(query, filter, col_purl_canonical)?;
        }
        "raw_purl" => {
            query = apply_text_filter!(query, filter, col_purl)?;
        }
        "supplier" => {
            query = apply_text_filter!(query, filter, col_supplier)?;
        }
        "license" => {
            query = apply_text_filter!(query, filter, col_license)?;
        }
        "source" => {
            query = apply_text_filter!(query, filter, col_source)?;
        }
        "current" => {
            query = apply_current_filter(query, filter)?;
        }
        "cpe" | "cpes" => {
            query = apply_cpe_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for endpoint_packages: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_current_filter<'a>(
    query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_current.eq(value))),
        FilterOp::NotEq => Ok(query.filter(col_current.ne(value))),
        _ => Err(ServiceError::InvalidRequest(
            "current filter only supports equality".into(),
        )),
    }
}

fn apply_cpe_filter<'a>(
    query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    let values = cpe_values(&filter.value)?;

    if values.is_empty() {
        return Ok(query);
    }

    match filter.op {
        FilterOp::Eq | FilterOp::In => Ok(query.filter(col_cpes.overlaps_with(values))),
        FilterOp::NotEq | FilterOp::NotIn => Ok(query.filter(not(col_cpes.overlaps_with(values)))),
        _ => Err(ServiceError::InvalidRequest(
            "cpe filter only supports equality and membership".into(),
        )),
    }
}

fn cpe_values(value: &FilterValue) -> Result<Vec<String>> {
    match value {
        FilterValue::Scalar(item) => Ok(vec![item.clone()]),
        FilterValue::List(items) => Ok(items.clone()),
    }
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "0" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "device_uid" | "device_id" | "agent_id" | "name" | "package" | "version"
        | "architecture" | "arch" | "package_manager" | "manager" | "ecosystem" | "purl"
        | "purl_canonical" | "canonical_purl" | "raw_purl" | "supplier" | "license" | "source" => {
            collect_text_params(params, filter)
        }
        "current" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "cpe" | "cpes" => {
            let values = cpe_values(&filter.value)?;
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: EndpointPackagesQuery<'a>,
    order: &[OrderClause],
) -> EndpointPackagesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query
            .order(col_updated_at.desc())
            .then_order_by(col_name.asc());
    }

    query
}

fn apply_single_order<'a>(
    query: EndpointPackagesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointPackagesQuery<'a> {
    match field {
        "device_uid" | "device_id" => match direction {
            OrderDirection::Asc => query.order(col_device_uid.asc()),
            OrderDirection::Desc => query.order(col_device_uid.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.order(col_agent_id.asc()),
            OrderDirection::Desc => query.order(col_agent_id.desc()),
        },
        "name" | "package" => match direction {
            OrderDirection::Asc => query.order(col_name.asc()),
            OrderDirection::Desc => query.order(col_name.desc()),
        },
        "version" => match direction {
            OrderDirection::Asc => query.order(col_version.asc()),
            OrderDirection::Desc => query.order(col_version.desc()),
        },
        "architecture" | "arch" => match direction {
            OrderDirection::Asc => query.order(col_architecture.asc()),
            OrderDirection::Desc => query.order(col_architecture.desc()),
        },
        "package_manager" | "manager" => match direction {
            OrderDirection::Asc => query.order(col_package_manager.asc()),
            OrderDirection::Desc => query.order(col_package_manager.desc()),
        },
        "ecosystem" => match direction {
            OrderDirection::Asc => query.order(col_ecosystem.asc()),
            OrderDirection::Desc => query.order(col_ecosystem.desc()),
        },
        "current" => match direction {
            OrderDirection::Asc => query.order(col_current.asc()),
            OrderDirection::Desc => query.order(col_current.desc()),
        },
        "inserted_at" => match direction {
            OrderDirection::Asc => query.order(col_inserted_at.asc()),
            OrderDirection::Desc => query.order(col_inserted_at.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: EndpointPackagesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointPackagesQuery<'a> {
    match field {
        "device_uid" | "device_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_device_uid.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_uid.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_id.desc()),
        },
        "name" | "package" => match direction {
            OrderDirection::Asc => query.then_order_by(col_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_name.desc()),
        },
        "version" => match direction {
            OrderDirection::Asc => query.then_order_by(col_version.asc()),
            OrderDirection::Desc => query.then_order_by(col_version.desc()),
        },
        "architecture" | "arch" => match direction {
            OrderDirection::Asc => query.then_order_by(col_architecture.asc()),
            OrderDirection::Desc => query.then_order_by(col_architecture.desc()),
        },
        "package_manager" | "manager" => match direction {
            OrderDirection::Asc => query.then_order_by(col_package_manager.asc()),
            OrderDirection::Desc => query.then_order_by(col_package_manager.desc()),
        },
        "ecosystem" => match direction {
            OrderDirection::Asc => query.then_order_by(col_ecosystem.asc()),
            OrderDirection::Desc => query.then_order_by(col_ecosystem.desc()),
        },
        "current" => match direction {
            OrderDirection::Asc => query.then_order_by(col_current.asc()),
            OrderDirection::Desc => query.then_order_by(col_current.desc()),
        },
        "inserted_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_inserted_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_inserted_at.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
        },
        _ => query,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::EndpointPackages,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        }
    }

    #[test]
    fn builds_query_with_package_filters() {
        for field in [
            "device_uid",
            "agent_id",
            "name",
            "version",
            "architecture",
            "package_manager",
            "ecosystem",
            "purl",
            "purl_canonical",
            "canonical_purl",
            "raw_purl",
            "supplier",
            "license",
            "source",
        ] {
            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("x".to_string()),
            }]);
            assert!(
                build_query(&plan).is_ok(),
                "should build query with {field} filter"
            );
        }
    }

    #[test]
    fn builds_query_with_current_and_cpe_filters() {
        let plan = plan_with(vec![
            Filter {
                field: "current".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("true".to_string()),
            },
            Filter {
                field: "cpe".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*".into()),
            },
        ]);

        assert!(build_query(&plan).is_ok());
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "scan_ref".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("x".to_string()),
        }]);

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected error for unsupported filter field"),
        }
    }
}
