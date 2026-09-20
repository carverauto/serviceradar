use dgraph_migrate::SchemaReport;

#[test]
fn empty_report_is_complete() {
    let report = SchemaReport::new(Vec::new(), Vec::new());
    assert!(report.is_complete());
    assert!(report.missing_predicates().is_empty());
    assert!(report.missing_types().is_empty());
}

#[test]
fn missing_predicate_is_incomplete() {
    let report = SchemaReport::new(vec!["device.id".to_string()], Vec::new());
    assert!(!report.is_complete());
    assert_eq!(report.missing_predicates(), &["device.id".to_string()]);
}

#[test]
fn missing_type_is_incomplete() {
    let report = SchemaReport::new(Vec::new(), vec!["Device".to_string()]);
    assert!(!report.is_complete());
    assert_eq!(report.missing_types(), &["Device".to_string()]);
}
