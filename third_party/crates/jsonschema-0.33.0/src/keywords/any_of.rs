use crate::{
    compiler,
    error::{error, no_error, ErrorIterator, ValidationError},
    node::SchemaNode,
    paths::{LazyLocation, Location},
    types::JsonType,
    validator::{PartialApplication, Validate},
};
use serde_json::{Map, Value};

use super::CompilationResult;

pub(crate) struct AnyOfValidator {
    schemas: Vec<SchemaNode>,
    location: Location,
}

impl AnyOfValidator {
    #[inline]
    pub(crate) fn compile<'a>(ctx: &compiler::Context, schema: &'a Value) -> CompilationResult<'a> {
        if let Value::Array(items) = schema {
            let ctx = ctx.new_at_location("anyOf");
            let mut schemas = Vec::with_capacity(items.len());
            for (idx, item) in items.iter().enumerate() {
                let ctx = ctx.new_at_location(idx);
                let node = compiler::compile(&ctx, ctx.as_resource_ref(item))?;
                schemas.push(node);
            }
            Ok(Box::new(AnyOfValidator {
                schemas,
                location: ctx.location().clone(),
            }))
        } else {
            Err(ValidationError::single_type_error(
                Location::new(),
                ctx.location().clone(),
                schema,
                JsonType::Array,
            ))
        }
    }
}

impl Validate for AnyOfValidator {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if self.is_valid(instance) {
            no_error()
        } else {
            error(ValidationError::any_of(
                self.location.clone(),
                location.into(),
                instance,
                self.schemas
                    .iter()
                    .map(|schema| schema.iter_errors(instance, location).collect())
                    .collect(),
            ))
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        self.schemas.iter().any(|s| s.is_valid(instance))
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::any_of(
                self.location.clone(),
                location.into(),
                instance,
                self.schemas
                    .iter()
                    .map(|schema| schema.iter_errors(instance, location).collect())
                    .collect(),
            ))
        }
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        let mut successes = Vec::new();
        let mut failures = Vec::new();
        for node in &self.schemas {
            let result = node.apply_rooted(instance, location);
            if result.is_valid() {
                successes.push(result);
            } else {
                failures.push(result);
            }
        }
        if successes.is_empty() {
            failures.into_iter().collect()
        } else {
            successes.into_iter().collect()
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    Some(AnyOfValidator::compile(ctx, schema))
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"anyOf": [{"type": "string"}]}), &json!(1), "/anyOf")]
    #[test_case(&json!({"anyOf": [{"type": "integer"}, {"type": "string"}]}), &json!({}), "/anyOf")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
