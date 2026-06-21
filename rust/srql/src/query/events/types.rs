use crate::schema::ocsf_events;
use diesel::{
    pg::Pg,
    query_builder::{AsQuery, BoxedSelectStatement, FromClause},
};

type EventsTable = ocsf_events::table;
type EventsFromClause = FromClause<EventsTable>;
pub(super) type EventsQuery<'a> =
    BoxedSelectStatement<'a, <EventsTable as AsQuery>::SqlType, EventsFromClause, Pg>;
