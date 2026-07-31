//! Template TTL (Time-to-Live) support for expiring cached templates.
//!
//! When enabled via [`TtlConfig`], templates are stamped with an insertion time
//! and expire after a configurable duration (default: 2 hours). Expired templates
//! are evicted on the next cache lookup, ensuring stale definitions are refreshed.

use std::time::{Duration, Instant};

/// Configuration for template TTL (Time-to-Live)
#[derive(Debug, Clone)]
pub struct TtlConfig {
    pub duration: Duration,
}

impl TtlConfig {
    /// Create a new TTL configuration with the specified duration.
    ///
    /// # Panics
    ///
    /// Panics if `duration` is zero. Use a non-zero duration.
    pub fn new(duration: Duration) -> Self {
        assert!(
            !duration.is_zero(),
            "TTL duration must be greater than zero"
        );
        Self { duration }
    }
}

impl Default for TtlConfig {
    /// Default TTL configuration: 2 hours
    fn default() -> Self {
        Self::new(Duration::from_secs(2 * 60 * 60))
    }
}

/// Metadata for tracking template insertion time
#[derive(Debug, Clone)]
pub struct TemplateMetadata {
    pub inserted_at: Option<Instant>,
}

impl TemplateMetadata {
    /// Create new metadata with current timestamp (when TTL is enabled)
    pub fn new_with_ttl() -> Self {
        Self {
            inserted_at: Some(Instant::now()),
        }
    }

    /// Create new metadata without timestamp (when TTL is disabled)
    pub fn new_without_ttl() -> Self {
        Self { inserted_at: None }
    }

    /// Check if this template has expired based on TTL configuration
    pub fn is_expired(&self, config: &TtlConfig) -> bool {
        match self.inserted_at {
            Some(instant) => instant.elapsed() >= config.duration,
            None => false,
        }
    }
}

impl Default for TemplateMetadata {
    fn default() -> Self {
        Self::new_without_ttl()
    }
}

/// Wrapper for templates with TTL metadata
#[derive(Debug, Clone)]
pub struct TemplateWithTtl<T> {
    pub template: T,
    pub metadata: TemplateMetadata,
}

impl<T> TemplateWithTtl<T> {
    /// Create a new template wrapper with TTL tracking enabled
    pub fn new_with_ttl(template: T) -> Self {
        Self {
            template,
            metadata: TemplateMetadata::new_with_ttl(),
        }
    }

    /// Create a new template wrapper without TTL tracking
    pub fn new_without_ttl(template: T) -> Self {
        Self {
            template,
            metadata: TemplateMetadata::new_without_ttl(),
        }
    }

    /// Create a new template wrapper, conditionally enabling TTL
    pub fn new(template: T, ttl_enabled: bool) -> Self {
        if ttl_enabled {
            Self::new_with_ttl(template)
        } else {
            Self::new_without_ttl(template)
        }
    }

    /// Check if this template has expired based on TTL configuration
    pub fn is_expired(&self, config: &TtlConfig) -> bool {
        self.metadata.is_expired(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    // Verify template expires after configured TTL duration elapses
    #[test]
    fn test_time_based_expiration() {
        let config = TtlConfig::new(Duration::from_millis(100));
        let metadata = TemplateMetadata::new_with_ttl();

        assert!(!metadata.is_expired(&config));
        thread::sleep(Duration::from_millis(500));
        assert!(metadata.is_expired(&config));
    }

    // Verify template without TTL stamp never expires regardless of elapsed time
    #[test]
    fn test_no_ttl_never_expires() {
        let config = TtlConfig::new(Duration::from_millis(1));
        let metadata = TemplateMetadata::new_without_ttl();

        thread::sleep(Duration::from_millis(10));
        assert!(!metadata.is_expired(&config));
    }

    // Verify TemplateWithTtl wraps a value and respects TTL expiration
    #[test]
    fn test_template_with_ttl_wrapper() {
        let template = 42u32;
        let wrapped = TemplateWithTtl::new_with_ttl(template);

        assert_eq!(wrapped.template, 42);

        let config = TtlConfig::new(Duration::from_millis(100));
        assert!(!wrapped.is_expired(&config));
        thread::sleep(Duration::from_millis(150));
        assert!(wrapped.is_expired(&config));
    }

    // Verify TemplateWithTtl created without TTL never expires
    #[test]
    fn test_template_without_ttl() {
        let wrapped = TemplateWithTtl::new_without_ttl(42u32);
        let config = TtlConfig::new(Duration::from_millis(1));
        thread::sleep(Duration::from_millis(10));
        assert!(!wrapped.is_expired(&config));
    }

    // Verify new() sets inserted_at based on the ttl_enabled flag
    #[test]
    fn test_conditional_new() {
        let with = TemplateWithTtl::new(42u32, true);
        assert!(with.metadata.inserted_at.is_some());

        let without = TemplateWithTtl::new(42u32, false);
        assert!(without.metadata.inserted_at.is_none());
    }

    // Verify default TtlConfig is 2 hours
    #[test]
    fn test_default_config() {
        let config = TtlConfig::default();
        assert_eq!(config.duration, Duration::from_secs(2 * 60 * 60));
    }
}
