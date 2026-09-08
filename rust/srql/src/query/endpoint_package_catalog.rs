//! Query execution for normalized endpoint-side package coordinates.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EndpointPackageCatalogRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::endpoint_packages::dsl::{
        architecture as col_architecture, coordinate_key as col_coordinate_key, cpes as col_cpes,
        ecosystem as col_ecosystem, endpoint_packages, id as col_id,
        inserted_at as col_inserted_at, name as col_name, package_manager as col_package_manager,
        primary_cpe as col_primary_cpe, purl_canonical as col_purl_canonical,
        source_scope as col_source_scope, updated_at as col_updated_at, version as col_version,
    },
    time::TimeRange,
};
use diesel::PgArrayExpressionMethods;
use diesel::PgTextExpressionMethods;
use diesel::dsl::not;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type EndpointPackageCatalogTable = crate::schema::endpoint_packages::table;
type EndpointPackageCatalogFromClause = FromClause<EndpointPackageCatalogTable>;
type EndpointPackageCatalogQuery<'a> = BoxedSelectStatement<
    'a,
    <EndpointPackageCatalogTable as AsQuery>::SqlType,
    EndpointPackageCatalogFromClause,
    Pg,
>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<EndpointPackageCatalogRow> = query
        .select(EndpointPackageCatalogRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EndpointPackageCatalogRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(EndpointPackageCatalogRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(rollup) = plan.rollup_stats.as_deref() {
        return Err(ServiceError::InvalidRequest(format!(
            "endpoint_package_catalog does not support rollup_stats: '{rollup}'"
        )));
    }

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
        Entity::EndpointPackageCatalog => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by endpoint_package_catalog query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<EndpointPackageCatalogQuery<'static>> {
    let mut query = endpoint_packages.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_inserted_at.ge(*start).and(col_inserted_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: EndpointPackageCatalogQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackageCatalogQuery<'a>> {
    match filter.field.as_str() {
        "id" | "package_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "package_id only supports equality comparisons"
            )?;
        }
        "coordinate_key" | "coordinate" => {
            query = apply_text_filter!(query, filter, col_coordinate_key)?;
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
        "primary_cpe" => {
            query = apply_text_filter!(query, filter, col_primary_cpe)?;
        }
        "source_scope" | "scope" => {
            query = apply_text_filter!(query, filter, col_source_scope)?;
        }
        "cpe" | "cpes" => {
            query = apply_cpe_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for endpoint_package_catalog: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_cpe_filter<'a>(
    query: EndpointPackageCatalogQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackageCatalogQuery<'a>> {
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
        "coordinate_key" | "coordinate" | "name" | "package" | "version" | "architecture"
        | "arch" | "package_manager" | "manager" | "ecosystem" | "purl" | "purl_canonical"
        | "canonical_purl" | "primary_cpe" | "source_scope" | "scope" => {
            collect_text_params(params, filter)
        }
        "cpe" | "cpes" => {
            let values = cpe_values(&filter.value)?;
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        "id" | "package_id" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for endpoint_package_catalog: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: EndpointPackageCatalogQuery<'a>,
    order: &[OrderClause],
) -> EndpointPackageCatalogQuery<'a> {
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
            .order(col_package_manager.asc())
            .then_order_by(col_name.asc())
            .then_order_by(col_version.asc());
    }

    query
}

fn apply_single_order<'a>(
    query: EndpointPackageCatalogQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointPackageCatalogQuery<'a> {
    match field {
        "coordinate_key" | "coordinate" => match direction {
            OrderDirection::Asc => query.order(col_coordinate_key.asc()),
            OrderDirection::Desc => query.order(col_coordinate_key.desc()),
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
        "purl" | "purl_canonical" | "canonical_purl" => match direction {
            OrderDirection::Asc => query.order(col_purl_canonical.asc()),
            OrderDirection::Desc => query.order(col_purl_canonical.desc()),
        },
        "source_scope" | "scope" => match direction {
            OrderDirection::Asc => query.order(col_source_scope.asc()),
            OrderDirection::Desc => query.order(col_source_scope.desc()),
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
    query: EndpointPackageCatalogQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointPackageCatalogQuery<'a> {
    match field {
        "coordinate_key" | "coordinate" => match direction {
            OrderDirection::Asc => query.then_order_by(col_coordinate_key.asc()),
            OrderDirection::Desc => query.then_order_by(col_coordinate_key.desc()),
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
        "purl" | "purl_canonical" | "canonical_purl" => match direction {
            OrderDirection::Asc => query.then_order_by(col_purl_canonical.asc()),
            OrderDirection::Desc => query.then_order_by(col_purl_canonical.desc()),
        },
        "source_scope" | "scope" => match direction {
            OrderDirection::Asc => query.then_order_by(col_source_scope.asc()),
            OrderDirection::Desc => query.then_order_by(col_source_scope.desc()),
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

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::EndpointPackageCatalog,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn builds_query_with_coordinate_filters() {
        for field in [
            "coordinate_key",
            "package_id",
            "name",
            "version",
            "architecture",
            "package_manager",
            "ecosystem",
            "purl_canonical",
            "canonical_purl",
            "primary_cpe",
            "source_scope",
        ] {
            let value = if field == "package_id" {
                "11111111-1111-4111-8111-111111111111"
            } else {
                "x"
            };

            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar(value.to_string()),
            }]);
            assert!(
                build_query(&plan).is_ok(),
                "should build query with {field} filter"
            );
        }
    }

    #[test]
    fn builds_query_with_cpe_filter() {
        let plan = plan_with(vec![Filter {
            field: "cpe".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*".into()),
        }]);

        assert!(build_query(&plan).is_ok());
    }
}
