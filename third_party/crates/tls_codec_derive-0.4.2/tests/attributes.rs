#[test]
fn attributes() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/attributes/*.rs");
}
