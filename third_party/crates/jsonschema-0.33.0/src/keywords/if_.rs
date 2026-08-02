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

pub(crate) struct IfThenValidator {
    schema: SchemaNode,
    then_schema: SchemaNode,
}

impl IfThenValidator {
    #[inline]
    pub(crate) fn compile<'a>(
        ctx: &compiler::Context,
        schema: &'a Value,
        then_schema: &'a Value,
    ) -> CompilationResult<'a> {
        Ok(Box::new(IfThenValidator {
            schema: {
                let ctx = ctx.new_at_location("if");
                compiler::compile(&ctx, ctx.as_resource_ref(schema))?
            },
            then_schema: {
                let ctx = ctx.new_at_location("then");
                compiler::compile(&ctx, ctx.as_resource_ref(then_schema))?
            },
        }))
    }
}

impl Validate for IfThenValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if self.schema.is_valid(instance) {
            let errors: Vec<_> = self.then_schema.iter_errors(instance, location).collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if self.schema.is_valid(instance) {
            self.then_schema.is_valid(instance)
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.schema.is_valid(instance) {
            self.then_schema.validate(instance, location)
        } else {
            Ok(())
        }
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        let mut if_result = self.schema.apply_rooted(instance, location);
        if if_result.is_valid() {
            let then_result = self.then_schema.apply_rooted(instance, location);
            if_result += then_result;
            if_result.into()
        } else {
            PartialApplication::valid_empty()
        }
    }
}

pub(crate) struct IfElseValidator {
    schema: SchemaNode,
    else_schema: SchemaNode,
}

impl IfElseValidator {
    #[inline]
    pub(crate) fn compile<'a>(
        ctx: &compiler::Context,
        schema: &'a Value,
        else_schema: &'a Value,
    ) -> CompilationResult<'a> {
        Ok(Box::new(IfElseValidator {
            schema: {
                let ctx = ctx.new_at_location("if");
                compiler::compile(&ctx, ctx.as_resource_ref(schema))?
            },
            else_schema: {
                let ctx = ctx.new_at_location("else");
                compiler::compile(&ctx, ctx.as_resource_ref(else_schema))?
            },
        }))
    }
}

impl Validate for IfElseValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if self.schema.is_valid(instance) {
            no_error()
        } else {
            let errors: Vec<_> = self.else_schema.iter_errors(instance, location).collect();
            Box::new(errors.into_iter())
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if self.schema.is_valid(instance) {
            true
        } else {
            self.else_schema.is_valid(instance)
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.schema.is_valid(instance) {
            Ok(())
        } else {
            self.else_schema.validate(instance, location)
        }
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        let if_result = self.schema.apply_rooted(instance, location);
        if if_result.is_valid() {
            if_result.into()
        } else {
            self.else_schema.apply_rooted(instance, location).into()
        }
    }
}

pub(crate) struct IfThenElseValidator {
    schema: SchemaNode,
    then_schema: SchemaNode,
    else_schema: SchemaNode,
}

impl IfThenElseValidator {
    #[inline]
    pub(crate) fn compile<'a>(
        ctx: &compiler::Context,
        schema: &'a Value,
        then_schema: &'a Value,
        else_schema: &'a Value,
    ) -> CompilationResult<'a> {
        Ok(Box::new(IfThenElseValidator {
            schema: {
                let ctx = ctx.new_at_location("if");
                compiler::compile(&ctx, ctx.as_resource_ref(schema))?
            },
            then_schema: {
                let ctx = ctx.new_at_location("then");
                compiler::compile(&ctx, ctx.as_resource_ref(then_schema))?
            },
            else_schema: {
                let ctx = ctx.new_at_location("else");
                compiler::compile(&ctx, ctx.as_resource_ref(else_schema))?
            },
        }))
    }
}

impl Validate for IfThenElseValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if self.schema.is_valid(instance) {
            let errors: Vec<_> = self.then_schema.iter_errors(instance, location).collect();
            Box::new(errors.into_iter())
        } else {
            let errors: Vec<_> = self.else_schema.iter_errors(instance, location).collect();
            Box::new(errors.into_iter())
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if self.schema.is_valid(instance) {
            self.then_schema.is_valid(instance)
        } else {
            self.else_schema.is_valid(instance)
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.schema.is_valid(instance) {
            self.then_schema.validate(instance, location)
        } else {
            self.else_schema.validate(instance, location)
        }
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        let mut if_result = self.schema.apply_rooted(instance, location);
        if if_result.is_valid() {
            if_result += self.then_schema.apply_rooted(instance, location);
            if_result.into()
        } else {
            self.else_schema.apply_rooted(instance, location).into()
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    parent: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    let then = parent.get("then");
    let else_ = parent.get("else");
    match (then, else_) {
        (Some(then_schema), Some(else_schema)) => Some(IfThenElseValidator::compile(
            ctx,
            schema,
            then_schema,
            else_schema,
        )),
        (None, Some(else_schema)) => Some(IfElseValidator::compile(ctx, schema, else_schema)),
        (Some(then_schema), None) => Some(IfThenValidator::compile(ctx, schema, then_schema)),
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"if": {"minimum": 0}, "else": {"multipleOf": 2}}), &json!(-1), "/else/multipleOf")]
    #[test_case(&json!({"if": {"minimum": 0}, "then": {"multipleOf": 2}}), &json!(3), "/then/multipleOf")]
    #[test_case(&json!({"if": {"minimum": 0}, "then": {"multipleOf": 2}, "else": {"multipleOf": 2}}), &json!(-1), "/else/multipleOf")]
    #[test_case(&json!({"if": {"minimum": 0}, "then": {"multipleOf": 2}, "else": {"multipleOf": 2}}), &json!(3), "/then/multipleOf")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
