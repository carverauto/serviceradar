use dgraph_test::HealthReport;
use dgraph_test::utils_tests::{HEALTHY_BODY, UNHEALTHY_BODY};

const URL: &str = "https://h:8080/health?all";

#[test]
fn parses_a_real_v25_response() {
    let report = HealthReport::parse(URL, HEALTHY_BODY).expect("a valid report");

    assert!(report.all_healthy());
    assert_eq!(report.count("zero"), 1);
    assert_eq!(report.count("alpha"), 1);

    let alpha = report
        .servers()
        .iter()
        .find(|s| s.instance() == "alpha")
        .expect("an alpha entry");
    assert_eq!(alpha.group(), "1");
    assert_eq!(alpha.version(), "v25.4.0");
}

#[test]
fn one_unhealthy_server_fails_the_whole_report() {
    let report = HealthReport::parse(URL, UNHEALTHY_BODY).expect("a valid report");
    assert!(!report.all_healthy());
    assert!(report.describe().contains("unhealthy"));
}

/// An empty array parses fine and would otherwise satisfy "all healthy" vacuously -- which is
/// exactly the answer a half-started cluster gives.
#[test]
fn an_empty_report_is_not_healthy() {
    let report = HealthReport::parse(URL, "[]").expect("an empty array is valid JSON");
    assert!(!report.all_healthy());
    assert_eq!(report.describe(), "no servers reported");
}

/// Dgraph adds keys between versions. A health check that breaks on a new optional field is
/// worse than no health check.
#[test]
fn unknown_fields_are_ignored_and_missing_ones_do_not_fail() {
    let body = r#"[{"instance":"alpha","status":"healthy","some_future_field":{"a":1}}]"#;
    let report = HealthReport::parse(URL, body).expect("tolerant of unknown keys");
    assert!(report.all_healthy());
    assert_eq!(report.servers()[0].address(), "");
}

/// Something other than Dgraph answering IS an error: an HTML error page or a login redirect
/// must not read as a healthy cluster.
#[test]
fn a_non_array_body_is_an_error() {
    for body in ["<html>502 Bad Gateway</html>", "{\"errors\":[]}"] {
        let err = HealthReport::parse(URL, body).expect_err("must not parse as a report");
        assert!(err.to_string().contains(URL), "{err}");
    }
}
