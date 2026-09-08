use rustler::{Encoder, Env, Term};
use serde_json::Value;
use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::Arc;
use std::sync::{Mutex, OnceLock};
use zen_engine::loader::MemoryLoader;
use zen_engine::model::DecisionContent;
use zen_engine::nodes::custom::NoopCustomNode;
use zen_engine::DecisionEngine;

static ENGINE_CACHE: OnceLock<Mutex<HashMap<u64, DecisionEngine>>> = OnceLock::new();

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn evaluate_rules(env: Env, context_json: String, rules: Vec<(String, String)>) -> Term {
    match evaluate_rules_impl(context_json, rules) {
        Ok(json) => (atoms::ok(), json).encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

fn evaluate_rules_impl(
    context_json: String,
    rules: Vec<(String, String)>,
) -> Result<String, String> {
    let mut context: Value = serde_json::from_str(&context_json)
        .map_err(|err| format!("invalid context JSON: {err}"))?;

    if rules.is_empty() {
        return serde_json::to_string(&context)
            .map_err(|err| format!("failed to encode normalized JSON: {err}"));
    }

    let engine = cached_engine(&rules)?;

    for (key, _) in rules {
        let previous = context.clone();
        let response = futures::executor::block_on(engine.evaluate(&key, previous.clone().into()))
            .map_err(|err| format!("failed to evaluate Zen rule {key}: {err}"))?;

        context = merge_rule_result(previous, Value::from(response.result));
    }

    serde_json::to_string(&context)
        .map_err(|err| format!("failed to encode normalized JSON: {err}"))
}

fn cached_engine(rules: &[(String, String)]) -> Result<DecisionEngine, String> {
    let cache_key = rule_set_hash(rules);
    let cache = ENGINE_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

    {
        let guard = cache
            .lock()
            .map_err(|_| "Zen rule engine cache poisoned".to_string())?;

        if let Some(engine) = guard.get(&cache_key) {
            return Ok(engine.clone());
        }
    }

    let engine = build_engine(rules)?;
    let mut guard = cache
        .lock()
        .map_err(|_| "Zen rule engine cache poisoned".to_string())?;

    Ok(guard.entry(cache_key).or_insert_with(|| engine).clone())
}

fn build_engine(rules: &[(String, String)]) -> Result<DecisionEngine, String> {
    let loader = MemoryLoader::default();
    for (key, rule_json) in rules {
        let content: DecisionContent = serde_json::from_str(rule_json)
            .map_err(|err| format!("invalid Zen rule {key}: {err}"))?;
        loader.add(key, content);
    }

    Ok(DecisionEngine::new(
        Arc::new(loader),
        Arc::new(NoopCustomNode),
    ))
}

fn rule_set_hash(rules: &[(String, String)]) -> u64 {
    let mut hasher = DefaultHasher::new();

    for (key, rule_json) in rules {
        key.hash(&mut hasher);
        rule_json.hash(&mut hasher);
    }

    hasher.finish()
}

fn merge_rule_result(previous: Value, result: Value) -> Value {
    match (previous, result) {
        (Value::Object(mut previous), Value::Object(result)) => {
            for (key, value) in result {
                let merged = match (previous.remove(&key), value) {
                    (Some(Value::Object(previous_nested)), Value::Object(result_nested)) => {
                        merge_rule_result(
                            Value::Object(previous_nested),
                            Value::Object(result_nested),
                        )
                    }
                    (_, value) => value,
                };

                previous.insert(key, merged);
            }

            Value::Object(previous)
        }
        (_, result) => result,
    }
}

rustler::init!("Elixir.ServiceRadar.Observability.Zen.Native");
