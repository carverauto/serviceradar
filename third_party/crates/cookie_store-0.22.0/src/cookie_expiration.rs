use std;

#[cfg(feature = "serde")]
use serde_derive::{Deserialize, Serialize};
use time::{self, OffsetDateTime};

/// When a given `Cookie` expires
#[derive(Eq, Clone, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub enum CookieExpiration {
    /// `Cookie` expires at the given UTC time, as set from either the Max-Age
    /// or Expires attribute of a Set-Cookie header
    #[cfg_attr(feature = "serde", serde(with = "crate::rfc3339_fmt"))]
    AtUtc(OffsetDateTime),
    /// `Cookie` expires at the end of the current `Session`; this means the cookie
    /// is not persistent
    SessionEnd,
}

// We directly impl `PartialEq` as the cookie Expires attribute does not include nanosecond precision
impl std::cmp::PartialEq for CookieExpiration {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (CookieExpiration::SessionEnd, CookieExpiration::SessionEnd) => true,
            (CookieExpiration::AtUtc(this_offset), CookieExpiration::AtUtc(other_offset)) => {
                // All instances should already be UTC offset
                this_offset.date() == other_offset.date()
                    && this_offset.time().hour() == other_offset.time().hour()
                    && this_offset.time().minute() == other_offset.time().minute()
                    && this_offset.time().second() == other_offset.time().second()
            }
            _ => false,
        }
    }
}

impl CookieExpiration {
    /// Indicates if the `Cookie` is expired as of *now*.
    pub fn is_expired(&self) -> bool {
        self.expires_by(&time::OffsetDateTime::now_utc())
    }

    /// Indicates if the `Cookie` expires as of `utc_tm`.
    pub fn expires_by(&self, utc_tm: &time::OffsetDateTime) -> bool {
        match *self {
            CookieExpiration::AtUtc(ref expire_tm) => *expire_tm <= *utc_tm,
            CookieExpiration::SessionEnd => false,
        }
    }
}

const MAX_RFC3339: time::OffsetDateTime = time::macros::date!(9999 - 12 - 31)
    .with_time(time::macros::time!(23:59:59))
    .assume_utc();
impl From<u64> for CookieExpiration {
    fn from(max_age: u64) -> CookieExpiration {
        // make sure we don't trigger a panic! in Duration by restricting the seconds
        // to the max
        CookieExpiration::from(time::Duration::seconds(std::cmp::min(
            time::Duration::MAX.whole_seconds() as u64,
            max_age,
        ) as i64))
    }
}

impl From<time::OffsetDateTime> for CookieExpiration {
    fn from(utc_tm: OffsetDateTime) -> CookieExpiration {
        CookieExpiration::AtUtc(utc_tm.min(MAX_RFC3339))
    }
}

impl From<cookie::Expiration> for CookieExpiration {
    fn from(expiration: cookie::Expiration) -> CookieExpiration {
        match expiration {
            cookie::Expiration::DateTime(offset) => CookieExpiration::AtUtc(offset),
            cookie::Expiration::Session => CookieExpiration::SessionEnd,
        }
    }
}

impl From<time::Duration> for CookieExpiration {
    fn from(duration: time::Duration) -> Self {
        // If delta-seconds is less than or equal to zero (0), let expiry-time
        //    be the earliest representable date and time.  Otherwise, let the
        //    expiry-time be the current date and time plus delta-seconds seconds.
        let utc_tm = if duration.is_zero() {
            time::OffsetDateTime::UNIX_EPOCH
        } else {
            let now_utc = time::OffsetDateTime::now_utc();
            let d = (MAX_RFC3339 - now_utc).min(duration);
            now_utc + d
        };
        CookieExpiration::from(utc_tm)
    }
}

#[cfg(test)]
mod tests {
    use super::CookieExpiration;
    use time;

    use crate::utils::test::*;

    #[test]
    fn max_age_bounds() {
        match CookieExpiration::from(time::Duration::MAX.whole_seconds() as u64 + 1) {
            CookieExpiration::AtUtc(_) => assert!(true),
            _ => assert!(false),
        }
    }

    #[test]
    fn expired() {
        let ma = CookieExpiration::from(0u64); // Max-Age<=0 indicates the cookie is expired
        assert!(ma.is_expired());
        assert!(ma.expires_by(&in_days(-1)));
    }

    #[test]
    fn max_age() {
        let ma = CookieExpiration::from(60u64);
        assert!(!ma.is_expired());
        assert!(ma.expires_by(&in_minutes(2)));
    }

    #[test]
    fn session_end() {
        // SessionEnd never "expires"; lives until end of session
        let se = CookieExpiration::SessionEnd;
        assert!(!se.is_expired());
        assert!(!se.expires_by(&in_days(1)));
        assert!(!se.expires_by(&in_days(-1)));
    }

    #[test]
    fn at_utc() {
        {
            let expire_tmrw = CookieExpiration::from(in_days(1));
            assert!(!expire_tmrw.is_expired());
            assert!(expire_tmrw.expires_by(&in_days(2)));
        }
        {
            let expired_yest = CookieExpiration::from(in_days(-1));
            assert!(expired_yest.is_expired());
            assert!(!expired_yest.expires_by(&in_days(-2)));
        }
    }
}
