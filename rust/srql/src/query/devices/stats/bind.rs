use crate::query::BindParam;
use chrono::{DateTime, Utc};
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_types::{Array, BigInt, Bool, Text, Timestamptz};

#[derive(Debug, Clone)]
pub(in crate::query::devices) enum DeviceSqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Bool(bool),
    Int(i64),
    Timestamp(DateTime<Utc>),
}

impl DeviceSqlBindValue {
    pub(in crate::query::devices) fn apply<'a>(
        &self,
        query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    ) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            Self::Text(value) => query.bind::<Text, _>(value.clone()),
            Self::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            Self::Bool(value) => query.bind::<Bool, _>(*value),
            Self::Int(value) => query.bind::<BigInt, _>(*value),
            Self::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

pub(in crate::query::devices) fn bind_param_from_device_stats(
    value: DeviceSqlBindValue,
) -> BindParam {
    match value {
        DeviceSqlBindValue::Text(value) => BindParam::Text(value),
        DeviceSqlBindValue::TextArray(values) => BindParam::TextArray(values),
        DeviceSqlBindValue::Bool(value) => BindParam::Bool(value),
        DeviceSqlBindValue::Int(value) => BindParam::Int(value),
        DeviceSqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}
