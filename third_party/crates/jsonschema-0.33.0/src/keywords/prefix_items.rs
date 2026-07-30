use crate::{
    compiler,
    error::{no_error, ErrorIterator, ValidationError},
    node::SchemaNode,
    paths::{LazyLocation, Location},
    types::JsonType,
    validator::{PartialApplication, Validate},
};
use serde_json::{Map, Value};

use super::CompilationResult;

pub(crate) struct PrefixItemsValidator {
    schemas: Vec<SchemaNode>,
}

impl PrefixItemsValidator {
    #[inline]
    pub(crate) fn compile<'a>(
        ctx: &compiler::Context,
        items: &'a [Value],
    ) -> CompilationResult<'a> {
        let ctx = ctx.new_at_location("prefixItems");
        let mut schemas = Vec::with_capacity(items.len());
        for (idx, item) in items.iter().enumerate() {
            let ctx = ctx.new_at_location(idx);
            let validators = compiler::compile(&ctx, ctx.as_resource_ref(item))?;
            schemas.push(validators);
        }
        Ok(Box::new(PrefixItemsValidator { schemas }))
    }
}

impl Validate for PrefixItemsValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Array(items) = instance {
            let errors: Vec<_> = self
                .schemas
                .iter()
                .zip(items.iter())
                .enumerate()
                .flat_map(|(idx, (n, i))| n.iter_errors(i, &location.push(idx)))
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Array(items) = instance {
            self.schemas
                .iter()
                .zip(items.iter())
                .all(|(n, i)| n.is_valid(i))
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Array(items) = instance {
            for (idx, (schema, item)) in self.schemas.iter().zip(items.iter()).enumerate() {
                schema.validate(item, &location.push(idx))?;
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Array(items) = instance {
            if !items.is_empty() {
                let validate_total = self.schemas.len();
                let mut results = Vec::with_capacity(validate_total);
                let mut max_index_applied = 0;
                for (idx, (schema_node, item)) in self.schemas.iter().zip(items.iter()).enumerate()
                {
                    let path = location.push(idx);
                    results.push(schema_node.apply_rooted(item, &path));
                    max_index_applied = idx;
                }
                // Per draft 2020-12 section https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.10.3.1.1
                // we must produce an annotation with the largest index of the underlying
                // array which the subschema was applied. The value MAY be a boolean true if
                // a subschema was applied to every index of the instance.
                let schema_was_applied: Value = if results.len() == items.len() {
                    true.into()
                } else {
                    max_index_applied.into()
                };
                let mut output: PartialApplication = results.into_iter().collect();
                output.annotate(schema_was_applied.into());
                return output;
            }
        }
        PartialApplication::valid_empty()
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    if let Value::Array(items) = schema {
        Some(PrefixItemsValidator::compile(ctx, items))
    } else {
        Some(Err(ValidationError::single_type_error(
            Location::new(),
            ctx.location().clone(),
            schema,
            JsonType::Array,
        )))
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"$schema": "https://json-schema.org/draft/2020-12/schema", "prefixItems": [{"type": "integer"}, {"maximum": 5}]}), &json!(["string"]), "/prefixItems/0/type")]
    #[test_case(&json!({"$schema": "https://json-schema.org/draft/2020-12/schema", "prefixItems": [{"type": "integer"}, {"maximum": 5}]}), &json!([42, 42]), "/prefixItems/1/maximum")]
    #[test_case(&json!({"$schema": "https://json-schema.org/draft/2020-12/schema", "prefixItems": [{"type": "integer"}, {"maximum": 5}], "items": {"type": "boolean"}}), &json!([42, 1, 42]), "/items/type")]
    #[test_case(&json!({"$schema": "https://json-schema.org/draft/2020-12/schema", "prefixItems": [{"type": "integer"}, {"maximum": 5}], "items": {"type": "boolean"}}), &json!([42, 42, true]), "/prefixItems/1/maximum")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }

    #[test_case{
        &json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema", 
            "type": "array",
            "prefixItems": [
                {
                    "type": "string"
                }
            ]
        }),
        &json!([]),
        &json!({
            "valid": true,
            "annotations": []
        }); "valid prefixItems empty array"
    }]
    #[test_case{
        &json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema", 
            "type": "array",
            "prefixItems": [
                {
                    "type": "string"
                },
                {
                    "type": "number"
                }
            ]
        }),
        &json!(["string", 1]),
        &json!({
            "valid": true,
            "annotations": [
                {
                    "keywordLocation": "/prefixItems",
                    "instanceLocation": "",
                    "annotations": true
                },
            ]
        }); "prefixItems valid items"
    }]
    #[test_case{
        &json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema", 
            "type": "array",
            "prefixItems": [
                {
                    "type": "string"
                }
            ]
        }),
        &json!(["string", 1]),
        &json!({
            "valid": true,
            "annotations": [
                {
                    "keywordLocation": "/prefixItems",
                    "instanceLocation": "",
                    "annotations": 0
                },
            ]
        }); "prefixItems valid mixed items"
    }]
    #[test_case{
        &json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema", 
            "type": "array",
            "items": {
                "type": "number",
                "annotation": "value"
            },
            "prefixItems": [
                {
                    "type": "string"
                },
                {
                    "type": "boolean"
                }
            ]
        }),
        &json!(["string", true, 2, 3]),
        &json!({
            "valid": true,
            "annotations": [
                {
                    "keywordLocation": "/prefixItems",
                    "instanceLocation": "",
                    "annotations": 1
                },
                {
                    "keywordLocation": "/items",
                    "instanceLocation": "",
                    "annotations": true
                },
                {
                    "annotations": {"annotation": "value" },
                    "instanceLocation": "/2",
                    "keywordLocation": "/items"
                },
                {
                    "annotations": {"annotation": "value" },
                    "instanceLocation": "/3",
                    "keywordLocation": "/items"
                }
            ]
        }); "valid prefixItems with mixed items"
    }]
    fn test_basic_output(schema: &Value, instance: &Value, expected_output: &Value) {
        let validator = crate::validator_for(schema).unwrap();
        let output = serde_json::to_value(validator.apply(instance).basic()).unwrap();
        assert_eq!(&output, expected_output);
    }
}
