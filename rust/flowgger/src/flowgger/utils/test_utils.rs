#[cfg(test)]
pub mod rfc_test_utils {
    use crate::flowgger::utils;
    use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time};

    /// Converts a partial date to a timestamp in ms assuming the year is the current one
    #[inline]
    pub fn ts_from_partial_date_time(month: Month, day: u8, hour: u8, min: u8, sec: u8) -> f64 {
        ts_from_date_time(
            OffsetDateTime::now_utc().year(),
            month,
            day,
            hour,
            min,
            sec,
            0,
        )
    }

    /// Converts a full date to a timestamp in ms
    pub fn new_date_time(
        year: i32,
        month: Month,
        day: u8,
        hour: u8,
        min: u8,
        sec: u8,
        msec: u16,
    ) -> OffsetDateTime {
        // Compute the timestamp we expect
        let d = Date::from_calendar_date(year, month, day).unwrap();
        let t = Time::from_hms_milli(hour, min, sec, msec).unwrap();
        let pd = PrimitiveDateTime::new(d, t);
        let now = OffsetDateTime::now_utc();
        now.replace_date_time(pd)
    }

    /// Converts a full date to a timestamp in ms
    pub fn ts_from_date_time(
        year: i32,
        month: Month,
        day: u8,
        hour: u8,
        min: u8,
        sec: u8,
        msec: u16,
    ) -> f64 {
        let dt = new_date_time(year, month, day, hour, min, sec, msec);
        utils::PreciseTimestamp::from_offset_datetime(dt).as_f64()
    }
}
