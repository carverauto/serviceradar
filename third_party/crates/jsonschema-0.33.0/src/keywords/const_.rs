use crate::{
    compiler, error::ValidationError, ext::cmp, keywords::CompilationResult, paths::Location,
    validator::Validate,
};
use serde_json::{Map, Number, Value};

use crate::paths::LazyLocation;

struct ConstArrayValidator {
    value: Vec<Value>,
    location: Location,
}
impl ConstArrayValidator {
    #[inline]
    pub(crate) fn compile(value: &[Value], location: Location) -> CompilationResult<'_> {
        Ok(Box::new(ConstArrayValidator {
            value: value.to_vec(),
            location,
        }))
    }
}
impl Validate for ConstArrayValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::constant_array(
                self.location.clone(),
                location.into(),
                instance,
                &self.value,
            ))
        }
    }

    #[inline]
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Array(instance_value) = instance {
            cmp::equal_arrays(&self.value, instance_value)
        } else {
            false
        }
    }
}

struct ConstBooleanValidator {
    value: bool,
    location: Location,
}
impl ConstBooleanValidator {
    #[inline]
    pub(crate) fn compile<'a>(value: bool, location: Location) -> CompilationResult<'a> {
        Ok(Box::new(ConstBooleanValidator { value, location }))
    }
}
impl Validate for ConstBooleanValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::constant_boolean(
                self.location.clone(),
                location.into(),
                instance,
                self.value,
            ))
        }
    }

    #[inline]
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Bool(instance_value) = instance {
            &self.value == instance_value
        } else {
            false
        }
    }
}

struct ConstNullValidator {
    location: Location,
}
impl ConstNullValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(ConstNullValidator { location }))
    }
}
impl Validate for ConstNullValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::constant_null(
                self.location.clone(),
                location.into(),
                instance,
            ))
        }
    }
    #[inline]
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_null()
    }
}

struct ConstNumberValidator {
    // This is saved in order to ensure that the error message is not altered by precision loss
    original_value: Number,
    value: f64,
    location: Location,
}

impl ConstNumberValidator {
    #[inline]
    pub(crate) fn compile(original_value: &Number, location: Location) -> CompilationResult<'_> {
        Ok(Box::new(ConstNumberValidator {
            original_value: original_value.clone(),
            value: original_value
                .as_f64()
                .expect("A JSON number will always be representable as f64"),
            location,
        }))
    }
}

impl Validate for ConstNumberValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::constant_number(
                self.location.clone(),
                location.into(),
                instance,
                &self.original_value,
            ))
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Number(item) = instance {
            (self.value - item.as_f64().expect("Always representable as f64")).abs() < f64::EPSILON
        } else {
            false
        }
    }
}

pub(crate) struct ConstObjectValidator {
    value: Map<String, Value>,
    location: Location,
}

impl ConstObjectValidator {
    #[inline]
    pub(crate) fn compile(value: &Map<String, Value>, location: Location) -> CompilationResult<'_> {
        Ok(Box::new(ConstObjectValidator {
            value: value.clone(),
            location,
        }))
    }
}

impl Validate for ConstObjectValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::constant_object(
                self.location.clone(),
                location.into(),
                instance,
                &self.value,
            ))
        }
    }
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            cmp::equal_objects(&self.value, item)
        } else {
            false
        }
    }
}

pub(crate) struct ConstStringValidator {
    value: String,
    location: Location,
}

impl ConstStringValidator {
    #[inline]
    pub(crate) fn compile(value: &str, location: Location) -> CompilationResult<'_> {
        Ok(Box::new(ConstStringValidator {
            value: value.to_string(),
            location,
        }))
    }
}

impl Validate for ConstStringValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::constant_string(
                self.location.clone(),
                location.into(),
                instance,
                &self.value,
            ))
        }
    }
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::String(item) = instance {
            &self.value == item
        } else {
            false
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    let location = ctx.location().join("const");
    match schema {
        Value::Array(items) => Some(ConstArrayValidator::compile(items, location)),
        Value::Bool(item) => Some(ConstBooleanValidator::compile(*item, location)),
        Value::Null => Some(ConstNullValidator::compile(location)),
        Value::Number(item) => Some(ConstNumberValidator::compile(item, location)),
        Value::Object(map) => Some(ConstObjectValidator::compile(map, location)),
        Value::String(string) => Some(ConstStringValidator::compile(string, location)),
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"const": 1}), &json!(2), "/const")]
    #[test_case(&json!({"const": null}), &json!(3), "/const")]
    #[test_case(&json!({"const": false}), &json!(4), "/const")]
    #[test_case(&json!({"const": []}), &json!(5), "/const")]
    #[test_case(&json!({"const": {}}), &json!(6), "/const")]
    #[test_case(&json!({"const": ""}), &json!(7), "/const")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
