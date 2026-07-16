use super::{DeviceQuery, filters::safe_device_ip_inet_sql};
use crate::{
    parser::{OrderClause, OrderDirection},
    schema::ocsf_devices::dsl::{
        first_seen_time as col_first_seen_time, last_seen_time as col_last_seen_time,
        type_id as col_type_id, uid as col_uid,
    },
};
use diesel::dsl::sql;
use diesel::prelude::*;
use diesel::sql_types::{Bool, Inet, Nullable};

pub(super) fn apply_ordering<'a>(
    mut query: DeviceQuery<'a>,
    order: &[OrderClause],
) -> DeviceQuery<'a> {
    let mut applied = false;
    let mut saw_is_available = false;
    let mut saw_ip = false;

    for clause in order {
        let (updated, did_apply) = if applied {
            apply_secondary_order(query, clause)
        } else {
            apply_primary_order(query, clause)
        };

        query = updated;
        if did_apply {
            applied = true;
        }

        match clause.field.as_str() {
            "is_available" => saw_is_available = true,
            "ip" => saw_ip = true,
            _ => {}
        }
    }

    if !applied {
        query = query
            .order(sql::<Bool>("coalesce(is_available, false)").desc())
            .then_order_by(sql::<Nullable<Inet>>(safe_device_ip_inet_sql()).asc())
            .then_order_by(col_uid.asc());
    } else if saw_is_available && !saw_ip {
        query = query
            .then_order_by(sql::<Nullable<Inet>>(safe_device_ip_inet_sql()).asc())
            .then_order_by(col_uid.asc());
    } else {
        query = query.then_order_by(col_uid.asc());
    }

    query
}

fn apply_primary_order<'a>(
    query: DeviceQuery<'a>,
    clause: &OrderClause,
) -> (DeviceQuery<'a>, bool) {
    match clause.field.as_str() {
        "is_available" => (
            match clause.direction {
                OrderDirection::Asc => {
                    query.order(sql::<Bool>("coalesce(is_available, false)").asc())
                }
                OrderDirection::Desc => {
                    query.order(sql::<Bool>("coalesce(is_available, false)").desc())
                }
            },
            true,
        ),
        "ip" => (
            match clause.direction {
                OrderDirection::Asc => {
                    query.order(sql::<Nullable<Inet>>(safe_device_ip_inet_sql()).asc())
                }
                OrderDirection::Desc => {
                    query.order(sql::<Nullable<Inet>>(safe_device_ip_inet_sql()).desc())
                }
            },
            true,
        ),
        "uid" => (
            match clause.direction {
                OrderDirection::Asc => query.order(col_uid.asc()),
                OrderDirection::Desc => query.order(col_uid.desc()),
            },
            true,
        ),
        // Support both OCSF and legacy time field names
        "first_seen_time" | "first_seen" => (
            match clause.direction {
                OrderDirection::Asc => query.order(col_first_seen_time.asc()),
                OrderDirection::Desc => query.order(col_first_seen_time.desc()),
            },
            true,
        ),
        "last_seen_time" | "last_seen" => (
            match clause.direction {
                OrderDirection::Asc => query.order(col_last_seen_time.asc()),
                OrderDirection::Desc => query.order(col_last_seen_time.desc()),
            },
            true,
        ),
        "type_id" => (
            match clause.direction {
                OrderDirection::Asc => query.order(col_type_id.asc()),
                OrderDirection::Desc => query.order(col_type_id.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}

fn apply_secondary_order<'a>(
    query: DeviceQuery<'a>,
    clause: &OrderClause,
) -> (DeviceQuery<'a>, bool) {
    match clause.field.as_str() {
        "is_available" => (
            match clause.direction {
                OrderDirection::Asc => {
                    query.then_order_by(sql::<Bool>("coalesce(is_available, false)").asc())
                }
                OrderDirection::Desc => {
                    query.then_order_by(sql::<Bool>("coalesce(is_available, false)").desc())
                }
            },
            true,
        ),
        "ip" => (
            match clause.direction {
                OrderDirection::Asc => {
                    query.then_order_by(sql::<Nullable<Inet>>(safe_device_ip_inet_sql()).asc())
                }
                OrderDirection::Desc => {
                    query.then_order_by(sql::<Nullable<Inet>>(safe_device_ip_inet_sql()).desc())
                }
            },
            true,
        ),
        "uid" => (
            match clause.direction {
                OrderDirection::Asc => query.then_order_by(col_uid.asc()),
                OrderDirection::Desc => query.then_order_by(col_uid.desc()),
            },
            true,
        ),
        // Support both OCSF and legacy time field names
        "first_seen_time" | "first_seen" => (
            match clause.direction {
                OrderDirection::Asc => query.then_order_by(col_first_seen_time.asc()),
                OrderDirection::Desc => query.then_order_by(col_first_seen_time.desc()),
            },
            true,
        ),
        "last_seen_time" | "last_seen" => (
            match clause.direction {
                OrderDirection::Asc => query.then_order_by(col_last_seen_time.asc()),
                OrderDirection::Desc => query.then_order_by(col_last_seen_time.desc()),
            },
            true,
        ),
        "type_id" => (
            match clause.direction {
                OrderDirection::Asc => query.then_order_by(col_type_id.asc()),
                OrderDirection::Desc => query.then_order_by(col_type_id.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}
