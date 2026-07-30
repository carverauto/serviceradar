//! Implementation of json schema output formats specified in <https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.12.2>
//!
//! Currently the "basic" formats is supported. The main contribution of this module is [`Output::basic`].
//! See the documentation of that method for more information.

use std::{
    borrow::Cow,
    collections::VecDeque,
    fmt,
    iter::{FromIterator, Sum},
    ops::AddAssign,
};

use crate::{paths::Location, validator::PartialApplication, ValidationError};
use ahash::AHashMap;
use referencing::Uri;
use serde::ser::SerializeMap;

use crate::{node::SchemaNode, paths::LazyLocation, Validator};

/// The output format resulting from the application of a schema.
///
/// This can be converted into various representations based on the definitions in
/// <https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.12.2>
///
/// Currently only the "flag" and "basic" output formats are supported
#[derive(Debug, Clone)]
pub struct Output<'a, 'b> {
    schema: &'a Validator,
    root_node: &'a SchemaNode,
    instance: &'b serde_json::Value,
}

impl<'a> Output<'a, '_> {
    pub(crate) const fn new<'c, 'd>(
        schema: &'c Validator,
        root_node: &'c SchemaNode,
        instance: &'d serde_json::Value,
    ) -> Output<'c, 'd> {
        Output {
            schema,
            root_node,
            instance,
        }
    }

    /// Indicates whether the schema was valid, corresponds to the "flag" output
    /// format
    #[must_use]
    pub fn flag(&self) -> bool {
        self.schema.is_valid(self.instance)
    }

    /// Output a list of errors and annotations for each element in the schema
    /// according to the basic output format. [`BasicOutput`] implements
    /// `serde::Serialize` in a manner which conforms to the json core spec so
    /// one way to use this is to serialize the `BasicOutput` and examine the
    /// JSON which is produced. However, for rust programs this is not
    /// necessary. Instead you can match on the `BasicOutput` and examine the
    /// results. To use this API you'll need to understand a few things:
    ///
    /// Regardless of whether the the schema validation was successful or not
    /// the `BasicOutput` is a sequence of [`OutputUnit`]s. An `OutputUnit` is
    /// some metadata about where the output is coming from (where in the schema
    /// and where in the instance). The difference between the
    /// `BasicOutput::Valid` and `BasicOutput::Invalid` cases is the value which
    /// is associated with each `OutputUnit`. For `Valid` outputs the value is
    /// an annotation, whilst for `Invalid` outputs it's an [`ErrorDescription`]
    /// (a `String` really).
    ///
    /// # Examples
    ///
    /// ```rust
    /// # use jsonschema::BasicOutput;
    /// # use serde_json::json;
    /// # let schema = json!({
    /// #     "title": "string value",
    /// #     "type": "string"
    /// # });
    /// # let instance = json!("some string");
    /// # let validator = jsonschema::validator_for(&schema).expect("Invalid schema");
    /// let output = validator.apply(&instance).basic();
    /// match output {
    ///     BasicOutput::Valid(annotations) => {
    ///         for annotation in annotations {
    ///             println!(
    ///                 "Value: {} at path {}",
    ///                 annotation.value(),
    ///                 annotation.instance_location()
    ///             )
    ///         }
    ///     },
    ///     BasicOutput::Invalid(errors) => {
    ///         for error in errors {
    ///             println!(
    ///                 "Error: {} at path {}",
    ///                 error.error_description(),
    ///                 error.instance_location()
    ///             )
    ///         }
    ///     }
    /// }
    /// ```
    #[must_use]
    pub fn basic(&self) -> BasicOutput<'a> {
        self.root_node
            .apply_rooted(self.instance, &LazyLocation::new())
    }
}

/// The "basic" output format. See the documentation for [`Output::basic`] for
/// examples of how to use this.
#[derive(Debug, PartialEq)]
pub enum BasicOutput<'a> {
    /// The schema was valid, collected annotations can be examined
    Valid(VecDeque<OutputUnit<Annotations<'a>>>),
    /// The schema was invalid
    Invalid(VecDeque<OutputUnit<ErrorDescription>>),
}

impl BasicOutput<'_> {
    /// A shortcut to check whether the output represents passed validation.
    #[must_use]
    pub const fn is_valid(&self) -> bool {
        match self {
            BasicOutput::Valid(..) => true,
            BasicOutput::Invalid(..) => false,
        }
    }
}

impl<'a> From<OutputUnit<Annotations<'a>>> for BasicOutput<'a> {
    fn from(unit: OutputUnit<Annotations<'a>>) -> Self {
        let mut units = VecDeque::new();
        units.push_front(unit);
        BasicOutput::Valid(units)
    }
}

impl AddAssign for BasicOutput<'_> {
    fn add_assign(&mut self, rhs: Self) {
        match (&mut *self, rhs) {
            (BasicOutput::Valid(ref mut anns), BasicOutput::Valid(anns_rhs)) => {
                anns.extend(anns_rhs);
            }
            (BasicOutput::Valid(..), BasicOutput::Invalid(errors)) => {
                *self = BasicOutput::Invalid(errors);
            }
            (BasicOutput::Invalid(..), BasicOutput::Valid(..)) => {}
            (BasicOutput::Invalid(errors), BasicOutput::Invalid(errors_rhs)) => {
                errors.extend(errors_rhs);
            }
        }
    }
}

impl Sum for BasicOutput<'_> {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        let result = BasicOutput::Valid(VecDeque::new());
        iter.fold(result, |mut acc, elem| {
            acc += elem;
            acc
        })
    }
}

impl Default for BasicOutput<'_> {
    fn default() -> Self {
        BasicOutput::Valid(VecDeque::new())
    }
}

impl<'a> From<BasicOutput<'a>> for PartialApplication<'a> {
    fn from(output: BasicOutput<'a>) -> Self {
        match output {
            BasicOutput::Valid(anns) => PartialApplication::Valid {
                annotations: None,
                child_results: anns,
            },
            BasicOutput::Invalid(errors) => PartialApplication::Invalid {
                errors: Vec::new(),
                child_results: errors,
            },
        }
    }
}

impl<'a> FromIterator<BasicOutput<'a>> for PartialApplication<'a> {
    fn from_iter<T: IntoIterator<Item = BasicOutput<'a>>>(iter: T) -> Self {
        iter.into_iter().sum::<BasicOutput<'_>>().into()
    }
}

/// A reference to a place in a schema and a place in an instance along with some value associated to that place.
///
/// For annotations the value will be an [`Annotations`] and for errors it will be an
/// [`ErrorDescription`]. See the documentation for [`Output::basic`] for a
/// detailed example.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputUnit<T> {
    keyword_location: Location,
    instance_location: Location,
    absolute_keyword_location: Option<Uri<String>>,
    value: T,
}

impl<T> OutputUnit<T> {
    pub(crate) const fn annotations(
        keyword_location: Location,
        instance_location: Location,
        absolute_keyword_location: Option<Uri<String>>,
        annotations: Annotations<'_>,
    ) -> OutputUnit<Annotations<'_>> {
        OutputUnit {
            keyword_location,
            instance_location,
            absolute_keyword_location,
            value: annotations,
        }
    }

    pub(crate) const fn error(
        keyword_location: Location,
        instance_location: Location,
        absolute_keyword_location: Option<Uri<String>>,
        error: ErrorDescription,
    ) -> OutputUnit<ErrorDescription> {
        OutputUnit {
            keyword_location,
            instance_location,
            absolute_keyword_location,
            value: error,
        }
    }

    /// The location in the schema of the keyword
    pub const fn keyword_location(&self) -> &Location {
        &self.keyword_location
    }

    /// The absolute location in the schema of the keyword. This will be
    /// different to `keyword_location` if the schema is a resolved reference.
    pub fn absolute_keyword_location(&self) -> Option<Uri<&str>> {
        self.absolute_keyword_location
            .as_ref()
            .map(|uri| uri.borrow())
    }

    /// The location in the instance
    pub const fn instance_location(&self) -> &Location {
        &self.instance_location
    }
}

impl OutputUnit<Annotations<'_>> {
    /// The annotations found at this output unit
    #[must_use]
    pub fn value(&self) -> Cow<'_, serde_json::Value> {
        self.value.value()
    }
}

impl OutputUnit<ErrorDescription> {
    /// The error for this output unit
    #[must_use]
    pub const fn error_description(&self) -> &ErrorDescription {
        &self.value
    }
}

/// Annotations associated with an output unit.
#[derive(serde::Serialize, Debug, Clone, PartialEq)]
pub struct Annotations<'a>(AnnotationsInner<'a>);

impl<'a> Annotations<'a> {
    /// The `serde_json::Value` of the annotation
    #[must_use]
    pub fn value(&'a self) -> Cow<'a, serde_json::Value> {
        match &self.0 {
            AnnotationsInner::Value(v) => Cow::Borrowed(v),
            AnnotationsInner::ValueRef(v) => Cow::Borrowed(v),
            AnnotationsInner::UnmatchedKeywords(kvs) => {
                let value = serde_json::to_value(kvs)
                    .expect("&AHashMap<String, serde_json::Value> cannot fail serializing");
                Cow::Owned(value)
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum AnnotationsInner<'a> {
    UnmatchedKeywords(&'a AHashMap<String, serde_json::Value>),
    ValueRef(&'a serde_json::Value),
    Value(Box<serde_json::Value>),
}

impl<'a> From<&'a AHashMap<String, serde_json::Value>> for Annotations<'a> {
    fn from(anns: &'a AHashMap<String, serde_json::Value>) -> Self {
        Annotations(AnnotationsInner::UnmatchedKeywords(anns))
    }
}

impl<'a> From<&'a serde_json::Value> for Annotations<'a> {
    fn from(v: &'a serde_json::Value) -> Self {
        Annotations(AnnotationsInner::ValueRef(v))
    }
}

impl From<serde_json::Value> for Annotations<'_> {
    fn from(v: serde_json::Value) -> Self {
        Annotations(AnnotationsInner::Value(Box::new(v)))
    }
}

/// An error associated with an [`OutputUnit`]
#[derive(serde::Serialize, Debug, Clone, PartialEq, Eq)]
pub struct ErrorDescription(String);

impl ErrorDescription {
    /// Returns the inner [`String`] of the error description.
    #[inline]
    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for ErrorDescription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<ValidationError<'_>> for ErrorDescription {
    fn from(e: ValidationError<'_>) -> Self {
        ErrorDescription(e.to_string())
    }
}

impl<'a> From<&'a str> for ErrorDescription {
    fn from(s: &'a str) -> Self {
        ErrorDescription(s.to_string())
    }
}

impl serde::Serialize for BasicOutput<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map_ser = serializer.serialize_map(Some(2))?;
        match self {
            BasicOutput::Valid(outputs) => {
                map_ser.serialize_entry("valid", &true)?;
                map_ser.serialize_entry("annotations", outputs)?;
            }
            BasicOutput::Invalid(errors) => {
                map_ser.serialize_entry("valid", &false)?;
                map_ser.serialize_entry("errors", errors)?;
            }
        }
        map_ser.end()
    }
}

impl serde::Serialize for AnnotationsInner<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            Self::UnmatchedKeywords(kvs) => kvs.serialize(serializer),
            Self::Value(v) => v.serialize(serializer),
            Self::ValueRef(v) => v.serialize(serializer),
        }
    }
}

impl serde::Serialize for OutputUnit<Annotations<'_>> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map_ser = serializer.serialize_map(Some(4))?;
        map_ser.serialize_entry("keywordLocation", self.keyword_location.as_str())?;
        map_ser.serialize_entry("instanceLocation", self.instance_location.as_str())?;
        if let Some(absolute) = &self.absolute_keyword_location {
            map_ser.serialize_entry("absoluteKeywordLocation", &absolute)?;
        }
        map_ser.serialize_entry("annotations", &self.value)?;
        map_ser.end()
    }
}

impl serde::Serialize for OutputUnit<ErrorDescription> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map_ser = serializer.serialize_map(Some(4))?;
        map_ser.serialize_entry("keywordLocation", self.keyword_location.as_str())?;
        map_ser.serialize_entry("instanceLocation", self.instance_location.as_str())?;
        if let Some(absolute) = &self.absolute_keyword_location {
            map_ser.serialize_entry("absoluteKeywordLocation", &absolute)?;
        }
        map_ser.serialize_entry("error", &self.value)?;
        map_ser.end()
    }
}
