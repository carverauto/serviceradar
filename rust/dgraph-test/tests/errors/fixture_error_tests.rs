use dgraph_test::{FixtureError, FixtureErrorEnum};

#[test]
fn unsupported_environment_names_the_supported_ones() {
    let err = FixtureError::new(FixtureErrorEnum::UnsupportedEnvironment {
        kind: "demo".to_string(),
    });
    let text = err.to_string();

    // The reader's next question is always "then which ones work", so the message answers it.
    assert!(text.contains("demo"), "{text}");
    assert!(text.contains("localhost"), "{text}");
    assert!(text.contains("ci"), "{text}");
    assert!(err.is_unsupported_environment());
    assert!(!err.is_not_ready());
}

#[test]
fn not_ready_carries_enough_to_diagnose() {
    let err = FixtureError::new(FixtureErrorEnum::NotReady {
        host: "alpha.example".to_string(),
        port: 9080,
        attempts: 7,
        last: "connection refused".to_string(),
    });
    let text = err.to_string();

    assert!(text.contains("alpha.example"), "{text}");
    assert!(text.contains("9080"), "{text}");
    assert!(text.contains('7'), "{text}");
    assert!(text.contains("connection refused"), "{text}");
    assert!(err.is_not_ready());
}

#[test]
fn kind_is_the_branching_surface() {
    let err = FixtureError::new(FixtureErrorEnum::Docker("no daemon".to_string()));
    assert!(matches!(err.kind(), FixtureErrorEnum::Docker(_)));
}
