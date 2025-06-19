pub mod rotating_file;
#[cfg(test)]
pub mod test_utils;

#[cfg(feature = "gelf")]
use std::time::{SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, PrimitiveDateTime};

pub struct PreciseTimestamp {
    ts: f64,
}

impl PreciseTimestamp {
    #[cfg(feature = "gelf")]
    #[inline]
    pub fn now() -> Self {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        PreciseTimestamp {
            ts: now.as_secs() as f64 + f64::from(now.subsec_nanos()) / 1e9,
        }
    }

    #[inline]
    pub fn from_offset_datetime(tsd: OffsetDateTime) -> Self {
        PreciseTimestamp {
            ts: tsd.unix_timestamp_nanos() as f64 / 1e9,
        }
    }

    #[inline]
    pub fn from_primitive_datetime(tsd: PrimitiveDateTime) -> Self {
        PreciseTimestamp {
            ts: tsd.assume_utc().unix_timestamp_nanos() as f64 / 1e9,
        }
    }

    #[inline]
    pub fn as_f64(&self) -> f64 {
        self.ts
    }
}
