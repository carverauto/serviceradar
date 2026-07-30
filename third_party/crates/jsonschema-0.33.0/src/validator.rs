//! Building a JSON Schema validator.
//! The main idea is to create a tree from the input JSON Schema. This tree will contain
//! everything needed to perform such validation in runtime.
use crate::{
    error::{error, no_error, ErrorIterator},
    node::SchemaNode,
    output::{Annotations, ErrorDescription, Output, OutputUnit},
    paths::LazyLocation,
    Draft, ValidationError, ValidationOptions,
};
use serde_json::Value;
use std::{collections::VecDeque, sync::Arc};

/// The Validate trait represents a predicate over some JSON value. Some validators are very simple
/// predicates such as "a value which is a string", whereas others may be much more complex,
/// consisting of several other validators composed together in various ways.
///
/// Much of the time all an application cares about is whether the predicate returns true or false,
/// in that case the `is_valid` function is sufficient. Sometimes applications will want more
/// detail about why a schema has failed, in which case the `validate` method can be used to
/// iterate over the errors produced by this validator. Finally, applications may be interested in
/// annotations produced by schemas over valid results, in this case the `apply` method can be used
/// to obtain this information.
///
/// If you are implementing `Validate` it is often sufficient to implement `validate` and
/// `is_valid`. `apply` is only necessary for validators which compose other validators. See the
/// documentation for `apply` for more information.
pub(crate) trait Validate: Send + Sync {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        match self.validate(instance, location) {
            Ok(()) => no_error(),
            Err(err) => error(err),
        }
    }
    // The same as above, but does not construct ErrorIterator.
    // It is faster for cases when the result is not needed (like anyOf), since errors are
    // not constructed
    fn is_valid(&self, instance: &Value) -> bool;

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>>;

    /// `apply` applies this validator and any sub-validators it is composed of to the value in
    /// question and collects the resulting annotations or errors. Note that the result of `apply`
    /// is a `PartialApplication`.
    ///
    /// What does "partial" mean in this context? Each validator can produce annotations or errors
    /// in the case of successful or unsuccessful validation respectively. We're ultimately
    /// producing these errors and annotations to produce the "basic" output format as specified in
    /// the 2020-12 draft specification. In this format each annotation or error must include a
    /// json pointer to the keyword in the schema and to the property in the instance. However,
    /// most validators don't know where they are in the schema tree so we allow them to return the
    /// errors or annotations they produce directly and leave it up to the parent validator to fill
    /// in the path information. This means that only validators which are composed of other
    /// validators must implement `apply`, for validators on the leaves of the validator tree the
    /// default implementation which is defined in terms of `validate` will suffice.
    ///
    /// If you are writing a validator which is composed of other validators then your validator will
    /// need to store references to the `SchemaNode`s which contain those other validators.
    /// `SchemaNode` stores information about where it is in the schema tree and therefore provides an
    /// `apply_rooted` method which returns a full `BasicOutput`. `BasicOutput` implements `AddAssign`
    /// so a typical pattern is to compose results from sub validators using `+=` and then use the
    /// `From<BasicOutput> for PartialApplication` impl to convert the composed outputs into a
    /// `PartialApplication` to return. For example, here is the implementation of
    /// `IfThenValidator`
    ///
    /// ```rust,ignore
    /// // Note that self.schema is a `SchemaNode` and we use `apply_rooted` to return a `BasicOutput`
    /// let mut if_result = self.schema.apply_rooted(instance, instance_path);
    /// if if_result.is_valid() {
    ///     // here we use the `AddAssign` implementation to combine the results of subschemas
    ///     if_result += self
    ///         .then_schema
    ///         .apply_rooted(instance, instance_path);
    ///     // Here we use the `From<BasicOutput> for PartialApplication impl
    ///     if_result.into()
    /// } else {
    ///     self.else_schema
    ///         .apply_rooted(instance, instance_path)
    ///         .into()
    /// }
    /// ```
    ///
    /// `BasicOutput` also implements `Sum<BasicOutput>` and `FromIterator<BasicOutput<'a>> for PartialApplication<'a>`
    /// so you can use `sum()` and `collect()` in simple cases.
    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        let errors: Vec<ErrorDescription> = self
            .iter_errors(instance, location)
            .map(ErrorDescription::from)
            .collect();
        if errors.is_empty() {
            PartialApplication::valid_empty()
        } else {
            PartialApplication::invalid_empty(errors)
        }
    }
}

/// The result of applying a validator to an instance. As explained in the documentation for
/// `Validate::apply` this is a "partial" result because it does not include information about
/// where the error or annotation occurred.
#[derive(Clone, PartialEq)]
pub(crate) enum PartialApplication<'a> {
    Valid {
        /// Annotations produced by this validator
        annotations: Option<Annotations<'a>>,
        /// Any outputs produced by validators which are children of this validator
        child_results: VecDeque<OutputUnit<Annotations<'a>>>,
    },
    Invalid {
        /// Errors which caused this schema to be invalid
        errors: Vec<ErrorDescription>,
        /// Any error outputs produced by child validators of this validator
        child_results: VecDeque<OutputUnit<ErrorDescription>>,
    },
}

impl<'a> PartialApplication<'a> {
    /// Create an empty `PartialApplication` which is valid
    pub(crate) fn valid_empty() -> PartialApplication<'static> {
        PartialApplication::Valid {
            annotations: None,
            child_results: VecDeque::new(),
        }
    }

    /// Create an empty `PartialApplication` which is invalid
    pub(crate) fn invalid_empty(errors: Vec<ErrorDescription>) -> PartialApplication<'static> {
        PartialApplication::Invalid {
            errors,
            child_results: VecDeque::new(),
        }
    }

    /// Set the annotation that will be returned for the current validator. If this
    /// `PartialApplication` is invalid then this method does nothing
    pub(crate) fn annotate(&mut self, new_annotations: Annotations<'a>) {
        match self {
            Self::Valid { annotations, .. } => *annotations = Some(new_annotations),
            Self::Invalid { .. } => {}
        }
    }

    /// Set the error that will be returned for the current validator. If this
    /// `PartialApplication` is valid then this method converts this application into
    /// `PartialApplication::Invalid`
    pub(crate) fn mark_errored(&mut self, error: ErrorDescription) {
        match self {
            Self::Invalid { errors, .. } => errors.push(error),
            Self::Valid { .. } => {
                *self = Self::Invalid {
                    errors: vec![error],
                    child_results: VecDeque::new(),
                }
            }
        }
    }
}

/// A compiled JSON Schema validator.
///
/// This structure represents a JSON Schema that has been parsed and compiled into
/// an efficient internal representation for validation. It contains the root node
/// of the schema tree and the configuration options used during compilation.
#[derive(Debug)]
pub struct Validator {
    pub(crate) root: SchemaNode,
    pub(crate) config: Arc<ValidationOptions>,
}

impl Validator {
    /// Create a default [`ValidationOptions`] for configuring JSON Schema validation.
    ///
    /// Use this to set the draft version and other validation parameters.
    ///
    /// # Example
    ///
    /// ```rust
    /// # use jsonschema::Draft;
    /// # let schema = serde_json::json!({});
    /// let validator = jsonschema::options()
    ///     .with_draft(Draft::Draft7)
    ///     .build(&schema);
    /// ```
    #[must_use]
    pub fn options() -> ValidationOptions {
        ValidationOptions::default()
    }
    /// Create a default [`ValidationOptions`] configured for async validation.
    ///
    /// Use this to set the draft version and other validation parameters when working
    /// with schemas that require async reference resolution.
    ///
    /// # Example
    ///
    /// ```rust
    /// # use serde_json::json;
    /// # use jsonschema::Draft;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let schema = json!({
    ///     "$ref": "https://example.com/schema.json"
    /// });
    ///
    /// let validator = jsonschema::async_options()
    ///     .with_draft(Draft::Draft202012)
    ///     .build(&schema)
    ///     .await?;
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// For sync validation, use [`options`] instead.
    #[cfg(feature = "resolve-async")]
    #[must_use]
    pub fn async_options() -> ValidationOptions<Arc<dyn referencing::AsyncRetrieve>> {
        ValidationOptions::default()
    }
    /// Create a validator using the default options.
    pub fn new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        Self::options().build(schema)
    }
    /// Create a validator using the default async options.
    #[cfg(feature = "resolve-async")]
    pub async fn async_new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        Self::async_options().build(schema).await
    }
    /// Validate `instance` against `schema` and return the first error if any.
    #[inline]
    pub fn validate<'i>(&self, instance: &'i Value) -> Result<(), ValidationError<'i>> {
        self.root.validate(instance, &LazyLocation::new())
    }
    /// Run validation against `instance` and return an iterator over [`ValidationError`] in the error case.
    #[inline]
    #[must_use]
    pub fn iter_errors<'i>(&'i self, instance: &'i Value) -> ErrorIterator<'i> {
        self.root.iter_errors(instance, &LazyLocation::new())
    }
    /// Run validation against `instance` but return a boolean result instead of an iterator.
    /// It is useful for cases, where it is important to only know the fact if the data is valid or not.
    /// This approach is much faster, than [`Validator::validate`].
    #[must_use]
    #[inline]
    pub fn is_valid(&self, instance: &Value) -> bool {
        self.root.is_valid(instance)
    }
    /// Apply the schema and return an [`Output`]. No actual work is done at this point, the
    /// evaluation of the schema is deferred until a method is called on the `Output`. This is
    /// because different output formats will have different performance characteristics.
    ///
    /// # Examples
    ///
    /// "basic" output format
    ///
    /// ```rust
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({
    ///     "title": "string value",
    ///     "type": "string"
    /// });
    /// let instance = json!("some string");
    ///
    /// let validator = jsonschema::validator_for(&schema)
    ///     .expect("Invalid schema");
    ///
    /// let output = validator.apply(&instance).basic();
    /// assert_eq!(
    ///     serde_json::to_value(output)?,
    ///     json!({
    ///         "valid": true,
    ///         "annotations": [
    ///             {
    ///                 "keywordLocation": "",
    ///                 "instanceLocation": "",
    ///                 "annotations": {
    ///                     "title": "string value"
    ///                 }
    ///             }
    ///         ]
    ///     })
    /// );
    /// # Ok(())
    /// # }
    /// ```
    #[must_use]
    pub const fn apply<'a, 'b>(&'a self, instance: &'b Value) -> Output<'a, 'b> {
        Output::new(self, &self.root, instance)
    }

    /// The [`Draft`] which was used to build this validator.
    #[must_use]
    pub fn draft(&self) -> Draft {
        self.config.draft()
    }

    /// The [`ValidationOptions`] that were used to build this validator.
    #[must_use]
    pub fn config(&self) -> Arc<ValidationOptions> {
        Arc::clone(&self.config)
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        error::ValidationError,
        keywords::custom::Keyword,
        paths::{LazyLocation, Location},
        types::JsonType,
        Validator,
    };
    use fancy_regex::Regex;
    use num_cmp::NumCmp;
    use once_cell::sync::Lazy;
    use serde_json::{json, Map, Value};

    #[cfg(not(target_arch = "wasm32"))]
    fn load(path: &str, idx: usize) -> Value {
        use std::{fs::File, io::Read, path::Path};
        let path = Path::new(path);
        let mut file = File::open(path).unwrap();
        let mut content = String::new();
        file.read_to_string(&mut content).ok().unwrap();
        let data: Value = serde_json::from_str(&content).unwrap();
        let case = &data.as_array().unwrap()[idx];
        case.get("schema").unwrap().clone()
    }

    #[test]
    fn only_keyword() {
        // When only one keyword is specified
        let schema = json!({"type": "string"});
        let validator = crate::validator_for(&schema).unwrap();
        let value1 = json!("AB");
        let value2 = json!(1);
        // And only this validator
        assert_eq!(validator.root.validators().len(), 1);
        assert!(validator.validate(&value1).is_ok());
        assert!(validator.validate(&value2).is_err());
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn validate_ref() {
        let schema = load("tests/suite/tests/draft7/ref.json", 1);
        let value = json!({"bar": 3});
        let validator = crate::validator_for(&schema).unwrap();
        assert!(validator.validate(&value).is_ok());
        let value = json!({"bar": true});
        assert!(validator.validate(&value).is_err());
    }

    #[test]
    fn wrong_schema_type() {
        let schema = json!([1]);
        let validator = crate::validator_for(&schema);
        assert!(validator.is_err());
    }

    #[test]
    fn multiple_errors() {
        let schema = json!({"minProperties": 2, "propertyNames": {"minLength": 3}});
        let value = json!({"a": 3});
        let validator = crate::validator_for(&schema).unwrap();
        let errors: Vec<_> = validator.iter_errors(&value).collect();
        assert_eq!(errors.len(), 2);
        assert_eq!(
            errors[0].to_string(),
            r#"{"a":3} has less than 2 properties"#
        );
        assert_eq!(errors[1].to_string(), r#""a" is shorter than 3 characters"#);
    }

    #[test]
    fn custom_keyword_definition() {
        /// Define a custom validator that verifies the object's keys consist of
        /// only ASCII representable characters.
        /// NOTE: This could be done with `propertyNames` + `pattern` but will be slower due to
        /// regex usage.
        struct CustomObjectValidator;
        impl Keyword for CustomObjectValidator {
            fn validate<'i>(
                &self,
                instance: &'i Value,
                location: &LazyLocation,
            ) -> Result<(), ValidationError<'i>> {
                for key in instance.as_object().unwrap().keys() {
                    if !key.is_ascii() {
                        return Err(ValidationError::custom(
                            Location::new(),
                            location.into(),
                            instance,
                            "Key is not ASCII",
                        ));
                    }
                }
                Ok(())
            }

            fn is_valid(&self, instance: &Value) -> bool {
                for (key, _value) in instance.as_object().unwrap() {
                    if !key.is_ascii() {
                        return false;
                    }
                }
                true
            }
        }

        fn custom_object_type_factory<'a>(
            _: &'a Map<String, Value>,
            schema: &'a Value,
            path: Location,
        ) -> Result<Box<dyn Keyword>, ValidationError<'a>> {
            const EXPECTED: &str = "ascii-keys";
            if schema.as_str() == Some(EXPECTED) {
                Ok(Box::new(CustomObjectValidator))
            } else {
                Err(ValidationError::constant_string(
                    Location::new(),
                    path,
                    schema,
                    EXPECTED,
                ))
            }
        }

        // Define a JSON schema that enforces the top level object has ASCII keys and has at least 1 property
        let schema =
            json!({ "custom-object-type": "ascii-keys", "type": "object", "minProperties": 1 });
        let validator = crate::options()
            .with_keyword("custom-object-type", custom_object_type_factory)
            .build(&schema)
            .unwrap();

        // Verify schema validation detects object with too few properties
        let instance = json!({});
        assert!(validator.validate(&instance).is_err());
        assert!(!validator.is_valid(&instance));

        // Verify validator succeeds on a valid custom-object-type
        let instance = json!({ "a" : 1 });
        assert!(validator.validate(&instance).is_ok());
        assert!(validator.is_valid(&instance));

        // Verify validator detects invalid custom-object-type
        let instance = json!({ "å" : 1 });
        let error = validator.validate(&instance).expect_err("Should fail");
        assert_eq!(error.to_string(), "Key is not ASCII");
        assert!(!validator.is_valid(&instance));
    }

    #[test]
    fn custom_format_and_override_keyword() {
        /// Check that a string has some number of digits followed by a dot followed by exactly 2 digits.
        fn currency_format_checker(s: &str) -> bool {
            static CURRENCY_RE: Lazy<Regex> = Lazy::new(|| {
                Regex::new("^(0|([1-9]+[0-9]*))(\\.[0-9]{2})$").expect("Invalid regex")
            });
            CURRENCY_RE.is_match(s).expect("Invalid regex")
        }
        /// A custom keyword validator that overrides "minimum"
        /// so that "minimum" may apply to "currency"-formatted strings as well.
        struct CustomMinimumValidator {
            limit: f64,
            limit_val: Value,
            with_currency_format: bool,
            location: Location,
        }

        impl Keyword for CustomMinimumValidator {
            fn validate<'i>(
                &self,
                instance: &'i Value,
                location: &LazyLocation,
            ) -> Result<(), ValidationError<'i>> {
                if self.is_valid(instance) {
                    Ok(())
                } else {
                    Err(ValidationError::minimum(
                        self.location.clone(),
                        location.into(),
                        instance,
                        self.limit_val.clone(),
                    ))
                }
            }

            fn is_valid(&self, instance: &Value) -> bool {
                match instance {
                    // Numeric comparison should happen just like original behavior
                    Value::Number(instance) => {
                        if let Some(item) = instance.as_u64() {
                            !NumCmp::num_lt(item, self.limit)
                        } else if let Some(item) = instance.as_i64() {
                            !NumCmp::num_lt(item, self.limit)
                        } else {
                            let item = instance.as_f64().expect("Always valid");
                            !NumCmp::num_lt(item, self.limit)
                        }
                    }
                    // String comparison should cast currency-formatted
                    Value::String(instance) => {
                        if self.with_currency_format && currency_format_checker(instance) {
                            // all preconditions for minimum applying are met
                            let value = instance
                                .parse::<f64>()
                                .expect("format validated by regex checker");
                            !NumCmp::num_lt(value, self.limit)
                        } else {
                            true
                        }
                    }
                    // In all other cases, the "minimum" keyword should not apply
                    _ => true,
                }
            }
        }

        /// Build a validator that overrides the standard `minimum` keyword
        fn custom_minimum_factory<'a>(
            parent: &'a Map<String, Value>,
            schema: &'a Value,
            location: Location,
        ) -> Result<Box<dyn Keyword>, ValidationError<'a>> {
            let limit = if let Value::Number(limit) = schema {
                limit.as_f64().expect("Always valid")
            } else {
                return Err(ValidationError::single_type_error(
                    // There is no metaschema definition for a custom keyword, hence empty `schema` pointer
                    Location::new(),
                    location,
                    schema,
                    JsonType::Number,
                ));
            };
            let with_currency_format = parent
                .get("format")
                .is_some_and(|format| format == "currency");
            Ok(Box::new(CustomMinimumValidator {
                limit,
                limit_val: schema.clone(),
                with_currency_format,
                location,
            }))
        }

        // Schema includes both the custom format and the overridden keyword
        let schema = json!({ "minimum": 2, "type": "string", "format": "currency" });
        let validator = crate::options()
            .with_format("currency", currency_format_checker)
            .with_keyword("minimum", custom_minimum_factory)
            .with_keyword("minimum-2", custom_minimum_factory)
            .should_validate_formats(true)
            .build(&schema)
            .expect("Invalid schema");

        // Control: verify schema validation rejects non-string types
        let instance = json!(15);
        assert!(validator.validate(&instance).is_err());
        assert!(!validator.is_valid(&instance));

        // Control: verify validator rejects ill-formatted strings
        let instance = json!("not a currency");
        assert!(validator.validate(&instance).is_err());
        assert!(!validator.is_valid(&instance));

        // Verify validator allows properly formatted strings that conform to custom keyword
        let instance = json!("3.00");
        assert!(validator.validate(&instance).is_ok());
        assert!(validator.is_valid(&instance));

        // Verify validator rejects properly formatted strings that do not conform to custom keyword
        let instance = json!("1.99");
        assert!(validator.validate(&instance).is_err());
        assert!(!validator.is_valid(&instance));

        // Define another schema that applies "minimum" to an integer to ensure original behavior
        let schema = json!({ "minimum": 2, "type": "integer" });
        let validator = crate::options()
            .with_format("currency", currency_format_checker)
            .with_keyword("minimum", custom_minimum_factory)
            .build(&schema)
            .expect("Invalid schema");

        // Verify schema allows integers greater than 2
        let instance = json!(3);
        assert!(validator.validate(&instance).is_ok());
        assert!(validator.is_valid(&instance));

        // Verify schema rejects integers less than 2
        let instance = json!(1);
        assert!(validator.validate(&instance).is_err());
        assert!(!validator.is_valid(&instance));

        // Invalid `minimum` value
        let schema = json!({ "minimum": "foo" });
        let error = crate::options()
            .with_keyword("minimum", custom_minimum_factory)
            .build(&schema)
            .expect_err("Should fail");
        assert_eq!(error.to_string(), "\"foo\" is not of type \"number\"");
    }

    #[test]
    fn test_validator_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Validator>();
    }
}
