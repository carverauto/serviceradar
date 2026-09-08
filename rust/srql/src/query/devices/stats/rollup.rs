use super::DeviceRollupStatsSql;
use crate::{
    error::{Result, ServiceError},
    query::QueryPlan,
};

pub(in crate::query::devices) fn build_rollup_stats_query(
    plan: &QueryPlan,
) -> Result<Option<DeviceRollupStatsSql>> {
    let rollup_type = match plan.rollup_stats.as_ref() {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    if !plan.filters.is_empty() || plan.time_range.is_some() {
        return Err(ServiceError::InvalidRequest(
            "devices rollup_stats does not support filters or time constraints".into(),
        ));
    }

    match rollup_type {
        "inventory_summary" => Ok(Some(DeviceRollupStatsSql {
            sql: String::from(
                r#"SELECT jsonb_build_object(
    'total', COALESCE((SELECT value FROM device_inventory_counts WHERE key = 'total'), 0)::bigint,
    'available', COALESCE((SELECT value FROM device_inventory_counts WHERE key = 'available'), 0)::bigint,
    'unavailable', COALESCE((SELECT value FROM device_inventory_counts WHERE key = 'unavailable'), 0)::bigint,
    'by_type', COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object('type', type, 'count', count)
            ORDER BY count DESC
        )
        FROM (
            SELECT type, count
            FROM device_inventory_type_counts
            ORDER BY count DESC, type ASC
        ) t
    ), '[]'::jsonb),
    'by_vendor', COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object('vendor_name', vendor_name, 'count', count)
            ORDER BY count DESC
        )
        FROM (
            SELECT vendor_name, count
            FROM device_inventory_vendor_counts
            ORDER BY count DESC, vendor_name ASC
        ) v
    ), '[]'::jsonb)
) AS payload"#,
            ),
        })),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for devices: '{other}' (supported: inventory_summary)"
        ))),
    }
}
