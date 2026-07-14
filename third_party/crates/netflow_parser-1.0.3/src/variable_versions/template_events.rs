//! Template lifecycle events and hooks for monitoring template cache behavior.
//!
//! This module provides an event system for tracking template operations in real-time.
//! Users can register callbacks to be notified when templates are learned, evicted,
//! expire, collide, or when data arrives for missing templates.
//!
//! # Use Cases
//!
//! - **Monitoring**: Track template learning and eviction patterns
//! - **Alerting**: Detect template collisions that indicate configuration issues
//! - **Metrics**: Integrate with observability systems (Prometheus, StatsD, etc.)
//! - **Debugging**: Log template lifecycle events for troubleshooting
//! - **Dynamic behavior**: React to template events with custom logic
//!
//! # Examples
//!
//! ```rust
//! use netflow_parser::{NetflowParser, TemplateEvent, TemplateProtocol};
//!
//! let parser = NetflowParser::builder()
//!     .on_template_event(|event| {
//!         match event {
//!             TemplateEvent::Learned { template_id, protocol } => {
//!                 println!("Learned template {:?} for {:?}", template_id, protocol);
//!             }
//!             TemplateEvent::Collision { template_id, protocol } => {
//!                 eprintln!("Collision on template {:?} for {:?}", template_id, protocol);
//!             }
//!             _ => {}
//!         }
//!         Ok(())
//!     })
//!     .build()
//!     .unwrap();
//! ```

use std::sync::Arc;

/// Protocol type for template events.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum TemplateProtocol {
    /// NetFlow v9 template
    V9,
    /// IPFIX template
    Ipfix,
}

/// Template lifecycle events.
///
/// These events are emitted during template cache operations and allow
/// users to monitor and react to template state changes.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub enum TemplateEvent {
    /// A new template was learned and added to the cache.
    ///
    /// This event fires when a template definition packet is successfully parsed
    /// and the template is inserted into the cache for the first time.
    Learned {
        /// The template ID that was learned
        template_id: Option<u16>,
        /// The protocol (V9 or IPFIX)
        protocol: TemplateProtocol,
    },

    /// A template ID was reused, potentially with a different definition.
    ///
    /// This event indicates that a template ID already in the cache was
    /// encountered again. This could be:
    /// - The same template being re-sent (normal refresh)
    /// - A different template using the same ID (collision - problematic)
    ///
    /// In multi-source deployments without proper scoping, collisions indicate
    /// that different routers are using the same template ID with potentially
    /// different schemas. Use `AutoScopedParser` to avoid this issue.
    ///
    /// **Note:** The `template_id` field is `None` when this event is derived from
    /// metric deltas, because specific IDs are not available from the metrics layer.
    Collision {
        /// The template ID that collided (None when derived from metric deltas)
        template_id: Option<u16>,
        /// The protocol (V9 or IPFIX)
        protocol: TemplateProtocol,
    },

    /// A template was evicted from the cache due to LRU policy.
    ///
    /// When the cache reaches its maximum size, the least recently used
    /// template is evicted to make room for new templates. Frequent evictions
    /// may indicate that the cache size is too small or that there are too
    /// many active templates.
    ///
    /// **Note:** The `template_id` field is `None` when this event is derived from
    /// metric deltas, because specific IDs are not available from the metrics layer.
    Evicted {
        /// The template ID that was evicted (None when derived from metric deltas)
        template_id: Option<u16>,
        /// The protocol (V9 or IPFIX)
        protocol: TemplateProtocol,
    },

    /// A template expired due to TTL timeout.
    ///
    /// When TTL-based template expiration is enabled, templates that haven't
    /// been used within the configured timeout are automatically removed from
    /// the cache. This is useful for handling exporters that may change their
    /// template definitions without notification.
    ///
    /// **Note:** The `template_id` field is `None` when this event is derived from
    /// metric deltas, because specific IDs are not available from the metrics layer.
    Expired {
        /// The template ID that expired (None when derived from metric deltas)
        template_id: Option<u16>,
        /// The protocol (V9 or IPFIX)
        protocol: TemplateProtocol,
    },

    /// Data packet arrived for a template that isn't in the cache.
    ///
    /// This typically occurs when:
    /// - Data packets arrive before their template definition (out-of-order)
    /// - Template was evicted from cache before data arrived
    /// - Template definition packet was lost in transit
    ///
    /// Users can implement retry logic or buffering strategies based on this event.
    MissingTemplate {
        /// The template ID that was not found
        template_id: Option<u16>,
        /// The protocol (V9 or IPFIX)
        protocol: TemplateProtocol,
    },

    /// A template was restored into the in-process cache from the secondary
    /// [`crate::template_store::TemplateStore`] on a primary-cache miss.
    ///
    /// This is distinct from `Learned` (which fires on a template flowset in
    /// a parsed packet) — observability tools that count `Learned` to
    /// detect new templates may want to count `Restored` as well after a
    /// parser restart that read templates back from a shared store.
    Restored {
        /// The template ID that was restored from the secondary store.
        template_id: Option<u16>,
        /// The protocol (V9 or IPFIX).
        protocol: TemplateProtocol,
    },
}

/// Error type returned by template event hooks.
pub type TemplateHookError = Box<dyn std::error::Error + Send + Sync>;

/// Type alias for template event hooks.
///
/// Hooks are functions that receive a reference to a `TemplateEvent` and
/// can perform any side effects (logging, metrics, etc.).
///
/// Hooks must be:
/// - `Send + Sync` for thread safety
/// - `'static` lifetime to be stored in the parser
/// - Infallible or return errors via `Result` — hooks must not panic
pub type TemplateHook =
    Arc<dyn Fn(&TemplateEvent) -> Result<(), TemplateHookError> + Send + Sync + 'static>;

/// Container for registered template event hooks.
#[derive(Default)]
pub struct TemplateHooks {
    hooks: Vec<TemplateHook>,
    /// Number of hook errors and panics encountered (observable in release builds).
    hook_errors: u64,
}

impl Clone for TemplateHooks {
    fn clone(&self) -> Self {
        Self {
            hooks: self.hooks.clone(),
            hook_errors: 0, // Reset error counter for cloned instances
        }
    }
}

// Custom Debug implementation to avoid printing closures
impl std::fmt::Debug for TemplateHooks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TemplateHooks")
            .field("hook_count", &self.hooks.len())
            .finish()
    }
}

impl TemplateHooks {
    /// Creates a new empty hook container.
    pub fn new() -> Self {
        Self {
            hooks: Vec::new(),
            hook_errors: 0,
        }
    }

    /// Registers a new hook.
    pub fn register<F>(&mut self, hook: F)
    where
        F: Fn(&TemplateEvent) -> Result<(), TemplateHookError> + Send + Sync + 'static,
    {
        self.hooks.push(Arc::new(hook));
    }

    /// Removes all registered hooks.
    pub fn clear(&mut self) {
        self.hooks.clear();
    }

    /// Triggers all registered hooks with the given event.
    ///
    /// All hooks are called regardless of whether earlier hooks return errors or panic.
    /// Errors and panics from hooks are isolated and do not interrupt other hooks or parsing.
    /// The error count is tracked via [`hook_error_count`](Self::hook_error_count) for
    /// production observability.
    pub fn trigger(&mut self, event: &TemplateEvent) {
        for hook in &self.hooks {
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| hook(event))) {
                Ok(Err(e)) => {
                    self.hook_errors = self.hook_errors.saturating_add(1);
                    #[cfg(debug_assertions)]
                    eprintln!("template hook error: {e}");
                    let _ = e;
                }
                Err(_panic) => {
                    self.hook_errors = self.hook_errors.saturating_add(1);
                    #[cfg(debug_assertions)]
                    eprintln!("template hook panicked");
                }
                Ok(Ok(())) => {}
            }
        }
    }

    /// Returns the total number of hook errors and panics encountered.
    pub fn hook_error_count(&self) -> u64 {
        self.hook_errors
    }

    /// Returns the number of registered hooks.
    pub fn len(&self) -> usize {
        self.hooks.len()
    }

    /// Returns true if no hooks are registered.
    pub fn is_empty(&self) -> bool {
        self.hooks.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    // Verify hooks can be registered and counted
    #[test]
    fn test_hook_registration() {
        let mut hooks = TemplateHooks::new();
        assert_eq!(hooks.len(), 0);
        assert!(hooks.is_empty());

        hooks.register(|_| Ok(()));
        assert_eq!(hooks.len(), 1);
        assert!(!hooks.is_empty());
    }

    // Verify triggering an event increments the hook's counter
    #[test]
    fn test_hook_triggering() {
        let mut hooks = TemplateHooks::new();
        let counter = Arc::new(AtomicUsize::new(0));
        let counter_clone = counter.clone();

        hooks.register(move |_| {
            counter_clone.fetch_add(1, Ordering::SeqCst);
            Ok(())
        });

        let event = TemplateEvent::Learned {
            template_id: Some(256),
            protocol: TemplateProtocol::V9,
        };

        hooks.trigger(&event);
        assert_eq!(counter.load(Ordering::SeqCst), 1);

        hooks.trigger(&event);
        assert_eq!(counter.load(Ordering::SeqCst), 2);
    }

    // Verify multiple hooks all fire on a single event trigger
    #[test]
    fn test_multiple_hooks() {
        let mut hooks = TemplateHooks::new();
        let counter1 = Arc::new(AtomicUsize::new(0));
        let counter2 = Arc::new(AtomicUsize::new(0));

        let c1 = counter1.clone();
        let c2 = counter2.clone();

        hooks.register(move |_| {
            c1.fetch_add(1, Ordering::SeqCst);
            Ok(())
        });

        hooks.register(move |_| {
            c2.fetch_add(10, Ordering::SeqCst);
            Ok(())
        });

        let event = TemplateEvent::Collision {
            template_id: Some(300),
            protocol: TemplateProtocol::Ipfix,
        };

        hooks.trigger(&event);

        assert_eq!(counter1.load(Ordering::SeqCst), 1);
        assert_eq!(counter2.load(Ordering::SeqCst), 10);
    }

    // Verify hooks can match on specific event variants
    #[test]
    fn test_hook_event_matching() {
        let mut hooks = TemplateHooks::new();
        let learned_count = Arc::new(AtomicUsize::new(0));
        let collision_count = Arc::new(AtomicUsize::new(0));

        let lc = learned_count.clone();
        let cc = collision_count.clone();

        hooks.register(move |event| {
            match event {
                TemplateEvent::Learned { .. } => {
                    lc.fetch_add(1, Ordering::SeqCst);
                }
                TemplateEvent::Collision { .. } => {
                    cc.fetch_add(1, Ordering::SeqCst);
                }
                _ => {}
            }
            Ok(())
        });

        hooks.trigger(&TemplateEvent::Learned {
            template_id: Some(256),
            protocol: TemplateProtocol::V9,
        });
        hooks.trigger(&TemplateEvent::Collision {
            template_id: Some(300),
            protocol: TemplateProtocol::Ipfix,
        });
        hooks.trigger(&TemplateEvent::Learned {
            template_id: Some(400),
            protocol: TemplateProtocol::V9,
        });

        assert_eq!(learned_count.load(Ordering::SeqCst), 2);
        assert_eq!(collision_count.load(Ordering::SeqCst), 1);
    }

    // Verify TemplateEvent implements Clone with matching fields
    #[test]
    fn test_template_event_clone() {
        let event = TemplateEvent::Evicted {
            template_id: Some(500),
            protocol: TemplateProtocol::Ipfix,
        };

        let cloned = event.clone();

        match (event, cloned) {
            (
                TemplateEvent::Evicted {
                    template_id: id1,
                    protocol: p1,
                },
                TemplateEvent::Evicted {
                    template_id: id2,
                    protocol: p2,
                },
            ) => {
                assert_eq!(id1, id2);
                assert_eq!(p1, p2);
            }
            _ => panic!("Event didn't match after clone"),
        }
    }
}
