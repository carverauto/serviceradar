use diesel::mysql::data_types::MysqlTime;
use diesel::mysql::MysqlType;
use diesel::mysql::MysqlValue;
use diesel::QueryResult;
use mysql_async::{Params, Value};
use std::convert::TryInto;

pub(super) struct ToSqlHelper {
    pub(super) metadata: Vec<MysqlType>,
    pub(super) binds: Vec<Option<Vec<u8>>>,
}

fn to_value((metadata, bind): (MysqlType, Option<Vec<u8>>)) -> QueryResult<Value> {
    let cast_helper = |e| diesel::result::Error::SerializationError(Box::new(e));
    let v = match bind {
        Some(bind) => match metadata {
            MysqlType::Tiny => Value::Int(i8::from_be_bytes([bind[0]]) as i64),
            MysqlType::Short => Value::Int(i16::from_ne_bytes(bind.try_into().unwrap()) as _),
            MysqlType::Long => Value::Int(i32::from_ne_bytes(bind.try_into().unwrap()) as _),
            MysqlType::LongLong => Value::Int(i64::from_ne_bytes(bind.try_into().unwrap())),

            MysqlType::UnsignedTiny => Value::UInt(bind[0] as _),
            MysqlType::UnsignedShort => {
                Value::UInt(u16::from_ne_bytes(bind.try_into().unwrap()) as _)
            }
            MysqlType::UnsignedLong => {
                Value::UInt(u32::from_ne_bytes(bind.try_into().unwrap()) as _)
            }
            MysqlType::UnsignedLongLong => {
                Value::UInt(u64::from_ne_bytes(bind.try_into().unwrap()))
            }
            MysqlType::Float => Value::Float(f32::from_ne_bytes(bind.try_into().unwrap())),
            MysqlType::Double => Value::Double(f64::from_ne_bytes(bind.try_into().unwrap())),

            MysqlType::Time => {
                let time: MysqlTime = diesel::deserialize::FromSql::<
                    diesel::sql_types::Time,
                    diesel::mysql::Mysql,
                >::from_sql(MysqlValue::new(&bind, metadata))
                .expect("This does not fail");
                Value::Time(
                    time.neg,
                    time.day,
                    time.hour.try_into().map_err(cast_helper)?,
                    time.minute.try_into().map_err(cast_helper)?,
                    time.second.try_into().map_err(cast_helper)?,
                    time.second_part.try_into().expect("Cast does not fail"),
                )
            }
            MysqlType::Date | MysqlType::DateTime | MysqlType::Timestamp => {
                let time: MysqlTime = diesel::deserialize::FromSql::<
                    diesel::sql_types::Timestamp,
                    diesel::mysql::Mysql,
                >::from_sql(MysqlValue::new(&bind, metadata))
                .expect("This does not fail");
                Value::Date(
                    time.year.try_into().map_err(cast_helper)?,
                    time.month.try_into().map_err(cast_helper)?,
                    time.day.try_into().map_err(cast_helper)?,
                    time.hour.try_into().map_err(cast_helper)?,
                    time.minute.try_into().map_err(cast_helper)?,
                    time.second.try_into().map_err(cast_helper)?,
                    time.second_part.try_into().expect("Cast does not fail"),
                )
            }
            MysqlType::Numeric
            | MysqlType::Set
            | MysqlType::Enum
            | MysqlType::String
            | MysqlType::Blob => Value::Bytes(bind),
            MysqlType::Bit => unimplemented!(),
            _ => unreachable!(),
        },
        None => Value::NULL,
    };
    Ok(v)
}

impl TryFrom<ToSqlHelper> for Params {
    type Error = diesel::result::Error;

    fn try_from(ToSqlHelper { metadata, binds }: ToSqlHelper) -> Result<Self, Self::Error> {
        let values = metadata
            .into_iter()
            .zip(binds)
            .map(to_value)
            .collect::<Result<Vec<_>, Self::Error>>()?;
        Ok(Params::Positional(values))
    }
}
