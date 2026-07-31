/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::Secret;

#[test]
fn exposes_the_underlying_value() {
    let secret = Secret::new("hunter2");

    assert_eq!(secret.expose(), "hunter2");
}

#[test]
fn debug_is_redacted() {
    let secret = Secret::new("hunter2");

    let rendered = format!("{secret:?}");
    assert!(!rendered.contains("hunter2"), "leaked: {rendered}");
    assert_eq!(rendered, "Secret(<redacted>)");
}

#[test]
fn display_is_redacted() {
    let secret = Secret::new("hunter2");

    let rendered = format!("{secret}");
    assert!(!rendered.contains("hunter2"), "leaked: {rendered}");
    assert_eq!(rendered, "<redacted>");
}

// A secret nested inside a derived-Debug container must still be redacted, which is what
// makes the wrapper safe to embed anywhere.
#[test]
fn redaction_survives_nesting() {
    #[derive(Debug)]
    struct Holder {
        token: Secret,
    }

    let holder = Holder {
        token: Secret::new("hunter2"),
    };

    let rendered = format!("{holder:?}");
    assert!(!rendered.contains("hunter2"), "leaked: {rendered}");
    // Read the field directly too, proving redaction is a property of Secret rather than
    // of the container losing the value.
    assert_eq!(holder.token.expose(), "hunter2");
}

#[test]
fn reports_empty() {
    assert!(Secret::new("").is_empty());
    assert!(!Secret::new("x").is_empty());
}
