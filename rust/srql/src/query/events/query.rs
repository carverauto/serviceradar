use super::{filters::apply_filter, order::apply_ordering, types::EventsQuery};
use crate::{
    error::Result,
    parser::Entity,
    query::QueryPlan,
    schema::ocsf_events::dsl::{ocsf_events, time as col_time},
    time::TimeRange,
};
use diesel::{dsl::sql, pg::Pg, prelude::*, sql_types::Bool};

pub(super) fn build_query(plan: &QueryPlan) -> Result<EventsQuery<'static>> {
    let query = build_filtered_query(plan)?;
    Ok(apply_ordering(query, &plan.order))
}

pub(super) fn build_count_query(plan: &QueryPlan) -> Result<EventsQuery<'static>> {
    build_filtered_query(plan)
}

fn build_filtered_query(plan: &QueryPlan) -> Result<EventsQuery<'static>> {
    let mut query = ocsf_events.into_boxed::<Pg>();

    query = match plan.entity {
        Entity::SecurityFindings => {
            query.filter(sql::<Bool>("\"ocsf_events\".\"category_uid\" = 2"))
        }
        Entity::ScanActivity => query.filter(sql::<Bool>(
            "\"ocsf_events\".\"class_uid\" = 6007 AND \"ocsf_events\".\"category_uid\" = 6",
        )),
        Entity::DnsActivity => query.filter(sql::<Bool>(
            "\"ocsf_events\".\"class_uid\" = 4003 AND \"ocsf_events\".\"category_uid\" = 4",
        )),
        _ => query,
    };

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(query)
}
