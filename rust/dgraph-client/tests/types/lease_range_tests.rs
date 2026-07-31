/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::LeaseRange;

#[test]
fn reports_both_bounds_verbatim() {
    let range = LeaseRange::new(1000, 1010);

    assert_eq!(range.start(), 1000);
    assert_eq!(range.end(), 1010);
}

// api.proto annotates `end` as inclusive while the Go client documents [start, end).
// len_exclusive commits to the Go reading, which is what its callers rely on.
#[test]
fn len_exclusive_uses_the_go_client_reading() {
    assert_eq!(LeaseRange::new(1000, 1010).len_exclusive(), 10);
}

// Must not underflow if a server ever reports end < start.
#[test]
fn len_exclusive_saturates_rather_than_underflowing() {
    assert_eq!(LeaseRange::new(10, 5).len_exclusive(), 0);
}

#[test]
fn empty_range_has_no_ids() {
    assert_eq!(LeaseRange::new(7, 7).len_exclusive(), 0);
}
