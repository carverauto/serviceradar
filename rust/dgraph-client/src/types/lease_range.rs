/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

/// A range of identifiers leased from the cluster.
///
/// # Bound semantics
///
/// The upstream sources disagree. `api.proto` annotates the `end` field of
/// `AllocateIDsResponse` with `// inclusive`, while the Go client documents
/// `AllocateUIDs` as returning "a start and end UIDs, end excluded" and describes the
/// usable range as `[start, end)`.
///
/// This type reports both bounds verbatim as the server sent them and does not pick a
/// side. Use [`LeaseRange::start`] and [`LeaseRange::end`] and apply whichever convention
/// your cluster version actually implements; [`LeaseRange::len_exclusive`] assumes the Go
/// client's `[start, end)` reading, which is the one its callers rely on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LeaseRange {
    start: u64,
    end: u64,
}

impl LeaseRange {
    /// Construct a range from explicit bounds.
    ///
    /// Public so callers can build one in their own tests; the client constructs these
    /// from server responses.
    pub fn new(start: u64, end: u64) -> Self {
        Self { start, end }
    }

    /// First identifier in the range.
    pub fn start(&self) -> u64 {
        self.start
    }

    /// Upper bound exactly as the server reported it. See the type docs on whether this is
    /// inclusive.
    pub fn end(&self) -> u64 {
        self.end
    }

    /// Count of identifiers under the `[start, end)` reading, saturating rather than
    /// underflowing if the server ever reports `end < start`.
    pub fn len_exclusive(&self) -> u64 {
        self.end.saturating_sub(self.start)
    }
}
