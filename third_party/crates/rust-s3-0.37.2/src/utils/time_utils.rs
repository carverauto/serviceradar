use std::time::{SystemTime, SystemTimeError, UNIX_EPOCH};
use time::OffsetDateTime;

fn real_time() -> Result<u64, SystemTimeError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|t| t.as_secs())
}

#[cfg(not(test))]
pub fn current_time() -> Result<u64, SystemTimeError> {
    real_time()
}

pub fn now_utc() -> OffsetDateTime {
    OffsetDateTime::from_unix_timestamp(current_time().unwrap() as i64).unwrap()
}

#[cfg(test)]
mod mocked_time {
    use super::*;

    use std::cell::Cell;

    thread_local! {
            static TIMESTAMP: Cell<u64> = Cell::new(0);
    }

    pub fn current_time() -> Result<u64, SystemTimeError> {
        TIMESTAMP.with(|ts| {
            let time = ts.get();
            if time == 0 { real_time() } else { Ok(time) }
        })
    }

    fn set_timestamp(timestamp: u64) -> u64 {
        TIMESTAMP.with(|ts| {
            let old = ts.get();
            ts.set(timestamp);
            old
        })
    }

    pub struct MockTimestamp {
        old: u64,
    }

    impl MockTimestamp {
        // Get the real clock time
        pub fn real_time(&self) -> u64 {
            real_time().unwrap()
        }

        // Get the old time before this call to with_timestamp
        pub fn old_time(&self) -> u64 {
            self.old
        }

        // Sets the time to the exact unix timestamp
        // 0 means use real_time
        // Returns old time
        pub fn set_time(&self, timestamp: u64) -> u64 {
            set_timestamp(timestamp)
        }

        // Add this many seconds to the current time
        // Can be negative
        // Returns new now, old time
        pub fn add_time(&self, time_delta: i64) -> (u64, u64) {
            let now = ((current_time().unwrap() as i64) + time_delta) as u64;
            (now, set_timestamp(now))
        }
    }

    impl Drop for MockTimestamp {
        fn drop(&mut self) {
            set_timestamp(self.old);
        }
    }

    pub fn with_timestamp(timestamp: u64) -> MockTimestamp {
        MockTimestamp {
            old: set_timestamp(timestamp),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        const MOCKED_TIMESTAMP: u64 = 5_000_000;

        mod current_time {
            use super::*;

            #[test]
            fn when_set_timestamp_not_called() {
                let now = real_time().unwrap();

                assert!(current_time().unwrap() >= now);
            }

            #[test]
            fn when_set_timestamp_was_called() {
                set_timestamp(MOCKED_TIMESTAMP);

                assert_eq!(current_time().unwrap(), MOCKED_TIMESTAMP);

                set_timestamp(0);
            }
        }

        mod with_timestamp {
            use super::*;

            #[test]
            fn when_resets_when_result_dropped() {
                let now = real_time().unwrap();
                let ts = with_timestamp(MOCKED_TIMESTAMP);

                assert_eq!(current_time().unwrap(), MOCKED_TIMESTAMP);

                drop(ts);

                assert!(current_time().unwrap() >= now);
            }

            #[test]
            fn when_nested() {
                let now = real_time().unwrap();
                {
                    let _ts = with_timestamp(MOCKED_TIMESTAMP);

                    assert_eq!(current_time().unwrap(), MOCKED_TIMESTAMP);

                    {
                        let _ts = with_timestamp(MOCKED_TIMESTAMP + 1_000);

                        assert_eq!(current_time().unwrap(), MOCKED_TIMESTAMP + 1_000);
                    }

                    {
                        let _ts = with_timestamp(0);

                        assert!(current_time().unwrap() >= now);
                    }

                    assert_eq!(current_time().unwrap(), MOCKED_TIMESTAMP);
                }

                assert!(current_time().unwrap() >= now);
            }
        }
    }
}
#[cfg(test)]
pub use mocked_time::*;
