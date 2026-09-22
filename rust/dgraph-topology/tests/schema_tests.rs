use dgraph_topology::{PREDICATES, SCHEMA, TYPES, schema_spec};

const ALLOWED_PREFIXES: &[&str] = &[
    "device.",
    "iface.",
    "hop.",
    "collector.",
    "topo.",
    "prefix.",
    "change.",
];

#[test]
fn every_predicate_is_namespaced() {
    for pred in PREDICATES {
        assert!(
            ALLOWED_PREFIXES
                .iter()
                .any(|prefix| pred.starts_with(prefix)),
            "unprefixed or foreign predicate: {pred}"
        );
        assert!(!pred.starts_with("svc."), "scrith predicate leaked: {pred}");
        assert!(
            !pred.starts_with("endpoint."),
            "scrith predicate leaked: {pred}"
        );
        assert_ne!(*pred, "id");
        assert_ne!(*pred, "name");
    }
}

#[test]
fn schema_declares_every_listed_predicate_and_type() {
    for pred in PREDICATES {
        let needle = format!("{pred}:");
        assert!(SCHEMA.contains(&needle), "SCHEMA missing {pred}");
    }
    for ty in TYPES {
        let needle = format!("type {ty} {{");
        assert!(SCHEMA.contains(&needle), "SCHEMA missing type {ty}");
    }
}

#[test]
fn upsert_keys_are_marked() {
    assert!(SCHEMA.contains("device.id: string @index(exact) @upsert"));
    assert!(SCHEMA.contains("topo.link_key: string @index(exact) @upsert"));
    assert!(SCHEMA.contains("prefix.cidr: string @index(exact) @upsert"));
    assert!(SCHEMA.contains("change.id: string @index(exact) @upsert"));
}

#[test]
fn required_types_are_present() {
    for ty in [
        "Device",
        "Interface",
        "HopNode",
        "Collector",
        "Service",
        "TopologyEdge",
        "Prefix",
        "Change",
    ] {
        assert!(TYPES.contains(&ty), "missing type {ty}");
    }
}

#[test]
fn schema_spec_matches_constants() {
    let spec = schema_spec();
    assert_eq!(spec.schema(), SCHEMA);
    assert_eq!(spec.predicates(), PREDICATES);
    assert_eq!(spec.types(), TYPES);
}

#[test]
fn schema_does_not_mention_drop_all() {
    assert!(!SCHEMA.to_ascii_lowercase().contains("drop_all"));
    assert!(!SCHEMA.contains("svc."));
    assert!(!SCHEMA.contains("endpoint."));
}

#[test]
fn src_and_dst_are_reverse_uid_edges() {
    assert!(SCHEMA.contains("topo.src: [uid] @reverse"));
    assert!(SCHEMA.contains("topo.dst: [uid] @reverse"));
}

#[test]
fn device_interfaces_stay_plain_uid() {
    assert!(SCHEMA.contains("device.interfaces: [uid] @reverse"));
}

#[test]
fn change_has_no_body_predicate() {
    for pred in PREDICATES {
        assert!(!pred.contains("body"), "blob predicate on graph: {pred}");
        assert!(!pred.contains("comment"), "ticket dump on graph: {pred}");
    }
}
