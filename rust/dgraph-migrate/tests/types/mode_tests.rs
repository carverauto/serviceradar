use dgraph_migrate::{CONFIRM_VALUE, Environment, Mode, ModeErrorEnum};

#[test]
fn default_is_migrate() {
    let mode = Mode::resolve(None, None, Some(Environment::Local)).expect("default");
    assert_eq!(mode, Mode::Migrate);
    assert!(!mode.is_destructive());
}

#[test]
fn status_is_read_only() {
    let mode = Mode::resolve(Some("status".to_string()), None, Some(Environment::Cluster))
        .expect("status");
    assert_eq!(mode, Mode::Status);
    assert!(!mode.is_destructive());
}

#[test]
fn unrecognised_mode_is_an_error() {
    let err = Mode::resolve(Some("drop_all".to_string()), None, Some(Environment::Local))
        .expect_err("drop_all is not a mode");
    assert!(matches!(err.kind(), ModeErrorEnum::Unrecognised(value) if value == "drop_all"));
}

#[test]
fn local_deprovision_does_not_need_confirm() {
    let mode = Mode::resolve(
        Some("DEPROVISION".to_string()),
        None,
        Some(Environment::Local),
    )
    .expect("local");
    assert_eq!(mode, Mode::Deprovision);
}

#[test]
fn cluster_deprovision_without_confirm_is_refused() {
    let err = Mode::resolve(
        Some("DEPROVISION".to_string()),
        None,
        Some(Environment::Cluster),
    )
    .expect_err("cluster");
    assert!(matches!(err.kind(), ModeErrorEnum::ConfirmationRequired));
}

#[test]
fn cluster_deprovision_with_confirm_is_allowed() {
    let mode = Mode::resolve(
        Some("DEPROVISION".to_string()),
        Some(CONFIRM_VALUE.to_string()),
        Some(Environment::Cluster),
    )
    .expect("confirmed");
    assert_eq!(mode, Mode::Deprovision);
}

#[test]
fn unknown_environment_refuses_deprovision() {
    let err = Mode::resolve(
        Some("DEPROVISION".to_string()),
        Some(CONFIRM_VALUE.to_string()),
        None,
    )
    .expect_err("unknown");
    assert!(matches!(
        err.kind(),
        ModeErrorEnum::RefusedInUnknownEnvironment
    ));
}

#[test]
fn true_is_not_a_confirm_value() {
    let err = Mode::resolve(
        Some("DEPROVISION".to_string()),
        Some("true".to_string()),
        Some(Environment::Cluster),
    )
    .expect_err("true");
    assert!(matches!(err.kind(), ModeErrorEnum::ConfirmationRequired));
}
