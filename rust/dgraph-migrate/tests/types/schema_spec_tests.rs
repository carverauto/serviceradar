use dgraph_migrate::SchemaSpec;

#[test]
fn new_preserves_lists() {
    const SCHEMA: &str = "device.id: string @index(exact) @upsert .";
    const PREDICATES: &[&str] = &["device.id"];
    const TYPES: &[&str] = &["Device"];
    let spec = SchemaSpec::new(SCHEMA, PREDICATES, TYPES);
    assert_eq!(spec.schema(), SCHEMA);
    assert_eq!(spec.predicates(), PREDICATES);
    assert_eq!(spec.types(), TYPES);
}
