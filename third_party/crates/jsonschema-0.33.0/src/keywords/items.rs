use crate::{
    compiler,
    error::{no_error, ErrorIterator},
    keywords::CompilationResult,
    node::SchemaNode,
    paths::LazyLocation,
    validator::{PartialApplication, Validate},
    ValidationError,
};
use serde_json::{Map, Value};

pub(crate) struct ItemsArrayValidator {
    items: Vec<SchemaNode>,
}
impl ItemsArrayValidator {
    #[inline]
    pub(crate) fn compile<'a>(
        ctx: &compiler::Context,
        schemas: &'a [Value],
    ) -> CompilationResult<'a> {
        let kctx = ctx.new_at_location("items");
        let mut items = Vec::with_capacity(schemas.len());
        for (idx, item) in schemas.iter().enumerate() {
            let ictx = kctx.new_at_location(idx);
            let validators = compiler::compile(&ictx, ictx.as_resource_ref(item))?;
            items.push(validators);
        }
        Ok(Box::new(ItemsArrayValidator { items }))
    }
}
impl Validate for ItemsArrayValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Array(items) = instance {
            let errors: Vec<_> = items
                .iter()
                .zip(self.items.iter())
                .enumerate()
                .flat_map(move |(idx, (item, node))| node.iter_errors(item, &location.push(idx)))
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Array(items) = instance {
            items
                .iter()
                .zip(self.items.iter())
                .all(move |(item, node)| node.is_valid(item))
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
            for (idx, (item, node)) in items.iter().zip(self.items.iter()).enumerate() {
                node.validate(item, &location.push(idx))?;
            }
        }
        Ok(())
    }
}

pub(crate) struct ItemsObjectValidator {
    node: SchemaNode,
}

impl ItemsObjectValidator {
    #[inline]
    pub(crate) fn compile<'a>(ctx: &compiler::Context, schema: &'a Value) -> CompilationResult<'a> {
        let ctx = ctx.new_at_location("items");
        let node = compiler::compile(&ctx, ctx.as_resource_ref(schema))?;
        Ok(Box::new(ItemsObjectValidator { node }))
    }
}
impl Validate for ItemsObjectValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Array(items) = instance {
            let errors: Vec<_> = items
                .iter()
                .enumerate()
                .flat_map(move |(idx, item)| self.node.iter_errors(item, &location.push(idx)))
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Array(items) = instance {
            items.iter().all(|i| self.node.is_valid(i))
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
            for (idx, item) in items.iter().enumerate() {
                self.node.validate(item, &location.push(idx))?;
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Array(items) = instance {
            let mut results = Vec::with_capacity(items.len());
            for (idx, item) in items.iter().enumerate() {
                let path = location.push(idx);
                results.push(self.node.apply_rooted(item, &path));
            }
            let mut output: PartialApplication = results.into_iter().collect();
            // Per draft 2020-12 section https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.10.3.1.2
            // we must produce an annotation with a boolean value indicating whether the subschema
            // was applied to any positions in the underlying array. Since the struct
            // `ItemsObjectValidator` is not used when prefixItems is defined, this is true if
            // there are any items in the instance.
            let schema_was_applied = !items.is_empty();
            output.annotate(serde_json::json!(schema_was_applied).into());
            output
        } else {
            PartialApplication::valid_empty()
        }
    }
}

pub(crate) struct ItemsObjectSkipPrefixValidator {
    node: SchemaNode,
    skip_prefix: usize,
}

impl ItemsObjectSkipPrefixValidator {
    #[inline]
    pub(crate) fn compile<'a>(
        schema: &'a Value,
        skip_prefix: usize,
        ctx: &compiler::Context,
    ) -> CompilationResult<'a> {
        let ctx = ctx.new_at_location("items");
        let node = compiler::compile(&ctx, ctx.as_resource_ref(schema))?;
        Ok(Box::new(ItemsObjectSkipPrefixValidator {
            node,
            skip_prefix,
        }))
    }
}

impl Validate for ItemsObjectSkipPrefixValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Array(items) = instance {
            let errors: Vec<_> = items
                .iter()
                .skip(self.skip_prefix)
                .enumerate()
                .flat_map(move |(idx, item)| {
                    self.node
                        .iter_errors(item, &location.push(idx + self.skip_prefix))
                })
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Array(items) = instance {
            items
                .iter()
                .skip(self.skip_prefix)
                .all(|i| self.node.is_valid(i))
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
            for (idx, item) in items.iter().skip(self.skip_prefix).enumerate() {
                self.node
                    .validate(item, &location.push(idx + self.skip_prefix))?;
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Array(items) = instance {
            let mut results = Vec::with_capacity(items.len().saturating_sub(self.skip_prefix));
            for (idx, item) in items.iter().enumerate().skip(self.skip_prefix) {
                let path = location.push(idx);
                results.push(self.node.apply_rooted(item, &path));
            }
            let mut output: PartialApplication = results.into_iter().collect();
            // Per draft 2020-12 section https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.10.3.1.2
            // we must produce an annotation with a boolean value indicating whether the subschema
            // was applied to any positions in the underlying array.
            let schema_was_applied = items.len() > self.skip_prefix;
            output.annotate(serde_json::json!(schema_was_applied).into());
            output
        } else {
            PartialApplication::valid_empty()
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    parent: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match schema {
        Value::Array(items) => Some(ItemsArrayValidator::compile(ctx, items)),
        Value::Object(_) | Value::Bool(false) => {
            if let Some(Value::Array(prefix_items)) = parent.get("prefixItems") {
                return Some(ItemsObjectSkipPrefixValidator::compile(
                    schema,
                    prefix_items.len(),
                    ctx,
                ));
            }
            Some(ItemsObjectValidator::compile(ctx, schema))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"items": false}), &json!([1]), "/items")]
    #[test_case(&json!({"items": {"type": "string"}}), &json!([1]), "/items/type")]
    #[test_case(&json!({"prefixItems": [{"type": "string"}]}), &json!([1]), "/prefixItems/0/type")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
