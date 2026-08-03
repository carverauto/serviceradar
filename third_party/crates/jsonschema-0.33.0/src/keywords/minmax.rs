use crate::{
    compiler,
    error::ValidationError,
    ext::numeric,
    keywords::CompilationResult,
    paths::{LazyLocation, Location},
    types::JsonType,
    validator::Validate,
};
use num_cmp::NumCmp;
use serde_json::{Map, Value};

macro_rules! define_numeric_keywords {
    ($($struct_name:ident => $fn_name:path => $error_fn_name:ident),* $(,)?) => {
        $(
            #[derive(Debug, Clone, PartialEq)]
            pub(crate) struct $struct_name<T> {
                pub(super) limit: T,
                limit_val: Value,
                location: Location,
            }

            impl<T> From<(T, Value, Location)> for $struct_name<T> {
                fn from((limit, limit_val, location): (T, Value, Location)) -> Self {
                    Self { limit, limit_val, location }
                }
            }

            impl<T> Validate for $struct_name<T>
            where
                T: Copy + Send + Sync,
                u64: NumCmp<T>,
                i64: NumCmp<T>,
                f64: NumCmp<T>,
            {
                fn validate<'i>(
                    &self,
                    instance: &'i Value,
                    location: &LazyLocation,
                ) -> Result<(), ValidationError<'i>> {
                    if self.is_valid(instance) {
                        Ok(())
                    } else {
                        Err(ValidationError::$error_fn_name(
                            self.location.clone(),
                            location.into(),
                            instance,
                            self.limit_val.clone(),
                        ))
                    }
                }

                fn is_valid(&self, instance: &Value) -> bool {
                    if let Value::Number(item) = instance {
                        $fn_name(item, self.limit)
                    } else {
                        true
                    }
                }
            }
        )*
    };
}

define_numeric_keywords!(
    Minimum => numeric::ge => minimum,
    Maximum => numeric::le => maximum,
    ExclusiveMinimum => numeric::gt => exclusive_minimum,
    ExclusiveMaximum => numeric::lt => exclusive_maximum,
);

#[inline]
fn create_validator<T, V>(
    ctx: &compiler::Context,
    keyword: &str,
    limit: T,
    schema: &Value,
) -> CompilationResult<'static>
where
    V: From<(T, Value, Location)> + Validate + 'static,
{
    let location = ctx.location().join(keyword);
    Ok(Box::new(V::from((limit, schema.clone(), location))))
}

fn number_type_error<'a>(ctx: &compiler::Context, schema: &'a Value) -> CompilationResult<'a> {
    Err(ValidationError::single_type_error(
        Location::new(),
        ctx.location().clone(),
        schema,
        JsonType::Number,
    ))
}

macro_rules! create_numeric_validator {
    ($validator_type:ident, $ctx:expr, $keyword:expr, $limit:expr, $schema:expr) => {
        if let Some(limit) = $limit.as_u64() {
            Some(create_validator::<_, $validator_type<u64>>(
                $ctx, $keyword, limit, $schema,
            ))
        } else if let Some(limit) = $limit.as_i64() {
            Some(create_validator::<_, $validator_type<i64>>(
                $ctx, $keyword, limit, $schema,
            ))
        } else {
            let limit = $limit.as_f64().expect("Always valid");
            Some(create_validator::<_, $validator_type<f64>>(
                $ctx, $keyword, limit, $schema,
            ))
        }
    };
}

#[inline]
pub(crate) fn compile_minimum<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match schema {
        Value::Number(limit) => create_numeric_validator!(Minimum, ctx, "minimum", limit, schema),
        _ => Some(number_type_error(ctx, schema)),
    }
}

#[inline]
pub(crate) fn compile_maximum<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match schema {
        Value::Number(limit) => create_numeric_validator!(Maximum, ctx, "maximum", limit, schema),
        _ => Some(number_type_error(ctx, schema)),
    }
}

#[inline]
pub(crate) fn compile_exclusive_minimum<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match schema {
        Value::Number(limit) => {
            create_numeric_validator!(ExclusiveMinimum, ctx, "exclusiveMinimum", limit, schema)
        }
        _ => Some(number_type_error(ctx, schema)),
    }
}

#[inline]
pub(crate) fn compile_exclusive_maximum<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match schema {
        Value::Number(limit) => {
            create_numeric_validator!(ExclusiveMaximum, ctx, "exclusiveMaximum", limit, schema)
        }
        _ => Some(number_type_error(ctx, schema)),
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"minimum": 1_u64 << 54}), &json!((1_u64 << 54) - 1))]
    #[test_case(&json!({"minimum": 1_i64 << 54}), &json!((1_i64 << 54) - 1))]
    #[test_case(&json!({"maximum": 1_u64 << 54}), &json!((1_u64 << 54) + 1))]
    #[test_case(&json!({"maximum": 1_i64 << 54}), &json!((1_i64 << 54) + 1))]
    #[test_case(&json!({"exclusiveMinimum": 1_u64 << 54}), &json!(1_u64 << 54))]
    #[test_case(&json!({"exclusiveMinimum": 1_i64 << 54}), &json!(1_i64 << 54))]
    #[test_case(&json!({"exclusiveMinimum": 1_u64 << 54}), &json!((1_u64 << 54) - 1))]
    #[test_case(&json!({"exclusiveMinimum": 1_i64 << 54}), &json!((1_i64 << 54) - 1))]
    #[test_case(&json!({"exclusiveMaximum": 1_u64 << 54}), &json!(1_u64 << 54))]
    #[test_case(&json!({"exclusiveMaximum": 1_i64 << 54}), &json!(1_i64 << 54))]
    #[test_case(&json!({"exclusiveMaximum": 1_u64 << 54}), &json!((1_u64 << 54) + 1))]
    #[test_case(&json!({"exclusiveMaximum": 1_i64 << 54}), &json!((1_i64 << 54) + 1))]
    fn is_not_valid(schema: &Value, instance: &Value) {
        tests_util::is_not_valid(schema, instance);
    }

    #[test_case(&json!({"minimum": 5}), &json!(1), "/minimum")]
    #[test_case(&json!({"minimum": 6}), &json!(1), "/minimum")]
    #[test_case(&json!({"minimum": 7}), &json!(1), "/minimum")]
    #[test_case(&json!({"maximum": 5}), &json!(10), "/maximum")]
    #[test_case(&json!({"maximum": 6}), &json!(10), "/maximum")]
    #[test_case(&json!({"maximum": 7}), &json!(10), "/maximum")]
    #[test_case(&json!({"exclusiveMinimum": 5}), &json!(1), "/exclusiveMinimum")]
    #[test_case(&json!({"exclusiveMinimum": 6}), &json!(1), "/exclusiveMinimum")]
    #[test_case(&json!({"exclusiveMinimum": 7}), &json!(1), "/exclusiveMinimum")]
    #[test_case(&json!({"exclusiveMaximum": 5}), &json!(7), "/exclusiveMaximum")]
    #[test_case(&json!({"exclusiveMaximum": -1}), &json!(7), "/exclusiveMaximum")]
    #[test_case(&json!({"exclusiveMaximum": -1.0}), &json!(7), "/exclusiveMaximum")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
