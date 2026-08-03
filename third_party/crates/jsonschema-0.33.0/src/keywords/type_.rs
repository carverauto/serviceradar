use crate::{
    compiler,
    error::ValidationError,
    keywords::CompilationResult,
    paths::Location,
    types::{JsonType, JsonTypeSet},
    validator::Validate,
};
use serde_json::{json, Map, Number, Value};
use std::str::FromStr;

use crate::paths::LazyLocation;

pub(crate) struct MultipleTypesValidator {
    types: JsonTypeSet,
    location: Location,
}

impl MultipleTypesValidator {
    #[inline]
    pub(crate) fn compile(items: &[Value], location: Location) -> CompilationResult<'_> {
        let mut types = JsonTypeSet::empty();
        for item in items {
            match item {
                Value::String(string) => {
                    if let Ok(ty) = JsonType::from_str(string.as_str()) {
                        types = types.insert(ty);
                    } else {
                        return Err(ValidationError::enumeration(
                            Location::new(),
                            location,
                            item,
                            &json!([
                                "array", "boolean", "integer", "null", "number", "object", "string"
                            ]),
                        ));
                    }
                }
                _ => {
                    return Err(ValidationError::single_type_error(
                        location,
                        Location::new(),
                        item,
                        JsonType::String,
                    ))
                }
            }
        }
        Ok(Box::new(MultipleTypesValidator { types, location }))
    }
}

impl Validate for MultipleTypesValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        self.types.contains_value_type(instance)
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::multiple_type_error(
                self.location.clone(),
                location.into(),
                instance,
                self.types,
            ))
        }
    }
}

pub(crate) struct NullTypeValidator {
    location: Location,
}

impl NullTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(NullTypeValidator { location }))
    }
}

impl Validate for NullTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_null()
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::Null,
            ))
        }
    }
}

pub(crate) struct BooleanTypeValidator {
    location: Location,
}

impl BooleanTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(BooleanTypeValidator { location }))
    }
}

impl Validate for BooleanTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_boolean()
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::Boolean,
            ))
        }
    }
}

pub(crate) struct StringTypeValidator {
    location: Location,
}

impl StringTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(StringTypeValidator { location }))
    }
}

impl Validate for StringTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_string()
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::String,
            ))
        }
    }
}

pub(crate) struct ArrayTypeValidator {
    location: Location,
}

impl ArrayTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(ArrayTypeValidator { location }))
    }
}

impl Validate for ArrayTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_array()
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::Array,
            ))
        }
    }
}

pub(crate) struct ObjectTypeValidator {
    location: Location,
}

impl ObjectTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(ObjectTypeValidator { location }))
    }
}

impl Validate for ObjectTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_object()
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::Object,
            ))
        }
    }
}

pub(crate) struct NumberTypeValidator {
    location: Location,
}

impl NumberTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(NumberTypeValidator { location }))
    }
}

impl Validate for NumberTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        instance.is_number()
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::Number,
            ))
        }
    }
}

pub(crate) struct IntegerTypeValidator {
    location: Location,
}

impl IntegerTypeValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(IntegerTypeValidator { location }))
    }
}

impl Validate for IntegerTypeValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Number(num) = instance {
            is_integer(num)
        } else {
            false
        }
    }
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            Ok(())
        } else {
            Err(ValidationError::single_type_error(
                self.location.clone(),
                location.into(),
                instance,
                JsonType::Integer,
            ))
        }
    }
}

fn is_integer(num: &Number) -> bool {
    num.is_u64() || num.is_i64() || num.as_f64().expect("Always valid").fract() == 0.
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    _: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    let location = ctx.location().join("type");
    match schema {
        Value::String(item) => Some(compile_single_type(item.as_str(), location, schema)),
        Value::Array(items) => {
            if items.len() == 1 {
                let item = &items[0];
                if let Value::String(ty) = item {
                    Some(compile_single_type(ty.as_str(), location, item))
                } else {
                    Some(Err(ValidationError::single_type_error(
                        Location::new(),
                        location,
                        item,
                        JsonType::String,
                    )))
                }
            } else {
                Some(MultipleTypesValidator::compile(items, location))
            }
        }
        _ => Some(Err(ValidationError::multiple_type_error(
            Location::new(),
            ctx.location().clone(),
            schema,
            JsonTypeSet::empty()
                .insert(JsonType::String)
                .insert(JsonType::Array),
        ))),
    }
}

fn compile_single_type<'a>(
    item: &str,
    location: Location,
    instance: &'a Value,
) -> CompilationResult<'a> {
    match JsonType::from_str(item) {
        Ok(JsonType::Array) => ArrayTypeValidator::compile(location),
        Ok(JsonType::Boolean) => BooleanTypeValidator::compile(location),
        Ok(JsonType::Integer) => IntegerTypeValidator::compile(location),
        Ok(JsonType::Null) => NullTypeValidator::compile(location),
        Ok(JsonType::Number) => NumberTypeValidator::compile(location),
        Ok(JsonType::Object) => ObjectTypeValidator::compile(location),
        Ok(JsonType::String) => StringTypeValidator::compile(location),
        Err(()) => Err(ValidationError::custom(
            Location::new(),
            location,
            instance,
            "Unexpected type",
        )),
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"type": "array"}), &json!(1), "/type")]
    #[test_case(&json!({"type": "boolean"}), &json!(1), "/type")]
    #[test_case(&json!({"type": "integer"}), &json!("f"), "/type")]
    #[test_case(&json!({"type": "null"}), &json!(1), "/type")]
    #[test_case(&json!({"type": "number"}), &json!("f"), "/type")]
    #[test_case(&json!({"type": "object"}), &json!(1), "/type")]
    #[test_case(&json!({"type": "string"}), &json!(1), "/type")]
    #[test_case(&json!({"type": ["string", "object"]}), &json!(1), "/type")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
