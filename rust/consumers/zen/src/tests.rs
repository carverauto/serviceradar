use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;
use serde_json::Value;
use zen_engine::DecisionEngine;

fn testdata_path(relative: &str) -> PathBuf {
    let runfile_rel = Path::new("rust/consumers/zen").join(relative);

    let check_candidates = |base: &Path| {
        let mut candidates = vec![base.join(&runfile_rel)];

        if let Ok(ws) = env::var("TEST_WORKSPACE") {
            candidates.push(base.join(ws).join(&runfile_rel));
        }

        candidates.push(base.join("__main").join(&runfile_rel));
        candidates.push(base.join("__main__").join(&runfile_rel));

        candidates.retain(|p| p.exists());
        candidates.into_iter().next()
    };

    if let Ok(runfiles_dir) = env::var("RUNFILES_DIR") {
        if let Some(found) = check_candidates(Path::new(&runfiles_dir)) {
            return found;
        }
    }

    if let Ok(test_srcdir) = env::var("TEST_SRCDIR") {
        if let Some(found) = check_candidates(Path::new(&test_srcdir)) {
            return found;
        }
    }

    Path::new(env!("CARGO_MANIFEST_DIR")).join(relative)
}

#[test]
fn test_host_switch_testdata_parses() {
    let path = testdata_path("testdata/host_switch.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", path.display(), e));
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data).unwrap();
    assert!(!parsed.nodes.is_empty());
}

#[test]
fn packaging_rules_parse() {
    let rules_dir = packaging_rules_dir();

    // Skip test if packaging rules directory doesn't exist (e.g., in Bazel sandbox)
    if !rules_dir.is_dir() {
        eprintln!(
            "Skipping packaging_rules_parse: directory not found at {}",
            rules_dir.display()
        );
        return;
    }

    for entry in fs::read_dir(&rules_dir).expect("list packaging rules") {
        let entry = entry.expect("read dir entry");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let data = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
        let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data)
            .unwrap_or_else(|e| panic!("{} failed to parse: {e}", path.display()));
        assert!(
            !parsed.nodes.is_empty(),
            "{} parsed but contained no nodes",
            path.display()
        );
    }
}

#[test]
fn snmp_severity_rule_uses_supported_fallback_expression() {
    let path = packaging_rules_dir().join("snmp_severity.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    let parsed: Value = serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("{} failed to parse as json: {e}", path.display()));

    let expressions = parsed["nodes"]
        .as_array()
        .and_then(|nodes| nodes.iter().find(|node| node["id"] == "setSeverity"))
        .and_then(|node| node["content"]["expressions"].as_array())
        .unwrap_or_else(|| panic!("{} missing snmp expressions", path.display()));

    let severity_expression = expressions
        .iter()
        .find(|expr| expr["key"] == "severity")
        .and_then(|expr| expr["value"].as_str())
        .unwrap_or_else(|| panic!("{} missing snmp severity expression", path.display()));

    let source_expression = expressions
        .iter()
        .find(|expr| expr["key"] == "source")
        .and_then(|expr| expr["value"].as_str())
        .unwrap_or_else(|| panic!("{} missing snmp source expression", path.display()));

    let service_name_expression = expressions
        .iter()
        .find(|expr| expr["key"] == "service_name")
        .and_then(|expr| expr["value"].as_str())
        .unwrap_or_else(|| panic!("{} missing snmp service_name expression", path.display()));

    let body_expression = expressions
        .iter()
        .find(|expr| expr["key"] == "body")
        .and_then(|expr| expr["value"].as_str())
        .unwrap_or_else(|| panic!("{} missing snmp body expression", path.display()));

    assert_eq!(severity_expression, "severity ?? 'Unknown'");
    assert_eq!(source_expression, "'snmp'");
    assert_eq!(service_name_expression, "'snmp'");
    assert_eq!(
        body_expression,
        "(((body ?? '') == '') or body == 'logs.snmp.processed') ? (len(varbinds ?? []) > 0 ? (extract(varbinds[0].value ?? '', '^[^:]+: (.*)$')[1] ?? varbinds[0].value ?? body ?? '') : (body ?? '')) : body"
    );
    assert!(!severity_expression.contains("coalesce("));
}

#[tokio::test]
async fn snmp_severity_rule_sets_body_from_first_varbind() {
    let path = packaging_rules_dir().join("snmp_severity.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("{} failed to parse: {e}", path.display()));

    let decision = DecisionEngine::default().create_decision(parsed.into());
    let response = decision
        .evaluate(
            json!({
                "body": "logs.snmp.processed",
                "varbinds": [
                    {
                        "oid": "1.3.6.1.2.1.16.9.1.1.2.4911",
                        "value": "OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
                    }
                ]
            })
            .into(),
        )
        .await
        .expect("evaluate snmp rule");

    let result = Value::from(response.result);
    assert_eq!(
        result["body"],
        "I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
    );
    assert_eq!(result["service_name"], "snmp");
    assert_eq!(result["source"], "snmp");
}

#[tokio::test]
async fn snmp_severity_rule_sets_body_from_first_varbind_when_body_is_missing() {
    let path = packaging_rules_dir().join("snmp_severity.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("{} failed to parse: {e}", path.display()));

    let decision = DecisionEngine::default().create_decision(parsed.into());
    let response = decision
        .evaluate(
            json!({
                "varbinds": [
                    {
                        "oid": "1.3.6.1.2.1.16.9.1.1.2.4911",
                        "value": "OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
                    }
                ]
            })
            .into(),
        )
        .await
        .expect("evaluate snmp rule");

    let result = Value::from(response.result);
    assert_eq!(
        result["body"],
        "I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
    );
    assert_eq!(result["service_name"], "snmp");
    assert_eq!(result["source"], "snmp");
}

#[tokio::test]
async fn expression_rule_can_set_nested_attribute_paths() {
    let parsed: zen_engine::model::DecisionContent = serde_json::from_value(json!({
        "nodes": [
            { "id": "inputNode", "type": "inputNode", "name": "Request", "position": { "x": 80, "y": 150 } },
            {
                "id": "setNested",
                "type": "expressionNode",
                "name": "Set Nested",
                "position": { "x": 300, "y": 150 },
                "content": {
                    "expressions": [
                        { "id": "expr1", "key": "attributes.event_type", "value": "'waf.finding'" },
                        { "id": "expr2", "key": "attributes.waf.rule_id", "value": "'941100'" }
                    ]
                }
            },
            { "id": "outputNode", "type": "outputNode", "name": "Response", "position": { "x": 560, "y": 150 } }
        ],
        "edges": [
            { "id": "e1", "sourceId": "inputNode", "targetId": "setNested", "type": "edge" },
            { "id": "e2", "sourceId": "setNested", "targetId": "outputNode", "type": "edge" }
        ]
    }))
    .expect("nested expression rule parses");

    let decision = DecisionEngine::default().create_decision(parsed.into());
    let response = decision
        .evaluate(json!({}).into())
        .await
        .expect("evaluate nested expression rule");

    let result = Value::from(response.result);
    assert_eq!(result["attributes"]["event_type"], "waf.finding");
    assert_eq!(result["attributes"]["waf"]["rule_id"], "941100");
}

#[tokio::test]
async fn coraza_waf_rule_normalizes_vector_payload() {
    let path = packaging_rules_dir().join("coraza_waf.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("{} failed to parse: {e}", path.display()));

    let decision = DecisionEngine::default().create_decision(parsed.into());
    let response = decision
        .evaluate(
            json!({
                "short_message": "envoy-coraza-waf: {\"event\":\"waf.finding\",\"source\":\"coraza-proxy-wasm\",\"waf_policy\":\"serviceradar-shared-coraza-waf\",\"summary\":\"WAF critical rule 941100: XSS Attack Detected via libinjection /\",\"rule_id\":\"941100\",\"rule_message\":\"XSS Attack Detected via libinjection\",\"rule_severity\":\"critical\",\"client_ip\":\"192.0.2.10\",\"request_path\":\"/\",\"request_query\":\"<redacted>\",\"request_id\":\"req-1\",\"raw_redacted\":true}",
                "host": "serviceradar-edge",
                "severity_text": "WARN"
            })
            .into(),
        )
        .await
        .expect("evaluate coraza waf rule");

    let result = Value::from(response.result);
    assert_eq!(result["event_name"], "waf.finding");
    assert_eq!(result["source"], "waf");
    assert_eq!(result["service_name"], "envoy-coraza-waf");
    assert_eq!(result["severity_text"], "critical");
    assert_eq!(
        result["body"],
        "WAF critical rule 941100: XSS Attack Detected via libinjection /"
    );
    assert_eq!(result["attributes"]["event_type"], "waf.finding");
    assert_eq!(result["attributes"]["security"]["signal"]["kind"], "waf");
    assert_eq!(
        result["attributes"]["security"]["signal"]["source"],
        "coraza-proxy-wasm"
    );
    assert_eq!(result["attributes"]["waf"]["rule_id"], "941100");
    assert_eq!(result["attributes"]["waf"]["client_ip"], "192.0.2.10");
    assert_eq!(result["attributes"]["waf"]["request_query"], "<redacted>");
}

#[tokio::test]
async fn cef_severity_rule_outputs_severity_delta() {
    let path = packaging_rules_dir().join("cef_severity.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("{} failed to parse: {e}", path.display()));

    let decision = DecisionEngine::default().create_decision(parsed.into());
    let input = json!({
        "host": "docker-mailserver-6bbcfbc66c-p4xjt",
        "short_message": "dovecot: disconnected",
        "full_message": "<22>Apr 29 21:03:39 docker-mailserver dovecot: disconnected"
    });

    let response = decision
        .evaluate(input.clone().into())
        .await
        .expect("evaluate cef severity rule");

    let result = Value::from(response.result);
    assert_eq!(result["severity"], "Unknown");
}

fn packaging_rules_dir() -> PathBuf {
    let runfile_rel = Path::new("build/packaging/zen/rules");

    let check_candidates = |base: &Path| {
        let mut candidates = vec![base.join(runfile_rel)];

        if let Ok(ws) = env::var("TEST_WORKSPACE") {
            candidates.push(base.join(ws).join(runfile_rel));
        }

        candidates.push(base.join("__main").join(runfile_rel));
        candidates.push(base.join("__main__").join(runfile_rel));

        candidates.retain(|p| p.exists());
        candidates.into_iter().next()
    };

    if let Ok(runfiles_dir) = env::var("RUNFILES_DIR") {
        if let Some(found) = check_candidates(Path::new(&runfiles_dir)) {
            return found;
        }
    }

    if let Ok(test_srcdir) = env::var("TEST_SRCDIR") {
        if let Some(found) = check_candidates(Path::new(&test_srcdir)) {
            return found;
        }
    }

    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../build/packaging/zen/rules")
}
