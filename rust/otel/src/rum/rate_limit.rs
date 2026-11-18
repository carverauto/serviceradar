use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::config::RumConfig;
use crate::rum::prefix::subnet_bucket_key;

const MAX_SUBNET_BUCKETS: usize = 100_000;
const STALE_BUCKET_TTL: Duration = Duration::from_secs(300);

#[derive(Debug, Clone)]
struct TokenBucket {
    tokens: f64,
    last_refill: Instant,
    last_seen: Instant,
}

impl TokenBucket {
    fn new(burst: f64, now: Instant) -> Self {
        Self {
            tokens: burst,
            last_refill: now,
            last_seen: now,
        }
    }

    fn take(&mut self, rps: f64, burst: f64, now: Instant) -> Result<(), u64> {
        let elapsed = now
            .saturating_duration_since(self.last_refill)
            .as_secs_f64();
        self.tokens = (self.tokens + elapsed * rps).min(burst);
        self.last_refill = now;
        self.last_seen = now;
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            Ok(())
        } else {
            let deficit = 1.0 - self.tokens;
            let wait_secs = if rps > 0.0 {
                (deficit / rps).ceil() as u64
            } else {
                60
            };
            Err(wait_secs.max(1))
        }
    }
}

#[derive(Debug)]
struct LimiterState {
    per_key: HashMap<String, TokenBucket>,
    per_subnet: HashMap<(String, String), TokenBucket>,
}

/// Bounded in-memory token-bucket rate limiter keyed by `rum_site_key` and
/// `(rum_site_key, /24 or /48 subnet)`.
#[derive(Debug)]
pub struct RumRateLimiter {
    per_key_rps: f64,
    per_key_burst: f64,
    per_subnet_rps: f64,
    per_subnet_burst: f64,
    max_subnet_buckets: usize,
    state: Mutex<LimiterState>,
}

impl RumRateLimiter {
    pub fn from_config(config: &RumConfig) -> Self {
        Self::with_limits(
            config.per_key_rps,
            config.per_key_burst,
            config.per_subnet_rps,
            config.per_subnet_burst,
            MAX_SUBNET_BUCKETS,
        )
    }

    pub fn with_limits(
        per_key_rps: f64,
        per_key_burst: f64,
        per_subnet_rps: f64,
        per_subnet_burst: f64,
        max_subnet_buckets: usize,
    ) -> Self {
        Self {
            per_key_rps: per_key_rps.max(0.0),
            per_key_burst: per_key_burst.max(1.0),
            per_subnet_rps: per_subnet_rps.max(0.0),
            per_subnet_burst: per_subnet_burst.max(1.0),
            max_subnet_buckets: max_subnet_buckets.max(1),
            state: Mutex::new(LimiterState {
                per_key: HashMap::new(),
                per_subnet: HashMap::new(),
            }),
        }
    }

    pub fn check(&self, site_key: &str, client_ip: Option<IpAddr>) -> Result<(), u64> {
        self.check_at(site_key, client_ip, Instant::now())
    }

    pub fn check_at(
        &self,
        site_key: &str,
        client_ip: Option<IpAddr>,
        now: Instant,
    ) -> Result<(), u64> {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        if let Some(ip) = client_ip {
            let subnet = subnet_bucket_key(ip);
            if !guard
                .per_subnet
                .contains_key(&(site_key.to_string(), subnet.clone()))
                && guard.per_subnet.len() >= self.max_subnet_buckets
            {
                evict_stale(&mut guard.per_subnet, now, self.max_subnet_buckets);
            }
            let bucket = guard
                .per_subnet
                .entry((site_key.to_string(), subnet))
                .or_insert_with(|| TokenBucket::new(self.per_subnet_burst, now));
            bucket.take(self.per_subnet_rps, self.per_subnet_burst, now)?;
        }

        let key_bucket = guard
            .per_key
            .entry(site_key.to_string())
            .or_insert_with(|| TokenBucket::new(self.per_key_burst, now));
        key_bucket.take(self.per_key_rps, self.per_key_burst, now)
    }
}

fn evict_stale(
    buckets: &mut HashMap<(String, String), TokenBucket>,
    now: Instant,
    max_buckets: usize,
) {
    buckets.retain(|_, b| now.saturating_duration_since(b.last_seen) < STALE_BUCKET_TTL);
    if buckets.len() >= max_buckets {
        let remove_count = buckets.len() / 10 + 1;
        let keys: Vec<(String, String)> = buckets.keys().take(remove_count).cloned().collect();
        for key in keys {
            buckets.remove(&key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn per_subnet_and_per_key_buckets_isolate_tenants_and_subnets() {
        let limiter = RumRateLimiter::with_limits(10.0, 5.0, 1.0, 2.0, 16);
        let t0 = Instant::now();
        let ip_a: IpAddr = "198.51.100.10".parse().unwrap();
        let ip_a2: IpAddr = "198.51.100.99".parse().unwrap();
        let ip_b: IpAddr = "203.0.113.10".parse().unwrap();

        // Subnet 198.51.100.0/24 exhausts burst=2, leaving 203.0.113.0/24 unaffected.
        assert!(limiter.check_at("key-a", Some(ip_a), t0).is_ok());
        assert!(limiter.check_at("key-a", Some(ip_a2), t0).is_ok());
        assert!(limiter.check_at("key-a", Some(ip_a), t0).is_err());
        assert!(limiter.check_at("key-a", Some(ip_b), t0).is_ok());

        // Refills after 1s.
        let t1 = t0 + Duration::from_secs(1);
        assert!(limiter.check_at("key-a", Some(ip_a), t1).is_ok());
    }

    #[test]
    fn ipv6_subnets_are_keyed_on_48_prefix() {
        let limiter = RumRateLimiter::with_limits(100.0, 100.0, 1.0, 1.0, 16);
        let t0 = Instant::now();
        let v6_1: IpAddr = "2001:db8:abcd:1::1".parse().unwrap();
        let v6_2: IpAddr = "2001:db8:abcd:2::9".parse().unwrap();
        assert!(limiter.check_at("key-a", Some(v6_1), t0).is_ok());
        assert!(limiter.check_at("key-a", Some(v6_2), t0).is_err());
    }
}
