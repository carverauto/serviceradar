use crate::{
    compiler,
    error::ValidationError,
    keywords::CompilationResult,
    node::SchemaNode,
    output::BasicOutput,
    paths::{LazyLocation, Location},
    types::JsonType,
    validator::{PartialApplication, Validate},
};
use serde_json::{Map, Value};

pub(crate) struct OneOfValidator {
    schemas: Vec<SchemaNode>,
    location: Location,
}

impl OneOfValidator {
    #[inline]
    pub(crate) fn compile<'a>(ctx: &compiler::Context, schema: &'a Value) -> CompilationResult<'a> {
        if let Value::Array(items) = schema {
            let ctx = ctx.new_at_location("oneOf");
            let mut schemas = Vec::with_capacity(items.len());
            for (idx, item) in items.iter().enumerate() {
                let ctx = ctx.new_at_location(idx);
                let node = compiler::compile(&ctx, ctx.as_resource_ref(item))?;
                schemas.push(node);
            }
            Ok(Box::new(OneOfValidator {
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

    fn get_first_valid(&self, instance: &Value) -> Option<usize> {
        let mut first_valid_idx = None;
        for (idx, node) in self.schemas.iter().enumerate() {
            if node.is_valid(instance) {
                first_valid_idx = Some(idx);
                break;
            }
        }
        first_valid_idx
    }

    #[allow(clippy::arithmetic_side_effects)]
    fn are_others_valid(&self, instance: &Value, idx: usize) -> bool {
        // `idx + 1` will not overflow, because the maximum possible value there is `usize::MAX - 1`
        // For example we have `usize::MAX` schemas and only the last one is valid, then
        // in `get_first_valid` we enumerate from `0`, and on the last index will be `usize::MAX - 1`
        self.schemas
            .iter()
            .skip(idx + 1)
            .any(|n| n.is_valid(instance))
    }
}

impl Validate for OneOfValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        let first_valid_idx = self.get_first_valid(instance);
        first_valid_idx.is_some_and(|idx| !self.are_others_valid(instance, idx))
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        let first_valid_idx = self.get_first_valid(instance);
        if let Some(idx) = first_valid_idx {
            if self.are_others_valid(instance, idx) {
                return Err(ValidationError::one_of_multiple_valid(
                    self.location.clone(),
                    location.into(),
                    instance,
                    self.schemas
                        .iter()
                        .map(|schema| schema.iter_errors(instance, location).collect())
                        .collect(),
                ));
            }
            Ok(())
        } else {
            Err(ValidationError::one_of_not_valid(
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
        let mut failures = Vec::new();
        let mut successes = Vec::new();
        for node in &self.schemas {
            match node.apply_rooted(instance, location) {
                output @ BasicOutput::Valid(..) => successes.push(output),
                output @ BasicOutput::Invalid(..) => failures.push(output),
            }
        }
        if successes.len() == 1 {
            let success = successes.remove(0);
            success.into()
        } else if successes.len() > 1 {
            PartialApplication::invalid_empty(vec!["more than one subschema succeeded".into()])
        } else if !failures.is_empty() {
            failures.into_iter().sum::<BasicOutput<'_>>().into()
        } else {
            unreachable!("compilation should fail for oneOf with no subschemas")
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    Some(OneOfValidator::compile(ctx, schema))
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"oneOf": [{"type": "string"}]}), &json!(0), "/oneOf")]
    #[test_case(&json!({"oneOf": [{"type": "string"}, {"maxLength": 3}]}), &json!(""), "/oneOf")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
