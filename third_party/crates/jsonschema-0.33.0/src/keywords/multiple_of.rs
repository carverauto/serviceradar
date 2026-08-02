use crate::{
    compiler,
    error::ValidationError,
    ext::numeric,
    keywords::CompilationResult,
    paths::{LazyLocation, Location},
    types::JsonType,
    validator::Validate,
};
use serde_json::{Map, Value};

pub(crate) struct MultipleOfFloatValidator {
    multiple_of: f64,
    location: Location,
}

impl MultipleOfFloatValidator {
    #[inline]
    pub(crate) fn compile<'a>(multiple_of: f64, location: Location) -> CompilationResult<'a> {
        Ok(Box::new(MultipleOfFloatValidator {
            multiple_of,
            location,
        }))
    }
}

impl Validate for MultipleOfFloatValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Number(item) = instance {
            numeric::is_multiple_of_float(item, self.multiple_of)
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if !self.is_valid(instance) {
            return Err(ValidationError::multiple_of(
                self.location.clone(),
                location.into(),
                instance,
                self.multiple_of,
            ));
        }
        Ok(())
    }
}

pub(crate) struct MultipleOfIntegerValidator {
    multiple_of: f64,
    location: Location,
}

impl MultipleOfIntegerValidator {
    #[inline]
    pub(crate) fn compile<'a>(multiple_of: f64, location: Location) -> CompilationResult<'a> {
        Ok(Box::new(MultipleOfIntegerValidator {
            multiple_of,
            location,
        }))
    }
}

impl Validate for MultipleOfIntegerValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Number(item) = instance {
            numeric::is_multiple_of_integer(item, self.multiple_of)
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if !self.is_valid(instance) {
            return Err(ValidationError::multiple_of(
                self.location.clone(),
                location.into(),
                instance,
                self.multiple_of,
            ));
        }
        Ok(())
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    if let Value::Number(multiple_of) = schema {
        let multiple_of = multiple_of.as_f64().expect("Always valid");
        let location = ctx.location().join("multipleOf");
        if multiple_of.fract() == 0. {
            Some(MultipleOfIntegerValidator::compile(multiple_of, location))
        } else {
            Some(MultipleOfFloatValidator::compile(multiple_of, location))
        }
    } else {
        Some(Err(ValidationError::single_type_error(
            Location::new(),
            ctx.location().clone(),
            schema,
            JsonType::Number,
        )))
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"multipleOf": 2}), &json!(4))]
    #[test_case(&json!({"multipleOf": 1.0}), &json!(4.0))]
    #[test_case(&json!({"multipleOf": 1.5}), &json!(3.0))]
    #[test_case(&json!({"multipleOf": 1.5}), &json!(4.5))]
    #[test_case(&json!({"multipleOf": 0.1}), &json!(12.2))]
    #[test_case(&json!({"multipleOf": 0.0001}), &json!(3.1254))]
    #[test_case(&json!({"multipleOf": 0.0001}), &json!(47.498))]
    #[test_case(&json!({"multipleOf": 0.1}), &json!(1.1))]
    #[test_case(&json!({"multipleOf": 0.1}), &json!(1.2))]
    #[test_case(&json!({"multipleOf": 0.1}), &json!(1.3))]
    #[test_case(&json!({"multipleOf": 0.02}), &json!(1.02))]
    #[test_case(&json!({"multipleOf": 1e-16}), &json!(1e-15))]
    fn multiple_of_is_valid(schema: &Value, instance: &Value) {
        tests_util::is_valid(schema, instance);
    }

    #[test_case(&json!({"multipleOf": 1.0}), &json!(4.5))]
    #[test_case(&json!({"multipleOf": 0.1}), &json!(4.55))]
    #[test_case(&json!({"multipleOf": 0.2}), &json!(4.5))]
    #[test_case(&json!({"multipleOf": 0.02}), &json!(1.01))]
    #[test_case(&json!({"multipleOf": 1.3}), &json!(1.3e-16))]
    fn multiple_of_is_not_valid(schema: &Value, instance: &Value) {
        tests_util::is_not_valid(schema, instance);
    }

    #[test_case(&json!({"multipleOf": 2}), &json!(3), "/multipleOf")]
    #[test_case(&json!({"multipleOf": 1.5}), &json!(5), "/multipleOf")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
