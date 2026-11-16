//! The ruleset a collector is normalizing with.
//!
//! A collector offers every document it fetches from datasvc. A document is
//! activated only as a whole: its digest must match, every rule must compile
//! and it must be the bundle for this collector's stream and subject. Anything
//! else leaves the previous ruleset active and is reported as stale, so a bad
//! update or a deleted key never stops normalization or changes its rules.
//! Before the first valid document there is no ruleset, and the collector is
//! not ready to normalize.

use crate::{BundleError, RuleBundle};
use std::sync::Mutex;

/// What the collector can say about its rules without evaluating any.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RulesStatus {
    /// No valid ruleset has arrived. `problem` is the last failure, if any.
    Missing { problem: Option<String> },
    /// The newest offered ruleset is active.
    Current { digest: String },
    /// An older ruleset is still active because of `problem`.
    Stale { digest: String, problem: String },
}

/// The result of offering a valid document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Offer {
    Activated,
    /// The document is the ruleset already active.
    Unchanged,
}

pub struct ActiveRules {
    stream_name: String,
    subject: String,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    active: Option<RuleBundle>,
    problem: Option<String>,
}

impl ActiveRules {
    pub fn new(stream_name: impl Into<String>, subject: impl Into<String>) -> Self {
        Self {
            stream_name: stream_name.into(),
            subject: subject.into(),
            state: Mutex::default(),
        }
    }

    /// Validates a fetched document and activates it. On an error the previous
    /// ruleset stays active and the status carries the error.
    pub fn offer(&self, document: &[u8]) -> Result<Offer, BundleError> {
        let candidate = RuleBundle::parse(document).and_then(|bundle| {
            if bundle.stream_name == self.stream_name && bundle.subject == self.subject {
                Ok(bundle)
            } else {
                Err(BundleError::Scope {
                    stream_name: bundle.stream_name,
                    subject: bundle.subject,
                })
            }
        });
        let mut state = self.lock();
        match candidate {
            Ok(bundle) => {
                state.problem = None;
                if state
                    .active
                    .as_ref()
                    .is_some_and(|active| active.digest == bundle.digest)
                {
                    return Ok(Offer::Unchanged);
                }
                state.active = Some(bundle);
                Ok(Offer::Activated)
            }
            Err(error) => {
                state.problem = Some(error.to_string());
                Err(error)
            }
        }
    }

    /// Records that datasvc could not be reached or watched, so the active
    /// ruleset may be behind. The next valid offer clears it.
    pub fn report_unavailable(&self, problem: impl Into<String>) {
        self.lock().problem = Some(problem.into());
    }

    /// The active ruleset. Take it once per batch so every record in the batch
    /// is normalized by one version.
    pub fn current(&self) -> Option<RuleBundle> {
        self.lock().active.clone()
    }

    pub fn status(&self) -> RulesStatus {
        let state = self.lock();
        match (&state.active, &state.problem) {
            (None, problem) => RulesStatus::Missing {
                problem: problem.clone(),
            },
            (Some(active), None) => RulesStatus::Current {
                digest: active.digest.clone(),
            },
            (Some(active), Some(problem)) => RulesStatus::Stale {
                digest: active.digest.clone(),
                problem: problem.clone(),
            },
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        // The state is replaced whole, so a holder that panicked left it valid.
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}
