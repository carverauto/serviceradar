use crate::{
    compiler,
    error::{no_error, ErrorIterator, ValidationError},
    keywords::CompilationResult,
    node::SchemaNode,
    paths::{LazyLocation, Location},
    validator::{PartialApplication, Validate},
};
use serde_json::{Map, Value};

pub(crate) struct PropertyNamesObjectValidator {
    node: SchemaNode,
}

impl PropertyNamesObjectValidator {
    #[inline]
    pub(crate) fn compile<'a>(ctx: &compiler::Context, schema: &'a Value) -> CompilationResult<'a> {
        let ctx = ctx.new_at_location("propertyNames");
        Ok(Box::new(PropertyNamesObjectValidator {
            node: compiler::compile(&ctx, ctx.as_resource_ref(schema))?,
        }))
    }
}

impl Validate for PropertyNamesObjectValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = &instance {
            let errors: Vec<_> = item
                .keys()
                .flat_map(move |key| {
                    let wrapper = Value::String(key.to_string());
                    let errors: Vec<_> = self
                        .node
                        .iter_errors(&wrapper, location)
                        .map(|error| {
                            ValidationError::property_names(
                                error.schema_path.clone(),
                                location.into(),
                                instance,
                                error.to_owned(),
                            )
                        })
                        .collect();
                    errors.into_iter()
                })
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = &instance {
            item.keys().all(move |key| {
                let wrapper = Value::String(key.to_string());
                self.node.is_valid(&wrapper)
            })
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = &instance {
            for key in item.keys() {
                let wrapper = Value::String(key.to_string());
                match self.node.validate(&wrapper, location) {
                    Ok(()) => {}
                    Err(error) => {
                        return Err(ValidationError::property_names(
                            error.schema_path.clone(),
                            location.into(),
                            instance,
                            error.to_owned(),
                        ))
                    }
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            item.keys()
                .map(|key| {
                    let wrapper = Value::String(key.to_string());
                    self.node.apply_rooted(&wrapper, location)
                })
                .collect()
        } else {
            PartialApplication::valid_empty()
        }
    }
}

pub(crate) struct PropertyNamesBooleanValidator {
    location: Location,
}

impl PropertyNamesBooleanValidator {
    #[inline]
    pub(crate) fn compile<'a>(ctx: &compiler::Context) -> CompilationResult<'a> {
        let location = ctx.location().join("propertyNames");
        Ok(Box::new(PropertyNamesBooleanValidator { location }))
    }
}

impl Validate for PropertyNamesBooleanValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            if !item.is_empty() {
                return false;
            }
        }
        true
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::false_schema(
                self.location.clone(),
                location.into(),
                instance,
            ))
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match schema {
        Value::Object(_) => Some(PropertyNamesObjectValidator::compile(ctx, schema)),
        Value::Bool(false) => Some(PropertyNamesBooleanValidator::compile(ctx)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"propertyNames": false}), &json!({"foo": 1}), "/propertyNames")]
    #[test_case(&json!({"propertyNames": {"minLength": 2}}), &json!({"f": 1}), "/propertyNames/minLength")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
