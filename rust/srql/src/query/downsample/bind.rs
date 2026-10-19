use crate::query::BindParam;
use chrono::{DateTime, Utc};
use diesel::pg::Pg;

#[derive(Debug)]
pub(super) enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Float(f64),
    Timestamp(DateTime<Utc>),
    BigInt(i64),
}

impl SqlBindValue {
    pub(super) fn apply<'a>(
        &self,
        query: diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery>,
    ) -> diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery> {
        use diesel::sql_types::{Array, Float8, Int8, Text, Timestamptz};
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            SqlBindValue::Float(value) => query.bind::<Float8, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
            SqlBindValue::BigInt(value) => query.bind::<Int8, _>(*value),
        }
    }

    pub(super) fn into_bind_param(self) -> BindParam {
        match self {
            SqlBindValue::Text(value) => BindParam::Text(value),
            SqlBindValue::TextArray(values) => BindParam::TextArray(values),
            SqlBindValue::Float(value) => BindParam::Float(value),
            SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
            SqlBindValue::BigInt(value) => BindParam::Int(value),
        }
    }
}
