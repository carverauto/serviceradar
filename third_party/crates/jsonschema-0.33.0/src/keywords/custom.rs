use crate::{
    paths::{LazyLocation, Location},
    validator::Validate,
    ValidationError,
};
use serde_json::{Map, Value};

pub(crate) struct CustomKeyword {
    inner: Box<dyn Keyword>,
}

impl CustomKeyword {
    pub(crate) fn new(inner: Box<dyn Keyword>) -> Self {
        Self { inner }
    }
}

impl Validate for CustomKeyword {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        self.inner.validate(instance, location)
    }

    fn is_valid(&self, instance: &Value) -> bool {
        self.inner.is_valid(instance)
    }
}

/// Trait that allows implementing custom validation for keywords.
pub trait Keyword: Send + Sync {
    /// Validate instance according to a custom specification.
    ///
    /// A custom keyword validator may be used when a validation that cannot be
    /// easily or efficiently expressed in JSON schema.
    ///
    /// The custom validation is applied in addition to the JSON schema validation.
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>>;
    /// Validate instance and return a boolean result.
    ///
    /// Could be potentilly faster than [`Keyword::validate`] method.
    fn is_valid(&self, instance: &Value) -> bool;
}

pub(crate) trait KeywordFactory: Send + Sync {
    fn init<'a>(
        &self,
        parent: &'a Map<String, Value>,
        schema: &'a Value,
        path: Location,
    ) -> Result<Box<dyn Keyword>, ValidationError<'a>>;
}

impl<F> KeywordFactory for F
where
    F: for<'a> Fn(
            &'a Map<String, Value>,
            &'a Value,
            Location,
        ) -> Result<Box<dyn Keyword>, ValidationError<'a>>
        + Send
        + Sync,
{
    fn init<'a>(
        &self,
        parent: &'a Map<String, Value>,
        schema: &'a Value,
        path: Location,
    ) -> Result<Box<dyn Keyword>, ValidationError<'a>> {
        self(parent, schema, path)
    }
}
