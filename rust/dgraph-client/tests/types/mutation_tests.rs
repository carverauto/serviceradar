/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::Mutation;

#[test]
fn new_mutation_does_not_commit() {
    assert!(!Mutation::new().is_commit_now());
}

#[test]
fn commit_now_is_recorded() {
    assert!(Mutation::new().commit_now().is_commit_now());
}

#[test]
fn builder_methods_chain() {
    let mutation = Mutation::new()
        .set_json(br#"{"name":"alice"}"#.to_vec())
        .cond("@if(eq(len(v), 0))")
        .commit_now();

    assert!(mutation.is_commit_now());
}

// The Go client's DeleteEdges builds a mutation without sending anything; same here.
#[test]
fn delete_edges_builds_without_sending() {
    let mutation = Mutation::new().delete_edges("0x1", ["friend", "name"]);

    // Nothing to assert about the wire beyond it being constructible: the point is that
    // this is a pure builder with no RPC and no panic on an empty predicate list.
    assert!(!mutation.is_commit_now());
}

#[test]
fn delete_edges_accepts_an_empty_predicate_list() {
    let mutation = Mutation::new().delete_edges("0x1", Vec::<String>::new());

    assert!(!mutation.is_commit_now());
}

#[test]
fn set_and_delete_can_coexist() {
    let mutation = Mutation::new()
        .set_nquads(b"_:a <name> \"alice\" .".to_vec())
        .delete_nquads(b"_:b <name> * .".to_vec());

    assert!(!mutation.is_commit_now());
}
