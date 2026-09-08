use super::types::EventsQuery;
use crate::{
    parser::{OrderClause, OrderDirection},
    schema::ocsf_events::dsl::{id as col_id, time as col_time},
};
use diesel::prelude::*;

pub(super) fn apply_ordering<'a>(
    mut query: EventsQuery<'a>,
    order: &[OrderClause],
) -> EventsQuery<'a> {
    let mut applied = false;
    for clause in order {
        if !matches!(
            clause.field.as_str(),
            "time" | "event_timestamp" | "timestamp"
        ) {
            continue;
        }

        query = match (applied, clause.direction) {
            (false, OrderDirection::Asc) => query.order(col_time.asc()),
            (false, OrderDirection::Desc) => query.order(col_time.desc()),
            (true, OrderDirection::Asc) => query.then_order_by(col_time.asc()),
            (true, OrderDirection::Desc) => query.then_order_by(col_time.desc()),
        };
        applied = true;
    }

    if !applied {
        query = query.order(col_time.desc());
    }

    query.then_order_by(col_id.asc())
}
