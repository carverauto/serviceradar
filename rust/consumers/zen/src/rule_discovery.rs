use anyhow::Result;
use async_nats::jetstream;
use futures::TryStreamExt;
use serde::Deserialize;

use crate::config::Config;

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RuleIndex {
    Object { rules: Vec<RuleIndexEntry> },
    List(Vec<RuleIndexEntry>),
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RuleIndexEntry {
    Object { key: String, order: Option<u32> },
    Key(String),
}

#[derive(Debug)]
struct OrderedRule {
    order: u32,
    key: String,
}

pub async fn ordered_rules_for_subject(
    cfg: &Config,
    js: &jetstream::Context,
    subject: &str,
) -> Result<Vec<String>> {
    let configured = cfg.configured_rules_for_subject(subject);

    if !cfg.discover_rules_from_kv {
        return Ok(configured);
    }

    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let rule_subject = cfg.subject_for_rule_lookup(subject);
    let prefix = rule_prefix(cfg, rule_subject);

    if let Some(bytes) = store.get(format!("{prefix}/_rules.json")).await? {
        return Ok(parse_rule_index(&bytes));
    }

    if !configured.is_empty() {
        return Ok(configured);
    }

    let mut keys = store.keys().await?;
    let mut rules = Vec::new();

    while let Some(key) = keys.try_next().await? {
        if let Some(rule) = rule_name_from_key(&key, &prefix) {
            rules.push(rule);
        }
    }

    rules.sort();
    rules.dedup();
    Ok(rules)
}

fn parse_rule_index(bytes: &[u8]) -> Vec<String> {
    match serde_json::from_slice::<RuleIndex>(bytes) {
        Ok(RuleIndex::Object { rules }) | Ok(RuleIndex::List(rules)) => {
            let mut ordered = rules
                .into_iter()
                .enumerate()
                .map(|(idx, entry)| match entry {
                    RuleIndexEntry::Object { key, order } => OrderedRule {
                        order: order.unwrap_or(idx as u32),
                        key,
                    },
                    RuleIndexEntry::Key(key) => OrderedRule {
                        order: idx as u32,
                        key,
                    },
                })
                .collect::<Vec<_>>();

            ordered.sort_by_key(|rule| (rule.order, rule.key.clone()));
            ordered.into_iter().map(|rule| rule.key).collect()
        }
        Err(_) => Vec::new(),
    }
}

fn rule_prefix(cfg: &Config, subject: &str) -> String {
    format!("agents/{}/{}/{}", cfg.agent_id, cfg.stream_name, subject)
}

fn rule_name_from_key(key: &str, prefix: &str) -> Option<String> {
    let suffix = key.strip_prefix(&format!("{prefix}/"))?;

    if suffix == "_rules.json" || suffix.contains('/') || !suffix.ends_with(".json") {
        return None;
    }

    Some(suffix.trim_end_matches(".json").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ordered_rule_index_object() {
        let rules = parse_rule_index(
            br#"{"rules":[{"key":"cef_severity","order":120},{"key":"coraza_waf","order":105},{"key":"strip_full_message","order":110}]}"#,
        );

        assert_eq!(
            rules,
            vec!["coraza_waf", "strip_full_message", "cef_severity"]
        );
    }

    #[test]
    fn extracts_rule_name_from_kv_key() {
        let prefix = "agents/default-agent/events/logs.syslog";

        assert_eq!(
            rule_name_from_key(
                "agents/default-agent/events/logs.syslog/coraza_waf.json",
                prefix
            ),
            Some("coraza_waf".to_string())
        );
        assert_eq!(
            rule_name_from_key(
                "agents/default-agent/events/logs.syslog/_rules.json",
                prefix
            ),
            None
        );
    }
}
