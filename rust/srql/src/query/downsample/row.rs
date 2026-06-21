use chrono::{DateTime, Utc};
use diesel::{
    deserialize::QueryableByName,
    sql_types::{Float8, Nullable, Text, Timestamptz},
};

#[derive(Debug, QueryableByName)]
pub(super) struct DownsampleRow {
    #[diesel(sql_type = Timestamptz)]
    pub(super) timestamp: DateTime<Utc>,
    #[diesel(sql_type = Nullable<Text>)]
    pub(super) series: Option<String>,
    #[diesel(sql_type = Nullable<Float8>)]
    pub(super) value: Option<f64>,
}
