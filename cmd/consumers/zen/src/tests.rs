use std::fs;

#[test]
fn test_host_switch_testdata_parses() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/host_switch.json");
    let data = fs::read_to_string(path).unwrap();
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data).unwrap();
    assert!(!parsed.nodes.is_empty());
}