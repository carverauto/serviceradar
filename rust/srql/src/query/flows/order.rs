use super::*;

pub(super) fn apply_ordering<'a>(
    mut query: FlowsQuery<'a>,
    order: &[OrderClause],
) -> FlowsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    // Default ordering by time descending
    if !applied {
        query = query.order(time.desc());
    }

    // Always apply a stable tie-breaker for deterministic pagination.
    query.then_order_by(created_at.desc())
}

fn apply_single_order<'a>(
    query: FlowsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> FlowsQuery<'a> {
    match field {
        "time" => match direction {
            OrderDirection::Asc => query.order(time.asc()),
            OrderDirection::Desc => query.order(time.desc()),
        },
        "bytes_total" => match direction {
            OrderDirection::Asc => query.order(bytes_total.asc()),
            OrderDirection::Desc => query.order(bytes_total.desc()),
        },
        "packets_total" => match direction {
            OrderDirection::Asc => query.order(packets_total.asc()),
            OrderDirection::Desc => query.order(packets_total.desc()),
        },
        "bytes_in" => match direction {
            OrderDirection::Asc => query.order(bytes_in.asc()),
            OrderDirection::Desc => query.order(bytes_in.desc()),
        },
        "bytes_out" => match direction {
            OrderDirection::Asc => query.order(bytes_out.asc()),
            OrderDirection::Desc => query.order(bytes_out.desc()),
        },
        "packets_in" => match direction {
            OrderDirection::Asc => query.order(packets_in.asc()),
            OrderDirection::Desc => query.order(packets_in.desc()),
        },
        "packets_out" => match direction {
            OrderDirection::Asc => query.order(packets_out.asc()),
            OrderDirection::Desc => query.order(packets_out.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: FlowsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> FlowsQuery<'a> {
    match field {
        "time" => match direction {
            OrderDirection::Asc => query.then_order_by(time.asc()),
            OrderDirection::Desc => query.then_order_by(time.desc()),
        },
        "bytes_total" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_total.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_total.desc()),
        },
        "packets_total" => match direction {
            OrderDirection::Asc => query.then_order_by(packets_total.asc()),
            OrderDirection::Desc => query.then_order_by(packets_total.desc()),
        },
        "bytes_in" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_in.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_in.desc()),
        },
        "bytes_out" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_out.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_out.desc()),
        },
        "packets_in" => match direction {
            OrderDirection::Asc => query.then_order_by(packets_in.asc()),
            OrderDirection::Desc => query.then_order_by(packets_in.desc()),
        },
        "packets_out" => match direction {
            OrderDirection::Asc => query.then_order_by(packets_out.asc()),
            OrderDirection::Desc => query.then_order_by(packets_out.desc()),
        },
        _ => query,
    }
}

// Stats aggregation support
