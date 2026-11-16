//! Ordered Zen rule normalization shared by collectors and the core NIF.
//!
//! A [`RuleSet`] is compiled once from ordered `(key, JDM JSON)` pairs and then
//! applied to many records. Each rule sees the record as the previous rules
//! left it, and its result is laid over that record:
//!
//! - an object result merges into an object record key by key, recursively;
//! - an explicit `null` replaces the field and stays present;
//! - arrays and scalars replace the field;
//! - a field the result does not mention is kept.
//!
//! This is not Zen's built-in merge, which treats `null` differently.
//!
//! A rule removes a top-level field by returning its input and setting that
//! field to `null`. Zen deletes such a field from the rule's own result, so the
//! result alone cannot say whether the rule removed a field or never mentioned
//! it. A rule whose graph connects its input node directly to its output node
//! returns every field it was given; a field it was given and did not return
//! was therefore removed, and is removed from the record. Other rules cannot
//! remove top-level fields.
//!
//! Records stay [`Variable`] values between rules; strings are shared, not
//! copied. A record is JSON text only at [`RuleSet::normalize_json`], once on
//! the way in and once on the way out.
//!
//! Zen stores numbers as 96-bit decimals, so a number a rule returns comes back
//! in Zen's normal form (`1.0` becomes `1`). A JSON number no rule returns
//! keeps its original text, including one a decimal cannot hold, such as
//! `1e300`; rules see that one as `null`.

use std::any::Any;
use std::fmt;
use std::rc::Rc;
use std::sync::Arc;
use zen_engine::DecisionEngine;
use zen_engine::loader::MemoryLoader;
use zen_engine::model::{DecisionContent, DecisionNodeKind};
use zen_engine::nodes::custom::NoopCustomNode;

use zen_expression::variable::{DynamicVariable, Symbol};

mod bundle;

pub use bundle::{BUNDLE_SCHEMA, BundleError, RuleBundle};
pub use zen_engine::Variable;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid Zen rule {key}: {reason}")]
    InvalidRule { key: String, reason: String },
    #[error("failed to evaluate Zen rule {key}: {reason}")]
    Evaluation { key: String, reason: String },
    #[error("invalid context JSON: {0}")]
    InvalidContext(serde_json::Error),
    #[error("failed to encode normalized JSON: {0}")]
    Encode(serde_json::Error),
}

/// Ordered rules, parsed and compiled ahead of the records they normalize.
#[derive(Clone)]
pub struct RuleSet {
    engine: DecisionEngine,
    rules: Arc<[Rule]>,
}

struct Rule {
    key: String,
    /// The graph hands the rule's whole input to its output.
    returns_input: bool,
}

fn returns_input(content: &DecisionContent) -> bool {
    let DecisionContent::Graph(graph) = content else {
        return false;
    };
    let ids = |wanted: fn(&DecisionNodeKind) -> bool| {
        graph
            .nodes
            .iter()
            .filter(move |node| wanted(&node.kind))
            .map(|node| node.id.clone())
            .collect::<Vec<_>>()
    };
    let inputs = ids(|kind| matches!(kind, DecisionNodeKind::InputNode { .. }));
    let outputs = ids(|kind| matches!(kind, DecisionNodeKind::OutputNode { .. }));
    graph
        .edges
        .iter()
        .any(|edge| inputs.contains(&edge.source_id) && outputs.contains(&edge.target_id))
}

impl RuleSet {
    /// Parses every rule and compiles the set. A rule that parses but cannot be
    /// compiled is still accepted here and reports its error when evaluated,
    /// which is where an uncompiled rule reports it.
    pub fn compile<K, R>(rules: &[(K, R)]) -> Result<Self, Error>
    where
        K: AsRef<str>,
        R: AsRef<str>,
    {
        let loader = MemoryLoader::default();
        let mut compiled = Vec::with_capacity(rules.len());
        for (key, rule_json) in rules {
            let key = key.as_ref();
            let content: DecisionContent =
                serde_json::from_str(rule_json.as_ref()).map_err(|error| Error::InvalidRule {
                    key: key.to_owned(),
                    reason: error.to_string(),
                })?;
            compiled.push(Rule {
                key: key.to_owned(),
                returns_input: returns_input(&content),
            });
            loader.add(key, content);
        }
        let engine = DecisionEngine::new(Arc::new(loader), Arc::new(NoopCustomNode));
        engine.compile();
        Ok(Self {
            engine,
            rules: compiled.into(),
        })
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// Applies every rule in order and returns the normalized record.
    pub fn normalize(&self, record: Variable) -> Result<Variable, Error> {
        let mut record = record;
        for rule in self.rules.iter() {
            let context = rule_context(&record);
            let given = if rule.returns_input {
                present_fields(&context)
            } else {
                Vec::new()
            };
            let result = futures::executor::block_on(self.engine.evaluate(&rule.key, context))
                .map_err(|error| Error::Evaluation {
                    key: rule.key.clone(),
                    reason: error.to_string(),
                })?
                .result;
            if let (Variable::Object(fields), Variable::Object(returned)) = (&record, &result) {
                let returned = returned.borrow();
                let mut fields = fields.borrow_mut();
                for removed in given.iter().filter(|key| !returned.contains_key(key)) {
                    fields.remove(removed);
                }
            }
            record = overlay(record, result);
        }
        Ok(record)
    }

    /// [`RuleSet::normalize`] for a caller that holds JSON text. An empty rule
    /// set returns the record without converting its numbers.
    pub fn normalize_json(&self, record_json: &str) -> Result<String, Error> {
        let record: serde_json::Value =
            serde_json::from_str(record_json).map_err(Error::InvalidContext)?;
        let normalized = if self.is_empty() {
            record
        } else {
            self.normalize(record_from_json(record))?.to_value()
        };
        serde_json::to_string(&normalized).map_err(Error::Encode)
    }
}

/// A number from a JSON record, kept as written until a rule result replaces
/// it. Rules evaluate its decimal value instead.
struct JsonNumber(serde_json::Number);

impl JsonNumber {
    /// `null` when Zen's decimal cannot hold the number.
    fn for_rule(&self) -> Variable {
        Variable::from(serde_json::Value::Number(self.0.clone()))
    }
}

impl fmt::Display for JsonNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl DynamicVariable for JsonNumber {
    fn type_name(&self) -> &'static str {
        "number"
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn to_value(&self) -> serde_json::Value {
        serde_json::Value::Number(self.0.clone())
    }
}

fn record_from_json(value: serde_json::Value) -> Variable {
    use serde_json::Value;
    match value {
        Value::Number(number) => Variable::Dynamic(Rc::new(JsonNumber(number))),
        Value::Array(items) => {
            Variable::from_array(items.into_iter().map(record_from_json).collect())
        }
        Value::Object(fields) => Variable::from_object(
            fields
                .into_iter()
                .map(|(key, value)| (Variable::key(&key), record_from_json(value)))
                .collect(),
        ),
        scalar => Variable::from(scalar),
    }
}

/// The context one rule evaluates. A rule may write into its context, so it
/// gets its own containers and the record changes only through [`overlay`];
/// strings are still shared.
fn rule_context(record: &Variable) -> Variable {
    match record {
        Variable::Array(items) => {
            Variable::from_array(items.borrow().iter().map(rule_context).collect())
        }
        Variable::Object(fields) => Variable::from_object(
            fields
                .borrow()
                .iter()
                .map(|(key, value)| (key.clone(), rule_context(value)))
                .collect(),
        ),
        Variable::Dynamic(value) => match value.as_any().downcast_ref::<JsonNumber>() {
            Some(number) => number.for_rule(),
            None => record.shallow_clone(),
        },
        other => other.shallow_clone(),
    }
}

/// The top-level fields a rule was given with a value. Zen drops a `null` field
/// from every result, so a missing one says nothing about the rule.
fn present_fields(context: &Variable) -> Vec<Symbol> {
    let Variable::Object(fields) = context else {
        return Vec::new();
    };
    fields
        .borrow()
        .iter()
        .filter(|(_, value)| !matches!(value, Variable::Null))
        .map(|(key, _)| key.clone())
        .collect()
}

/// Lays a rule result over the record it was computed from.
///
/// Containers taken from the result are copied, so a result that names one
/// object under two fields cannot make a later overlay change both.
fn overlay(record: Variable, result: Variable) -> Variable {
    match (record, result) {
        (Variable::Object(fields), Variable::Object(changes)) => {
            for (key, change) in changes.borrow().iter() {
                let existing = fields.borrow().get(key).map(Variable::shallow_clone);
                let merged = match existing {
                    Some(existing) => overlay(existing, change.shallow_clone()),
                    None => change.deep_clone(),
                };
                fields.borrow_mut().insert(key.clone(), merged);
            }
            Variable::Object(fields)
        }
        (_, result) => result.deep_clone(),
    }
}

#[cfg(test)]
mod tests;
