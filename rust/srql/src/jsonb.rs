use diesel::deserialize::{self, FromSql};
use diesel::expression::AsExpression;
use diesel::pg::{Pg, PgValue};
use diesel::serialize::{self, IsNull, Output, ToSql};
use diesel::sql_types::{Json, Jsonb};
use diesel::FromSqlRow;
use serde::{Deserialize, Serialize};
use std::io::Write;

#[derive(
    AsExpression, Clone, Debug, Default, Deserialize, FromSqlRow, PartialEq, Serialize,
)]
#[diesel(sql_type = Json)]
#[diesel(sql_type = Jsonb)]
#[serde(transparent)]
pub struct DbJson(pub serde_json::Value);

impl DbJson {
    pub fn into_inner(self) -> serde_json::Value {
        self.0
    }
}

impl From<serde_json::Value> for DbJson {
    fn from(value: serde_json::Value) -> Self {
        Self(value)
    }
}

impl From<DbJson> for serde_json::Value {
    fn from(value: DbJson) -> Self {
        value.0
    }
}

impl std::ops::Deref for DbJson {
    type Target = serde_json::Value;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for DbJson {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl FromSql<Json, Pg> for DbJson {
    fn from_sql(value: PgValue<'_>) -> deserialize::Result<Self> {
        serde_json::from_slice(value.as_bytes())
            .map(Self)
            .map_err(|_| "Invalid Json".into())
    }
}

impl ToSql<Json, Pg> for DbJson {
    fn to_sql<'b>(&'b self, out: &mut Output<'b, '_, Pg>) -> serialize::Result {
        serde_json::to_writer(out, &self.0)
            .map(|_| IsNull::No)
            .map_err(Into::into)
    }
}

impl FromSql<Jsonb, Pg> for DbJson {
    fn from_sql(value: PgValue<'_>) -> deserialize::Result<Self> {
        let bytes = value.as_bytes();
        if bytes.first().copied() != Some(1) {
            return Err("Unsupported JSONB encoding version".into());
        }

        serde_json::from_slice(&bytes[1..])
            .map(Self)
            .map_err(|_| "Invalid Json".into())
    }
}

impl ToSql<Jsonb, Pg> for DbJson {
    fn to_sql<'b>(&'b self, out: &mut Output<'b, '_, Pg>) -> serialize::Result {
        out.write_all(&[1])?;
        serde_json::to_writer(out, &self.0)
            .map(|_| IsNull::No)
            .map_err(Into::into)
    }
}
