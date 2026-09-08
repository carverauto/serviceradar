use crate::{
    error::{Result, ServiceError},
    query::BindParam,
};
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_types::{Array, BigInt, Bool, Text, Timestamptz};

pub(super) fn bind_param<'a>(
    query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, SqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Bool(value) => Ok(query.bind::<Bool, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<diesel::sql_types::Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&chrono::Utc))
                .map_err(|err| {
                    ServiceError::Internal(anyhow::anyhow!(
                        "invalid timestamptz bind {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
        BindParam::Uuid(value) => Ok(query.bind::<diesel::sql_types::Uuid, _>(value)),
        BindParam::Date(_) => Err(ServiceError::InvalidRequest(
            "unsupported bind type for interfaces".into(),
        )),
    }
}
