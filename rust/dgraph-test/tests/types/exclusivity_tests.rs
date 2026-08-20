use dgraph_test::Exclusivity;

#[test]
fn only_an_exclusive_instance_may_be_destroyed() {
    assert!(Exclusivity::Exclusive.may_destroy());
    assert!(!Exclusivity::Shared.may_destroy());
}
