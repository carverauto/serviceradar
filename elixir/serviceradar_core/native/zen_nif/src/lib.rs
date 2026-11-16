#[cfg(panic = "abort")]
compile_error!("zen_nif requires panic=unwind to contain native panics");

use rustler::{Encoder, Env, Term};
use serviceradar_zen_normalize::RuleSet;
use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Mutex, OnceLock};

static RULE_SET_CACHE: OnceLock<Mutex<HashMap<u64, RuleSet>>> = OnceLock::new();

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn evaluate_rules(env: Env, context_json: String, rules: Vec<(String, String)>) -> Term {
    let normalized = cached_rule_set(&rules).and_then(|rule_set| {
        rule_set
            .normalize_json(&context_json)
            .map_err(|error| error.to_string())
    });
    match normalized {
        Ok(json) => (atoms::ok(), json).encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

fn cached_rule_set(rules: &[(String, String)]) -> Result<RuleSet, String> {
    let cache_key = rule_set_hash(rules);
    let cache = RULE_SET_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

    {
        let guard = cache
            .lock()
            .map_err(|_| "Zen rule engine cache poisoned".to_string())?;

        if let Some(rule_set) = guard.get(&cache_key) {
            return Ok(rule_set.clone());
        }
    }

    // Compile without holding the lock; a concurrent caller may compile the
    // same rules, and the first one stored is kept.
    let rule_set = RuleSet::compile(rules).map_err(|error| error.to_string())?;
    let mut guard = cache
        .lock()
        .map_err(|_| "Zen rule engine cache poisoned".to_string())?;

    Ok(guard.entry(cache_key).or_insert(rule_set).clone())
}

fn rule_set_hash(rules: &[(String, String)]) -> u64 {
    let mut hasher = DefaultHasher::new();

    for (key, rule_json) in rules {
        key.hash(&mut hasher);
        rule_json.hash(&mut hasher);
    }

    hasher.finish()
}

rustler::init!("Elixir.ServiceRadar.Observability.Zen.Native");
