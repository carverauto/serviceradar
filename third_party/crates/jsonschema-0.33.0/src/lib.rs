//! A high-performance JSON Schema validator for Rust.
//!
//! - 📚 Support for popular JSON Schema drafts
//! - 🔧 Custom keywords and format validators
//! - 🌐 Blocking & non-blocking remote reference fetching (network/file)
//! - 🎨 `Basic` output style as per JSON Schema spec
//! - ✨ Meta-schema validation for schema documents
//! - 🚀 WebAssembly support
//!
//! ## Supported drafts
//!
//! Compliance levels vary across drafts, with newer versions having some unimplemented keywords.
//!
//! - ![Draft 2020-12](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft2020-12.json)
//! - ![Draft 2019-09](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft2019-09.json)
//! - ![Draft 7](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft7.json)
//! - ![Draft 6](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft6.json)
//! - ![Draft 4](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft4.json)
//!
//! # Validation
//!
//! The `jsonschema` crate offers two main approaches to validation: one-off validation and reusable validators.
//! When external references are involved, the validator can be constructed using either blocking or non-blocking I/O.
//!
//!
//! For simple use cases where you need to validate an instance against a schema once, use [`is_valid`] or [`validate`] functions:
//!
//! ```rust
//! use serde_json::json;
//!
//! let schema = json!({"type": "string"});
//! let instance = json!("Hello, world!");
//!
//! assert!(jsonschema::is_valid(&schema, &instance));
//! assert!(jsonschema::validate(&schema, &instance).is_ok());
//! ```
//!
//! For better performance, especially when validating multiple instances against the same schema, build a validator once and reuse it:
//! If your schema contains external references, you can choose between blocking and non-blocking construction:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema = json!({"type": "string"});
//! // Blocking construction - will fetch external references synchronously
//! let validator = jsonschema::validator_for(&schema)?;
//! // Non-blocking construction - will fetch external references asynchronously
//! # #[cfg(feature = "resolve-async")]
//! # async fn async_example() -> Result<(), Box<dyn std::error::Error>> {
//! # let schema = json!({"type": "string"});
//! let validator = jsonschema::async_validator_for(&schema).await?;
//! # Ok(())
//! # }
//!
//!  // Once constructed, validation is always synchronous as it works with in-memory data
//! assert!(validator.is_valid(&json!("Hello, world!")));
//! assert!(!validator.is_valid(&json!(42)));
//! assert!(validator.validate(&json!(42)).is_err());
//!
//! // Iterate over all errors
//! let instance = json!(42);
//! for error in validator.iter_errors(&instance) {
//!     eprintln!("Error: {}", error);
//!     eprintln!("Location: {}", error.instance_path);
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ### Note on `format` keyword
//!
//! By default, format validation is draft‑dependent. To opt in for format checks, you can configure your validator like this:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! # use serde_json::json;
//! #
//! # let schema = json!({"type": "string"});
//! let validator = jsonschema::draft202012::options()
//!     .should_validate_formats(true)
//!     .build(&schema)?;
//! # Ok(())
//! # }
//! ```
//!
//! Once built, any `format` keywords in your schema will be actively validated according to the chosen draft.
//!
//! # Meta-Schema Validation
//!
//! The crate provides functionality to validate JSON Schema documents themselves against their meta-schemas.
//! This ensures your schema documents are valid according to the JSON Schema specification.
//!
//! ```rust
//! use serde_json::json;
//!
//! let schema = json!({
//!     "type": "object",
//!     "properties": {
//!         "name": {"type": "string"},
//!         "age": {"type": "integer", "minimum": 0}
//!     }
//! });
//!
//! // Validate schema with automatic draft detection
//! assert!(jsonschema::meta::is_valid(&schema));
//! assert!(jsonschema::meta::validate(&schema).is_ok());
//!
//! // Invalid schema example
//! let invalid_schema = json!({
//!     "type": "invalid_type",  // must be one of the valid JSON Schema types
//!     "minimum": "not_a_number"
//! });
//! assert!(!jsonschema::meta::is_valid(&invalid_schema));
//! assert!(jsonschema::meta::validate(&invalid_schema).is_err());
//! ```
//!
//! # Configuration
//!
//! `jsonschema` provides several ways to configure and use JSON Schema validation.
//!
//! ## Draft-specific Modules
//!
//! The library offers modules for specific JSON Schema draft versions:
//!
//! - [`draft4`]
//! - [`draft6`]
//! - [`draft7`]
//! - [`draft201909`]
//! - [`draft202012`]
//!
//! Each module provides:
//! - A `new` function to create a validator
//! - An `is_valid` function for validation with a boolean result
//! - An `validate` function for getting the first validation error
//! - An `options` function to create a draft-specific configuration builder
//! - A `meta` module for draft-specific meta-schema validation
//!
//! Here's how you can explicitly use a specific draft version:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema = json!({"type": "string"});
//!
//! // Instance validation
//! let validator = jsonschema::draft7::new(&schema)?;
//! assert!(validator.is_valid(&json!("Hello")));
//!
//! // Meta-schema validation
//! assert!(jsonschema::draft7::meta::is_valid(&schema));
//! # Ok(())
//! # }
//! ```
//!
//! You can also use the convenience [`is_valid`] and [`validate`] functions:
//!
//! ```rust
//! use serde_json::json;
//!
//! let schema = json!({"type": "number", "minimum": 0});
//! let instance = json!(42);
//!
//! assert!(jsonschema::draft202012::is_valid(&schema, &instance));
//! assert!(jsonschema::draft202012::validate(&schema, &instance).is_ok());
//! ```
//!
//! For more advanced configuration, you can use the draft-specific `options` function:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema = json!({"type": "string", "format": "ends-with-42"});
//! let validator = jsonschema::draft202012::options()
//!     .with_format("ends-with-42", |s| s.ends_with("42"))
//!     .should_validate_formats(true)
//!     .build(&schema)?;
//!
//! assert!(validator.is_valid(&json!("Hello 42")));
//! assert!(!validator.is_valid(&json!("No!")));
//! # Ok(())
//! # }
//! ```
//!
//! ## General Configuration
//!
//! For configuration options that are not draft-specific, `jsonschema` provides a builder via `jsonschema::options()`.
//!
//! Here's an example:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema = json!({"type": "string"});
//! let validator = jsonschema::options()
//!     // Add configuration options here
//!     .build(&schema)?;
//!
//! assert!(validator.is_valid(&json!("Hello")));
//! # Ok(())
//! # }
//! ```
//!
//! For a complete list of configuration options and their usage, please refer to the [`ValidationOptions`] struct.
//!
//! ## Automatic Draft Detection
//!
//! If you don't need to specify a particular draft version, you can use `jsonschema::validator_for`
//! which automatically detects the appropriate draft:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema = json!({"$schema": "http://json-schema.org/draft-07/schema#", "type": "string"});
//! let validator = jsonschema::validator_for(&schema)?;
//!
//! assert!(validator.is_valid(&json!("Hello")));
//! # Ok(())
//! # }
//! ```
//!
//! # External References
//!
//! By default, `jsonschema` resolves HTTP references using `reqwest` and file references from the local file system.
//! Both blocking and non-blocking retrieval is supported during validator construction. Note that the validation
//! itself is always synchronous as it operates on in-memory data only.
//!
//! ```rust
//! # async fn example() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema = json!({"$schema": "http://json-schema.org/draft-07/schema#", "type": "string"});
//!
//! // Building a validator with blocking retrieval (default)
//! let validator = jsonschema::validator_for(&schema)?;
//!
//! // Building a validator with non-blocking retrieval (requires `resolve-async` feature)
//! # #[cfg(feature = "resolve-async")]
//! let validator = jsonschema::async_validator_for(&schema).await?;
//!
//! // Validation is always synchronous
//! assert!(validator.is_valid(&json!("Hello")));
//! # Ok(())
//! # }
//! ```
//!
//! To enable HTTPS support, add the `rustls-tls` feature to `reqwest` in your `Cargo.toml`:
//!
//! ```toml
//! reqwest = { version = "*", features = ["rustls-tls"] }
//! ```
//!
//! You can disable the default behavior using crate features:
//!
//! - Disable HTTP resolving: `default-features = false, features = ["resolve-file"]`
//! - Disable file resolving: `default-features = false, features = ["resolve-http"]`
//! - Enable async resolution: `features = ["resolve-async"]`
//! - Disable all resolving: `default-features = false`
//!
//! ## Custom retrievers
//!
//! You can implement custom retrievers for both blocking and non-blocking retrieval:
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use std::{collections::HashMap, sync::Arc};
//! use jsonschema::{Retrieve, Uri};
//! use serde_json::{json, Value};
//!
//! struct InMemoryRetriever {
//!     schemas: HashMap<String, Value>,
//! }
//!
//! impl Retrieve for InMemoryRetriever {
//!
//!    fn retrieve(
//!        &self,
//!        uri: &Uri<String>,
//!    ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
//!         self.schemas
//!             .get(uri.as_str())
//!             .cloned()
//!             .ok_or_else(|| format!("Schema not found: {uri}").into())
//!     }
//! }
//!
//! let mut schemas = HashMap::new();
//! schemas.insert(
//!     "https://example.com/person.json".to_string(),
//!     json!({
//!         "type": "object",
//!         "properties": {
//!             "name": { "type": "string" },
//!             "age": { "type": "integer" }
//!         },
//!         "required": ["name", "age"]
//!     }),
//! );
//!
//! let retriever = InMemoryRetriever { schemas };
//!
//! let schema = json!({
//!     "$ref": "https://example.com/person.json"
//! });
//!
//! let validator = jsonschema::options()
//!     .with_retriever(retriever)
//!     .build(&schema)?;
//!
//! assert!(validator.is_valid(&json!({
//!     "name": "Alice",
//!     "age": 30
//! })));
//!
//! assert!(!validator.is_valid(&json!({
//!     "name": "Bob"
//! })));
//! #    Ok(())
//! # }
//! ```
//!
//! And non-blocking version with the `resolve-async` feature enabled:
//!
//! ```rust
//! # #[cfg(feature = "resolve-async")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error>> {
//! use jsonschema::{AsyncRetrieve, Registry, Resource, Uri};
//! use serde_json::{Value, json};
//!
//! struct HttpRetriever;
//!
//! #[async_trait::async_trait]
//! impl AsyncRetrieve for HttpRetriever {
//!     async fn retrieve(
//!         &self,
//!         uri: &Uri<String>,
//!     ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
//!         reqwest::get(uri.as_str())
//!             .await?
//!             .json()
//!             .await
//!             .map_err(Into::into)
//!     }
//! }
//!
//! // Then use it to build a validator
//! let validator = jsonschema::async_options()
//!     .with_retriever(HttpRetriever)
//!     .build(&json!({"$ref": "https://example.com/user.json"}))
//!     .await?;
//! # Ok(())
//! # }
//! ```
//!
//! # Output Styles
//!
//! `jsonschema` supports the `basic` output style as defined in JSON Schema Draft 2019-09.
//! This styles allow you to serialize validation results in a standardized format using `serde`.
//!
//! ```rust
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use serde_json::json;
//!
//! let schema_json = json!({
//!     "title": "string value",
//!     "type": "string"
//! });
//! let instance = json!("some string");
//! let validator = jsonschema::validator_for(&schema_json)?;
//!
//! let output = validator.apply(&instance).basic();
//!
//! assert_eq!(
//!     serde_json::to_value(output)?,
//!     json!({
//!         "valid": true,
//!         "annotations": [
//!             {
//!                 "keywordLocation": "",
//!                 "instanceLocation": "",
//!                 "annotations": {
//!                     "title": "string value"
//!                 }
//!             }
//!         ]
//!     })
//! );
//! #    Ok(())
//! # }
//! ```
//!
//! # Regular Expression Configuration
//!
//! The `jsonschema` crate allows configuring the regular expression engine used for validating
//! keywords like `pattern` or `patternProperties`.
//!
//! By default, the crate uses [`fancy-regex`](https://docs.rs/fancy-regex), which supports advanced
//! regular expression features such as lookaround and backreferences.
//!
//! The primary motivation for switching to the `regex` engine is security and performance:
//! it guarantees linear-time matching, preventing potential DoS attacks from malicious patterns
//! in user-provided schemas while offering better performance with a smaller feature set.
//!
//! You can configure the engine at **runtime** using the [`PatternOptions`] API:
//!
//! ### Example: Configure `fancy-regex` with Backtracking Limit
//!
//! ```rust
//! use serde_json::json;
//! use jsonschema::PatternOptions;
//!
//! let schema = json!({
//!     "type": "string",
//!     "pattern": "^(a+)+$"
//! });
//!
//! let validator = jsonschema::options()
//!     .with_pattern_options(
//!         PatternOptions::fancy_regex()
//!             .backtrack_limit(10_000)
//!     )
//!     .build(&schema)
//!     .expect("A valid schema");
//! ```
//!
//! ### Example: Use the `regex` Engine Instead
//!
//! ```rust
//! use serde_json::json;
//! use jsonschema::PatternOptions;
//!
//! let schema = json!({
//!     "type": "string",
//!     "pattern": "^a+$"
//! });
//!
//! let validator = jsonschema::options()
//!     .with_pattern_options(PatternOptions::regex())
//!     .build(&schema)
//!     .expect("A valid schema");
//! ```
//!
//! ### Notes
//!
//! - If neither engine is explicitly set, `fancy-regex` is used by default.
//! - Regular expressions that rely on advanced features like `(?<=...)` (lookbehind) or backreferences (`\1`) will fail with the `regex` engine.
//!
//! # Custom Keywords
//!
//! `jsonschema` allows you to extend its functionality by implementing custom validation logic through custom keywords.
//! This feature is particularly useful when you need to validate against domain-specific rules that aren't covered by the standard JSON Schema keywords.
//!
//! To implement a custom keyword, you need to:
//! 1. Create a struct that implements the [`Keyword`] trait
//! 2. Create a factory function or closure that produces instances of your custom keyword
//! 3. Register the custom keyword with the [`Validator`] instance using the [`ValidationOptions::with_keyword`] method
//!
//! Here's a complete example:
//!
//! ```rust
//! use jsonschema::{
//!     paths::{LazyLocation, Location},
//!     Keyword, ValidationError,
//! };
//! use serde_json::{json, Map, Value};
//! use std::iter::once;
//!
//! // Step 1: Implement the Keyword trait
//! struct EvenNumberValidator;
//!
//! impl Keyword for EvenNumberValidator {
//!     fn validate<'i>(
//!         &self,
//!         instance: &'i Value,
//!         location: &LazyLocation,
//!     ) -> Result<(), ValidationError<'i>> {
//!         if let Value::Number(n) = instance {
//!             if n.as_u64().map_or(false, |n| n % 2 == 0) {
//!                 Ok(())
//!             } else {
//!                 return Err(ValidationError::custom(
//!                     Location::new(),
//!                     location.into(),
//!                     instance,
//!                     "Number must be even",
//!                 ));
//!             }
//!         } else {
//!             Err(ValidationError::custom(
//!                 Location::new(),
//!                 location.into(),
//!                 instance,
//!                 "Value must be a number",
//!             ))
//!         }
//!     }
//!
//!     fn is_valid(&self, instance: &Value) -> bool {
//!         instance.as_u64().map_or(false, |n| n % 2 == 0)
//!     }
//! }
//!
//! // Step 2: Create a factory function
//! fn even_number_validator_factory<'a>(
//!     _parent: &'a Map<String, Value>,
//!     value: &'a Value,
//!     path: Location,
//! ) -> Result<Box<dyn Keyword>, ValidationError<'a>> {
//!     // You can use the `value` parameter to configure your validator if needed
//!     if value.as_bool() == Some(true) {
//!         Ok(Box::new(EvenNumberValidator))
//!     } else {
//!         Err(ValidationError::custom(
//!             Location::new(),
//!             path,
//!             value,
//!             "The 'even-number' keyword must be set to true",
//!         ))
//!     }
//! }
//!
//! // Step 3: Use the custom keyword
//! fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let schema = json!({"even-number": true, "type": "integer"});
//!     let validator = jsonschema::options()
//!         .with_keyword("even-number", even_number_validator_factory)
//!         .build(&schema)?;
//!
//!     assert!(validator.is_valid(&json!(2)));
//!     assert!(!validator.is_valid(&json!(3)));
//!     assert!(!validator.is_valid(&json!("not a number")));
//!
//!     Ok(())
//! }
//! ```
//!
//! In this example, we've created a custom `even-number` keyword that validates whether a number is even.
//! The `EvenNumberValidator` implements the actual validation logic, while the `even_number_validator_factory`
//! creates instances of the validator and allows for additional configuration based on the keyword's value in the schema.
//!
//! You can also use a closure instead of a factory function for simpler cases:
//!
//! ```rust
//! # use jsonschema::{
//! #     paths::LazyLocation,
//! #     Keyword, ValidationError,
//! # };
//! # use serde_json::{json, Map, Value};
//! # use std::iter::once;
//! #
//! # struct EvenNumberValidator;
//! #
//! # impl Keyword for EvenNumberValidator {
//! #     fn validate<'i>(
//! #         &self,
//! #         instance: &'i Value,
//! #         location: &LazyLocation,
//! #     ) -> Result<(), ValidationError<'i>> {
//! #         Ok(())
//! #     }
//! #
//! #     fn is_valid(&self, instance: &Value) -> bool {
//! #         true
//! #     }
//! # }
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let schema = json!({"even-number": true, "type": "integer"});
//! let validator = jsonschema::options()
//!     .with_keyword("even-number", |_, _, _| {
//!         Ok(Box::new(EvenNumberValidator))
//!     })
//!     .build(&schema)?;
//! # Ok(())
//! # }
//! ```
//!
//! # Custom Formats
//!
//! JSON Schema allows for format validation through the `format` keyword. While `jsonschema`
//! provides built-in validators for standard formats, you can also define custom format validators
//! for domain-specific string formats.
//!
//! To implement a custom format validator:
//!
//! 1. Define a function or a closure that takes a `&str` and returns a `bool`.
//! 2. Register the function with `jsonschema::options().with_format()`.
//!
//! ```rust
//! use serde_json::json;
//!
//! // Step 1: Define the custom format validator function
//! fn ends_with_42(s: &str) -> bool {
//!     s.ends_with("42!")
//! }
//!
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! // Step 2: Create a schema using the custom format
//! let schema = json!({
//!     "type": "string",
//!     "format": "ends-with-42"
//! });
//!
//! // Step 3: Build the validator with the custom format
//! let validator = jsonschema::options()
//!     .with_format("ends-with-42", ends_with_42)
//!     .with_format("ends-with-43", |s| s.ends_with("43!"))
//!     .should_validate_formats(true)
//!     .build(&schema)?;
//!
//! // Step 4: Validate instances
//! assert!(validator.is_valid(&json!("Hello42!")));
//! assert!(!validator.is_valid(&json!("Hello43!")));
//! assert!(!validator.is_valid(&json!(42))); // Not a string
//! #    Ok(())
//! # }
//! ```
//!
//! ### Notes on Custom Format Validators
//!
//! - Custom format validators are only called for string instances.
//! - In newer drafts, `format` is purely an annotation and won’t do any checking unless you
//!   opt in by calling `.should_validate_formats(true)` on your options builder. If you omit
//!   it, all `format` keywords are ignored at validation time.
//!
//! # WebAssembly support
//!
//! When using `jsonschema` in WASM environments, be aware that external references are
//! not supported by default due to WASM limitations:
//!    - No filesystem access (`resolve-file` feature)
//!    - No direct HTTP requests, at least right now (`resolve-http` feature)
//!
//! To use `jsonschema` in WASM, disable default features:
//!
//! ```toml
//! jsonschema = { version = "x.y.z", default-features = false }
//! ```
//!
//! For external references in WASM you may want to implement a custom retriever.
//! See the [External References](#external-references) section for implementation details.

pub(crate) mod compiler;
mod content_encoding;
mod content_media_type;
mod ecma;
pub mod error;
pub mod ext;
mod keywords;
mod node;
mod options;
pub mod output;
pub mod paths;
pub(crate) mod properties;
pub(crate) mod regex;
mod retriever;
pub mod types;
mod validator;

#[deprecated(since = "0.30.0", note = "Use `jsonschema::types` instead.")]
pub mod primitive_type {
    pub use super::types::*;
}

pub use error::{ErrorIterator, MaskedValidationError, ValidationError};
pub use keywords::custom::Keyword;
pub use options::{FancyRegex, PatternOptions, Regex, ValidationOptions};
pub use output::BasicOutput;
pub use referencing::{
    Draft, Error as ReferencingError, Registry, RegistryOptions, Resource, Retrieve, Uri,
};
pub use types::{JsonType, JsonTypeSet, JsonTypeSetIterator};
pub use validator::Validator;

#[cfg(feature = "resolve-async")]
pub use referencing::AsyncRetrieve;

use serde_json::Value;

#[cfg(all(
    target_arch = "wasm32",
    any(feature = "resolve-http", feature = "resolve-file")
))]
compile_error!("Features 'resolve-http' and 'resolve-file' are not supported on WASM.");

/// Validate `instance` against `schema` and get a `true` if the instance is valid and `false`
/// otherwise. Draft is detected automatically.
///
/// # Examples
///
/// ```rust
/// use serde_json::json;
///
/// let schema = json!({"maxLength": 5});
/// let instance = json!("foo");
/// assert!(jsonschema::is_valid(&schema, &instance));
/// ```
///
/// # Panics
///
/// This function panics if an invalid schema is passed.
#[must_use]
#[inline]
pub fn is_valid(schema: &Value, instance: &Value) -> bool {
    validator_for(schema)
        .expect("Invalid schema")
        .is_valid(instance)
}

/// Validate `instance` against `schema` and return the first error if any. Draft is detected automatically.
///
/// # Examples
///
/// ```rust
/// use serde_json::json;
///
/// let schema = json!({"maxLength": 5});
/// let instance = json!("foo");
/// assert!(jsonschema::validate(&schema, &instance).is_ok());
/// ```
///
/// # Panics
///
/// This function panics if an invalid schema is passed.
#[inline]
pub fn validate<'i>(schema: &Value, instance: &'i Value) -> Result<(), ValidationError<'i>> {
    validator_for(schema)
        .expect("Invalid schema")
        .validate(instance)
}

/// Create a validator for the input schema with automatic draft detection and default options.
///
/// # Examples
///
/// ```rust
/// # fn main() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::json;
///
/// let schema = json!({"minimum": 5});
/// let instance = json!(42);
///
/// let validator = jsonschema::validator_for(&schema)?;
/// assert!(validator.is_valid(&instance));
/// # Ok(())
/// # }
/// ```
pub fn validator_for(schema: &Value) -> Result<Validator, ValidationError<'static>> {
    Validator::new(schema)
}

/// Create a validator for the input schema with automatic draft detection and default options,
/// using non-blocking retrieval for external references.
///
/// This is the async counterpart to [`validator_for`]. Note that only the construction is
/// asynchronous - validation itself is always synchronous.
///
/// # Examples
///
/// ```rust
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::json;
///
/// let schema = json!({
///     "type": "object",
///     "properties": {
///         "user": { "$ref": "https://example.com/user.json" }
///     }
/// });
///
/// let validator = jsonschema::async_validator_for(&schema).await?;
/// assert!(validator.is_valid(&json!({"user": {"name": "Alice"}})));
/// # Ok(())
/// # }
/// ```
#[cfg(feature = "resolve-async")]
pub async fn async_validator_for(schema: &Value) -> Result<Validator, ValidationError<'static>> {
    Validator::async_new(schema).await
}

/// Create a builder for configuring JSON Schema validation options.
///
/// This function returns a [`ValidationOptions`] struct, which allows you to set various
/// options for JSON Schema validation. You can use this builder to specify
/// the draft version, set custom formats, and more.
///
/// # Examples
///
/// Basic usage with draft specification:
///
/// ```
/// # fn main() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::json;
/// use jsonschema::Draft;
///
/// let schema = json!({"type": "string"});
/// let validator = jsonschema::options()
///     .with_draft(Draft::Draft7)
///     .build(&schema)?;
///
/// assert!(validator.is_valid(&json!("Hello")));
/// # Ok(())
/// # }
/// ```
///
/// Advanced configuration:
///
/// ```
/// # fn main() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::json;
///
/// let schema = json!({"type": "string", "format": "custom"});
/// let validator = jsonschema::options()
///     .with_format("custom", |value| value.len() == 3)
///     .should_validate_formats(true)
///     .build(&schema)?;
///
/// assert!(validator.is_valid(&json!("abc")));
/// assert!(!validator.is_valid(&json!("abcd")));
/// # Ok(())
/// # }
/// ```
///
/// See [`ValidationOptions`] for all available configuration options.
#[must_use]
pub fn options() -> ValidationOptions {
    Validator::options()
}

/// Create a builder for configuring JSON Schema validation options.
///
/// This function returns a [`ValidationOptions`] struct which allows you to set various options for JSON Schema validation.
/// External references will be retrieved using non-blocking I/O.
///
/// # Examples
///
/// Basic usage with external references:
///
/// ```rust
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::json;
///
/// let schema = json!({
///     "$ref": "https://example.com/user.json"
/// });
///
/// let validator = jsonschema::async_options()
///     .build(&schema)
///     .await?;
///
/// assert!(validator.is_valid(&json!({"name": "Alice"})));
/// # Ok(())
/// # }
/// ```
///
/// Advanced configuration:
///
/// ```rust
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::{Value, json};
/// use jsonschema::{Draft, AsyncRetrieve, Uri};
///
/// // Custom async retriever
/// struct MyRetriever;
///
/// #[async_trait::async_trait]
/// impl AsyncRetrieve for MyRetriever {
///     async fn retrieve(&self, uri: &Uri<String>) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
///         // Custom retrieval logic
///         Ok(json!({}))
///     }
/// }
///
/// let schema = json!({
///     "$ref": "https://example.com/user.json"
/// });
/// let validator = jsonschema::async_options()
///     .with_draft(Draft::Draft202012)
///     .with_retriever(MyRetriever)
///     .build(&schema)
///     .await?;
/// # Ok(())
/// # }
/// ```
///
/// See [`ValidationOptions`] for all available configuration options.
#[cfg(feature = "resolve-async")]
#[must_use]
pub fn async_options() -> ValidationOptions<std::sync::Arc<dyn AsyncRetrieve>> {
    Validator::async_options()
}

/// Functionality for validating JSON Schema documents against their meta-schemas.
pub mod meta {
    use crate::{error::ValidationError, Draft, ReferencingError};
    use serde_json::Value;

    use crate::Validator;

    pub(crate) mod validators {
        use crate::Validator;
        use once_cell::sync::Lazy;

        pub static DRAFT4_META_VALIDATOR: Lazy<Validator> = Lazy::new(|| {
            crate::options()
                .without_schema_validation()
                .build(&referencing::meta::DRAFT4)
                .expect("Draft 4 meta-schema should be valid")
        });

        pub static DRAFT6_META_VALIDATOR: Lazy<Validator> = Lazy::new(|| {
            crate::options()
                .without_schema_validation()
                .build(&referencing::meta::DRAFT6)
                .expect("Draft 6 meta-schema should be valid")
        });

        pub static DRAFT7_META_VALIDATOR: Lazy<Validator> = Lazy::new(|| {
            crate::options()
                .without_schema_validation()
                .build(&referencing::meta::DRAFT7)
                .expect("Draft 7 meta-schema should be valid")
        });

        pub static DRAFT201909_META_VALIDATOR: Lazy<Validator> = Lazy::new(|| {
            crate::options()
                .without_schema_validation()
                .build(&referencing::meta::DRAFT201909)
                .expect("Draft 2019-09 meta-schema should be valid")
        });

        pub static DRAFT202012_META_VALIDATOR: Lazy<Validator> = Lazy::new(|| {
            crate::options()
                .without_schema_validation()
                .build(&referencing::meta::DRAFT202012)
                .expect("Draft 2020-12 meta-schema should be valid")
        });
    }

    /// Validate a JSON Schema document against its meta-schema and get a `true` if the schema is valid
    /// and `false` otherwise. Draft version is detected automatically.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({
    ///     "type": "string",
    ///     "maxLength": 5
    /// });
    /// assert!(jsonschema::meta::is_valid(&schema));
    /// ```
    ///
    /// # Panics
    ///
    /// This function panics if the meta-schema can't be detected.
    #[must_use]
    pub fn is_valid(schema: &Value) -> bool {
        meta_validator_for(schema).is_valid(schema)
    }
    /// Validate a JSON Schema document against its meta-schema and return the first error if any.
    /// Draft version is detected automatically.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({
    ///     "type": "string",
    ///     "maxLength": 5
    /// });
    /// assert!(jsonschema::meta::validate(&schema).is_ok());
    ///
    /// // Invalid schema
    /// let invalid_schema = json!({
    ///     "type": "invalid_type"
    /// });
    /// assert!(jsonschema::meta::validate(&invalid_schema).is_err());
    /// ```
    ///
    /// # Panics
    ///
    /// This function panics if the meta-schema can't be detected.
    pub fn validate(schema: &Value) -> Result<(), ValidationError<'_>> {
        meta_validator_for(schema).validate(schema)
    }

    fn meta_validator_for(schema: &Value) -> &'static Validator {
        try_meta_validator_for(schema).expect("Failed to detect meta schema")
    }

    /// Try to validate a JSON Schema document against its meta-schema.
    ///
    /// # Returns
    ///
    /// - `Ok(true)` if the schema is valid
    /// - `Ok(false)` if the schema is invalid
    /// - `Err(ReferencingError)` if the meta-schema can't be detected
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({
    ///     "type": "string",
    ///     "maxLength": 5
    /// });
    /// assert!(jsonschema::meta::try_is_valid(&schema).expect("Unknown draft"));
    ///
    /// // Invalid $schema URI
    /// let undetectable_schema = json!({
    ///     "$schema": "invalid-uri",
    ///     "type": "string"
    /// });
    /// assert!(jsonschema::meta::try_is_valid(&undetectable_schema).is_err());
    /// ```
    pub fn try_is_valid(schema: &Value) -> Result<bool, ReferencingError> {
        Ok(try_meta_validator_for(schema)?.is_valid(schema))
    }

    /// Try to validate a JSON Schema document against its meta-schema.
    ///
    /// # Returns
    ///
    /// - `Ok(Ok(()))` if the schema is valid
    /// - `Ok(Err(ValidationError))` if the schema is invalid
    /// - `Err(ReferencingError)` if the meta-schema can't be detected
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({
    ///     "type": "string",
    ///     "maxLength": 5
    /// });
    /// assert!(jsonschema::meta::try_validate(&schema).expect("Invalid schema").is_ok());
    ///
    /// // Invalid schema
    /// let invalid_schema = json!({
    ///     "type": "invalid_type"
    /// });
    /// assert!(jsonschema::meta::try_validate(&invalid_schema).expect("Invalid schema").is_err());
    ///
    /// // Invalid $schema URI
    /// let undetectable_schema = json!({
    ///     "$schema": "invalid-uri",
    ///     "type": "string"
    /// });
    /// assert!(jsonschema::meta::try_validate(&undetectable_schema).is_err());
    /// ```
    pub fn try_validate(
        schema: &Value,
    ) -> Result<Result<(), ValidationError<'_>>, ReferencingError> {
        Ok(try_meta_validator_for(schema)?.validate(schema))
    }

    fn try_meta_validator_for(schema: &Value) -> Result<&'static Validator, ReferencingError> {
        Ok(match Draft::default().detect(schema)? {
            Draft::Draft4 => &validators::DRAFT4_META_VALIDATOR,
            Draft::Draft6 => &validators::DRAFT6_META_VALIDATOR,
            Draft::Draft7 => &validators::DRAFT7_META_VALIDATOR,
            Draft::Draft201909 => &validators::DRAFT201909_META_VALIDATOR,
            Draft::Draft202012 => &validators::DRAFT202012_META_VALIDATOR,
            _ => unreachable!("Unknown draft"),
        })
    }
}

/// Functionality specific to JSON Schema Draft 4.
///
/// [![Draft 4](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft4.json)](https://bowtie.report/#/implementations/rust-jsonschema)
///
/// This module provides functions for creating validators and performing validation
/// according to the JSON Schema Draft 4 specification.
///
/// # Examples
///
/// ```rust
/// use serde_json::json;
///
/// let schema = json!({"type": "number", "multipleOf": 2});
/// let instance = json!(4);
///
/// assert!(jsonschema::draft4::is_valid(&schema, &instance));
/// ```
pub mod draft4 {
    use super::{Draft, ValidationError, ValidationOptions, Validator, Value};

    /// Create a new JSON Schema validator using Draft 4 specifications.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let instance = json!(42);
    ///
    /// let validator = jsonschema::draft4::new(&schema)?;
    /// assert!(validator.is_valid(&instance));
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        options().build(schema)
    }
    /// Validate an instance against a schema using Draft 4 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft4::is_valid(&schema, &valid));
    /// assert!(!jsonschema::draft4::is_valid(&schema, &invalid));
    /// ```
    #[must_use]
    pub fn is_valid(schema: &Value, instance: &Value) -> bool {
        new(schema).expect("Invalid schema").is_valid(instance)
    }
    /// Validate an instance against a schema using Draft 4 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft4::validate(&schema, &valid).is_ok());
    /// assert!(jsonschema::draft4::validate(&schema, &invalid).is_err());
    /// ```
    pub fn validate<'i>(schema: &Value, instance: &'i Value) -> Result<(), ValidationError<'i>> {
        new(schema).expect("Invalid schema").validate(instance)
    }
    /// Creates a [`ValidationOptions`] builder pre-configured for JSON Schema Draft 4.
    ///
    /// This function provides a shorthand for `jsonschema::options().with_draft(Draft::Draft4)`.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"type": "string", "format": "ends-with-42"});
    /// let validator = jsonschema::draft4::options()
    ///     .with_format("ends-with-42", |s| s.ends_with("42"))
    ///     .should_validate_formats(true)
    ///     .build(&schema)?;
    ///
    /// assert!(validator.is_valid(&json!("Hello 42")));
    /// assert!(!validator.is_valid(&json!("No!")));
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// See [`ValidationOptions`] for all available configuration options.
    #[must_use]
    pub fn options() -> ValidationOptions {
        crate::options().with_draft(Draft::Draft4)
    }

    /// Functionality for validating JSON Schema Draft 4 documents.
    pub mod meta {
        use crate::ValidationError;
        use serde_json::Value;

        pub use crate::meta::validators::DRAFT4_META_VALIDATOR as VALIDATOR;

        /// Validate a JSON Schema document against Draft 4 meta-schema and get a `true` if the schema is valid
        /// and `false` otherwise.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft4::meta::is_valid(&schema));
        /// ```
        #[must_use]
        #[inline]
        pub fn is_valid(schema: &Value) -> bool {
            VALIDATOR.is_valid(schema)
        }

        /// Validate a JSON Schema document against Draft 4 meta-schema and return the first error if any.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft4::meta::validate(&schema).is_ok());
        ///
        /// // Invalid schema
        /// let invalid_schema = json!({
        ///     "type": "invalid_type"
        /// });
        /// assert!(jsonschema::draft4::meta::validate(&invalid_schema).is_err());
        /// ```
        #[inline]
        pub fn validate(schema: &Value) -> Result<(), ValidationError<'_>> {
            VALIDATOR.validate(schema)
        }
    }
}

/// Functionality specific to JSON Schema Draft 6.
///
/// [![Draft 6](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft6.json)](https://bowtie.report/#/implementations/rust-jsonschema)
///
/// This module provides functions for creating validators and performing validation
/// according to the JSON Schema Draft 6 specification.
///
/// # Examples
///
/// ```rust
/// use serde_json::json;
///
/// let schema = json!({"type": "string", "format": "uri"});
/// let instance = json!("https://www.example.com");
///
/// assert!(jsonschema::draft6::is_valid(&schema, &instance));
/// ```
pub mod draft6 {
    use super::{Draft, ValidationError, ValidationOptions, Validator, Value};

    /// Create a new JSON Schema validator using Draft 6 specifications.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let instance = json!(42);
    ///
    /// let validator = jsonschema::draft6::new(&schema)?;
    /// assert!(validator.is_valid(&instance));
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        options().build(schema)
    }
    /// Validate an instance against a schema using Draft 6 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft6::is_valid(&schema, &valid));
    /// assert!(!jsonschema::draft6::is_valid(&schema, &invalid));
    /// ```
    #[must_use]
    pub fn is_valid(schema: &Value, instance: &Value) -> bool {
        new(schema).expect("Invalid schema").is_valid(instance)
    }
    /// Validate an instance against a schema using Draft 6 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft6::validate(&schema, &valid).is_ok());
    /// assert!(jsonschema::draft6::validate(&schema, &invalid).is_err());
    /// ```
    pub fn validate<'i>(schema: &Value, instance: &'i Value) -> Result<(), ValidationError<'i>> {
        new(schema).expect("Invalid schema").validate(instance)
    }
    /// Creates a [`ValidationOptions`] builder pre-configured for JSON Schema Draft 6.
    ///
    /// This function provides a shorthand for `jsonschema::options().with_draft(Draft::Draft6)`.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"type": "string", "format": "ends-with-42"});
    /// let validator = jsonschema::draft6::options()
    ///     .with_format("ends-with-42", |s| s.ends_with("42"))
    ///     .should_validate_formats(true)
    ///     .build(&schema)?;
    ///
    /// assert!(validator.is_valid(&json!("Hello 42")));
    /// assert!(!validator.is_valid(&json!("No!")));
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// See [`ValidationOptions`] for all available configuration options.
    #[must_use]
    pub fn options() -> ValidationOptions {
        crate::options().with_draft(Draft::Draft6)
    }

    /// Functionality for validating JSON Schema Draft 6 documents.
    pub mod meta {
        use crate::ValidationError;
        use serde_json::Value;

        pub use crate::meta::validators::DRAFT6_META_VALIDATOR as VALIDATOR;

        /// Validate a JSON Schema document against Draft 6 meta-schema and get a `true` if the schema is valid
        /// and `false` otherwise.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft6::meta::is_valid(&schema));
        /// ```
        #[must_use]
        #[inline]
        pub fn is_valid(schema: &Value) -> bool {
            VALIDATOR.is_valid(schema)
        }

        /// Validate a JSON Schema document against Draft 6 meta-schema and return the first error if any.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft6::meta::validate(&schema).is_ok());
        ///
        /// // Invalid schema
        /// let invalid_schema = json!({
        ///     "type": "invalid_type"
        /// });
        /// assert!(jsonschema::draft6::meta::validate(&invalid_schema).is_err());
        /// ```
        #[inline]
        pub fn validate(schema: &Value) -> Result<(), ValidationError<'_>> {
            VALIDATOR.validate(schema)
        }
    }
}

/// Functionality specific to JSON Schema Draft 7.
///
/// [![Draft 7](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft7.json)](https://bowtie.report/#/implementations/rust-jsonschema)
///
/// This module provides functions for creating validators and performing validation
/// according to the JSON Schema Draft 7 specification.
///
/// # Examples
///
/// ```rust
/// use serde_json::json;
///
/// let schema = json!({"type": "string", "pattern": "^[a-zA-Z0-9]+$"});
/// let instance = json!("abc123");
///
/// assert!(jsonschema::draft7::is_valid(&schema, &instance));
/// ```
pub mod draft7 {
    use super::{Draft, ValidationError, ValidationOptions, Validator, Value};

    /// Create a new JSON Schema validator using Draft 7 specifications.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let instance = json!(42);
    ///
    /// let validator = jsonschema::draft7::new(&schema)?;
    /// assert!(validator.is_valid(&instance));
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        options().build(schema)
    }
    /// Validate an instance against a schema using Draft 7 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft7::is_valid(&schema, &valid));
    /// assert!(!jsonschema::draft7::is_valid(&schema, &invalid));
    /// ```
    #[must_use]
    pub fn is_valid(schema: &Value, instance: &Value) -> bool {
        new(schema).expect("Invalid schema").is_valid(instance)
    }
    /// Validate an instance against a schema using Draft 7 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft7::validate(&schema, &valid).is_ok());
    /// assert!(jsonschema::draft7::validate(&schema, &invalid).is_err());
    /// ```
    pub fn validate<'i>(schema: &Value, instance: &'i Value) -> Result<(), ValidationError<'i>> {
        new(schema).expect("Invalid schema").validate(instance)
    }
    /// Creates a [`ValidationOptions`] builder pre-configured for JSON Schema Draft 7.
    ///
    /// This function provides a shorthand for `jsonschema::options().with_draft(Draft::Draft7)`.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"type": "string", "format": "ends-with-42"});
    /// let validator = jsonschema::draft7::options()
    ///     .with_format("ends-with-42", |s| s.ends_with("42"))
    ///     .should_validate_formats(true)
    ///     .build(&schema)?;
    ///
    /// assert!(validator.is_valid(&json!("Hello 42")));
    /// assert!(!validator.is_valid(&json!("No!")));
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// See [`ValidationOptions`] for all available configuration options.
    #[must_use]
    pub fn options() -> ValidationOptions {
        crate::options().with_draft(Draft::Draft7)
    }

    /// Functionality for validating JSON Schema Draft 7 documents.
    pub mod meta {
        use crate::ValidationError;
        use serde_json::Value;

        pub use crate::meta::validators::DRAFT7_META_VALIDATOR as VALIDATOR;

        /// Validate a JSON Schema document against Draft 7 meta-schema and get a `true` if the schema is valid
        /// and `false` otherwise.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft7::meta::is_valid(&schema));
        /// ```
        #[must_use]
        #[inline]
        pub fn is_valid(schema: &Value) -> bool {
            VALIDATOR.is_valid(schema)
        }

        /// Validate a JSON Schema document against Draft 7 meta-schema and return the first error if any.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft7::meta::validate(&schema).is_ok());
        ///
        /// // Invalid schema
        /// let invalid_schema = json!({
        ///     "type": "invalid_type"
        /// });
        /// assert!(jsonschema::draft7::meta::validate(&invalid_schema).is_err());
        /// ```
        #[inline]
        pub fn validate(schema: &Value) -> Result<(), ValidationError<'_>> {
            VALIDATOR.validate(schema)
        }
    }
}

/// Functionality specific to JSON Schema Draft 2019-09.
///
/// [![Draft 2019-09](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft2019-09.json)](https://bowtie.report/#/implementations/rust-jsonschema)
///
/// This module provides functions for creating validators and performing validation
/// according to the JSON Schema Draft 2019-09 specification.
///
/// # Examples
///
/// ```rust
/// use serde_json::json;
///
/// let schema = json!({"type": "array", "minItems": 2, "uniqueItems": true});
/// let instance = json!([1, 2]);
///
/// assert!(jsonschema::draft201909::is_valid(&schema, &instance));
/// ```
pub mod draft201909 {
    use super::{Draft, ValidationError, ValidationOptions, Validator, Value};

    /// Create a new JSON Schema validator using Draft 2019-09 specifications.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let instance = json!(42);
    ///
    /// let validator = jsonschema::draft201909::new(&schema)?;
    /// assert!(validator.is_valid(&instance));
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        options().build(schema)
    }
    /// Validate an instance against a schema using Draft 2019-09 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft201909::is_valid(&schema, &valid));
    /// assert!(!jsonschema::draft201909::is_valid(&schema, &invalid));
    /// ```
    #[must_use]
    pub fn is_valid(schema: &Value, instance: &Value) -> bool {
        new(schema).expect("Invalid schema").is_valid(instance)
    }
    /// Validate an instance against a schema using Draft 2019-09 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft201909::validate(&schema, &valid).is_ok());
    /// assert!(jsonschema::draft201909::validate(&schema, &invalid).is_err());
    /// ```
    pub fn validate<'i>(schema: &Value, instance: &'i Value) -> Result<(), ValidationError<'i>> {
        new(schema).expect("Invalid schema").validate(instance)
    }
    /// Creates a [`ValidationOptions`] builder pre-configured for JSON Schema Draft 2019-09.
    ///
    /// This function provides a shorthand for `jsonschema::options().with_draft(Draft::Draft201909)`.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"type": "string", "format": "ends-with-42"});
    /// let validator = jsonschema::draft201909::options()
    ///     .with_format("ends-with-42", |s| s.ends_with("42"))
    ///     .should_validate_formats(true)
    ///     .build(&schema)?;
    ///
    /// assert!(validator.is_valid(&json!("Hello 42")));
    /// assert!(!validator.is_valid(&json!("No!")));
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// See [`ValidationOptions`] for all available configuration options.
    #[must_use]
    pub fn options() -> ValidationOptions {
        crate::options().with_draft(Draft::Draft201909)
    }

    /// Functionality for validating JSON Schema Draft 2019-09 documents.
    pub mod meta {
        use crate::ValidationError;
        use serde_json::Value;

        pub use crate::meta::validators::DRAFT201909_META_VALIDATOR as VALIDATOR;
        /// Validate a JSON Schema document against Draft 2019-09 meta-schema and get a `true` if the schema is valid
        /// and `false` otherwise.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft201909::meta::is_valid(&schema));
        /// ```
        #[must_use]
        #[inline]
        pub fn is_valid(schema: &Value) -> bool {
            VALIDATOR.is_valid(schema)
        }

        /// Validate a JSON Schema document against Draft 2019-09 meta-schema and return the first error if any.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft201909::meta::validate(&schema).is_ok());
        ///
        /// // Invalid schema
        /// let invalid_schema = json!({
        ///     "type": "invalid_type"
        /// });
        /// assert!(jsonschema::draft201909::meta::validate(&invalid_schema).is_err());
        /// ```
        #[inline]
        pub fn validate(schema: &Value) -> Result<(), ValidationError<'_>> {
            VALIDATOR.validate(schema)
        }
    }
}

/// Functionality specific to JSON Schema Draft 2020-12.
///
/// [![Draft 2020-12](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Frust-jsonschema%2Fcompliance%2Fdraft2020-12.json)](https://bowtie.report/#/implementations/rust-jsonschema)
///
/// This module provides functions for creating validators and performing validation
/// according to the JSON Schema Draft 2020-12 specification.
///
/// # Examples
///
/// ```rust
/// # fn main() -> Result<(), Box<dyn std::error::Error>> {
/// use serde_json::json;
///
/// let schema = json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]});
/// let instance = json!({"name": "John Doe"});
///
/// assert!(jsonschema::draft202012::is_valid(&schema, &instance));
/// # Ok(())
/// # }
/// ```
pub mod draft202012 {
    use super::{Draft, ValidationError, ValidationOptions, Validator, Value};

    /// Create a new JSON Schema validator using Draft 2020-12 specifications.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let instance = json!(42);
    ///
    /// let validator = jsonschema::draft202012::new(&schema)?;
    /// assert!(validator.is_valid(&instance));
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(schema: &Value) -> Result<Validator, ValidationError<'static>> {
        options().build(schema)
    }
    /// Validate an instance against a schema using Draft 2020-12 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft202012::is_valid(&schema, &valid));
    /// assert!(!jsonschema::draft202012::is_valid(&schema, &invalid));
    /// ```
    #[must_use]
    pub fn is_valid(schema: &Value, instance: &Value) -> bool {
        new(schema).expect("Invalid schema").is_valid(instance)
    }
    /// Validate an instance against a schema using Draft 2020-12 specifications without creating a validator.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use serde_json::json;
    ///
    /// let schema = json!({"minimum": 5});
    /// let valid = json!(42);
    /// let invalid = json!(3);
    ///
    /// assert!(jsonschema::draft202012::validate(&schema, &valid).is_ok());
    /// assert!(jsonschema::draft202012::validate(&schema, &invalid).is_err());
    /// ```
    pub fn validate<'i>(schema: &Value, instance: &'i Value) -> Result<(), ValidationError<'i>> {
        new(schema).expect("Invalid schema").validate(instance)
    }
    /// Creates a [`ValidationOptions`] builder pre-configured for JSON Schema Draft 2020-12.
    ///
    /// This function provides a shorthand for `jsonschema::options().with_draft(Draft::Draft202012)`.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use serde_json::json;
    ///
    /// let schema = json!({"type": "string", "format": "ends-with-42"});
    /// let validator = jsonschema::draft202012::options()
    ///     .with_format("ends-with-42", |s| s.ends_with("42"))
    ///     .should_validate_formats(true)
    ///     .build(&schema)?;
    ///
    /// assert!(validator.is_valid(&json!("Hello 42")));
    /// assert!(!validator.is_valid(&json!("No!")));
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// See [`ValidationOptions`] for all available configuration options.
    #[must_use]
    pub fn options() -> ValidationOptions {
        crate::options().with_draft(Draft::Draft202012)
    }

    /// Functionality for validating JSON Schema Draft 2020-12 documents.
    pub mod meta {
        use crate::ValidationError;
        use serde_json::Value;

        pub use crate::meta::validators::DRAFT202012_META_VALIDATOR as VALIDATOR;

        /// Validate a JSON Schema document against Draft 2020-12 meta-schema and get a `true` if the schema is valid
        /// and `false` otherwise.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft202012::meta::is_valid(&schema));
        /// ```
        #[must_use]
        #[inline]
        pub fn is_valid(schema: &Value) -> bool {
            VALIDATOR.is_valid(schema)
        }

        /// Validate a JSON Schema document against Draft 2020-12 meta-schema and return the first error if any.
        ///
        /// # Examples
        ///
        /// ```rust
        /// use serde_json::json;
        ///
        /// let schema = json!({
        ///     "type": "string",
        ///     "maxLength": 5
        /// });
        /// assert!(jsonschema::draft202012::meta::validate(&schema).is_ok());
        ///
        /// // Invalid schema
        /// let invalid_schema = json!({
        ///     "type": "invalid_type"
        /// });
        /// assert!(jsonschema::draft202012::meta::validate(&invalid_schema).is_err());
        /// ```
        #[inline]
        pub fn validate(schema: &Value) -> Result<(), ValidationError<'_>> {
            VALIDATOR.validate(schema)
        }
    }
}

#[cfg(test)]
pub(crate) mod tests_util {
    use super::Validator;
    use crate::ValidationError;
    use serde_json::Value;

    #[track_caller]
    pub(crate) fn is_not_valid_with(validator: &Validator, instance: &Value) {
        assert!(
            !validator.is_valid(instance),
            "{instance} should not be valid (via is_valid)",
        );
        assert!(
            validator.validate(instance).is_err(),
            "{instance} should not be valid (via validate)",
        );
        assert!(
            validator.iter_errors(instance).next().is_some(),
            "{instance} should not be valid (via validate)",
        );
        assert!(
            !validator.apply(instance).basic().is_valid(),
            "{instance} should not be valid (via apply)",
        );
    }

    #[track_caller]
    pub(crate) fn is_not_valid(schema: &Value, instance: &Value) {
        let validator = crate::options()
            .should_validate_formats(true)
            .build(schema)
            .expect("Invalid schema");
        is_not_valid_with(&validator, instance);
    }

    #[track_caller]
    pub(crate) fn is_not_valid_with_draft(draft: crate::Draft, schema: &Value, instance: &Value) {
        let validator = crate::options()
            .should_validate_formats(true)
            .with_draft(draft)
            .build(schema)
            .expect("Invalid schema");
        is_not_valid_with(&validator, instance);
    }

    pub(crate) fn expect_errors(schema: &Value, instance: &Value, errors: &[&str]) {
        assert_eq!(
            crate::validator_for(schema)
                .expect("Should be a valid schema")
                .iter_errors(instance)
                .map(|e| e.to_string())
                .collect::<Vec<String>>(),
            errors
        );
    }

    #[track_caller]
    pub(crate) fn is_valid_with(validator: &Validator, instance: &Value) {
        if let Some(first) = validator.iter_errors(instance).next() {
            panic!(
                "{} should be valid (via validate). Error: {} at {}",
                instance, first, first.instance_path
            );
        }
        assert!(
            validator.is_valid(instance),
            "{instance} should be valid (via is_valid)",
        );
        assert!(
            validator.validate(instance).is_ok(),
            "{instance} should be valid (via is_valid)",
        );
        assert!(
            validator.apply(instance).basic().is_valid(),
            "{instance} should be valid (via apply)",
        );
    }

    #[track_caller]
    pub(crate) fn is_valid(schema: &Value, instance: &Value) {
        let validator = crate::options()
            .should_validate_formats(true)
            .build(schema)
            .expect("Invalid schema");
        is_valid_with(&validator, instance);
    }

    #[track_caller]
    pub(crate) fn is_valid_with_draft(draft: crate::Draft, schema: &Value, instance: &Value) {
        let validator = crate::options().with_draft(draft).build(schema).unwrap();
        is_valid_with(&validator, instance);
    }

    #[track_caller]
    pub(crate) fn validate(schema: &Value, instance: &Value) -> ValidationError<'static> {
        let validator = crate::options()
            .should_validate_formats(true)
            .build(schema)
            .expect("Invalid schema");
        let err = validator
            .validate(instance)
            .expect_err("Should be an error")
            .to_owned();
        err
    }

    #[track_caller]
    pub(crate) fn assert_schema_location(schema: &Value, instance: &Value, expected: &str) {
        let error = validate(schema, instance);
        assert_eq!(error.schema_path.as_str(), expected);
    }

    #[track_caller]
    pub(crate) fn assert_locations(schema: &Value, instance: &Value, expected: &[&str]) {
        let validator = crate::validator_for(schema).unwrap();
        let errors = validator.iter_errors(instance);
        for (error, location) in errors.zip(expected) {
            assert_eq!(error.schema_path.as_str(), *location);
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::{validator_for, ValidationError};

    use super::Draft;
    use serde_json::json;
    use test_case::test_case;

    #[test_case(crate::is_valid ; "autodetect")]
    #[test_case(crate::draft4::is_valid ; "draft4")]
    #[test_case(crate::draft6::is_valid ; "draft6")]
    #[test_case(crate::draft7::is_valid ; "draft7")]
    #[test_case(crate::draft201909::is_valid ; "draft201909")]
    #[test_case(crate::draft202012::is_valid ; "draft202012")]
    fn test_is_valid(is_valid_fn: fn(&serde_json::Value, &serde_json::Value) -> bool) {
        let schema = json!({
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "age": {"type": "integer", "minimum": 0}
            },
            "required": ["name"]
        });

        let valid_instance = json!({
            "name": "John Doe",
            "age": 30
        });

        let invalid_instance = json!({
            "age": -5
        });

        assert!(is_valid_fn(&schema, &valid_instance));
        assert!(!is_valid_fn(&schema, &invalid_instance));
    }

    #[test_case(crate::validate ; "autodetect")]
    #[test_case(crate::draft4::validate ; "draft4")]
    #[test_case(crate::draft6::validate ; "draft6")]
    #[test_case(crate::draft7::validate ; "draft7")]
    #[test_case(crate::draft201909::validate ; "draft201909")]
    #[test_case(crate::draft202012::validate ; "draft202012")]
    fn test_validate(
        validate_fn: for<'i> fn(
            &serde_json::Value,
            &'i serde_json::Value,
        ) -> Result<(), ValidationError<'i>>,
    ) {
        let schema = json!({
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "age": {"type": "integer", "minimum": 0}
            },
            "required": ["name"]
        });

        let valid_instance = json!({
            "name": "John Doe",
            "age": 30
        });

        let invalid_instance = json!({
            "age": -5
        });

        assert!(validate_fn(&schema, &valid_instance).is_ok());
        assert!(validate_fn(&schema, &invalid_instance).is_err());
    }

    #[test_case(crate::meta::validate, crate::meta::is_valid ; "autodetect")]
    #[test_case(crate::draft4::meta::validate, crate::draft4::meta::is_valid ; "draft4")]
    #[test_case(crate::draft6::meta::validate, crate::draft6::meta::is_valid ; "draft6")]
    #[test_case(crate::draft7::meta::validate, crate::draft7::meta::is_valid ; "draft7")]
    #[test_case(crate::draft201909::meta::validate, crate::draft201909::meta::is_valid ; "draft201909")]
    #[test_case(crate::draft202012::meta::validate, crate::draft202012::meta::is_valid ; "draft202012")]
    fn test_meta_validation(
        validate_fn: fn(&serde_json::Value) -> Result<(), ValidationError>,
        is_valid_fn: fn(&serde_json::Value) -> bool,
    ) {
        let valid = json!({
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "age": {"type": "integer", "minimum": 0}
            },
            "required": ["name"]
        });

        let invalid = json!({
            "type": "invalid_type",
            "minimum": "not_a_number",
            "required": true  // should be an array
        });

        assert!(validate_fn(&valid).is_ok());
        assert!(validate_fn(&invalid).is_err());
        assert!(is_valid_fn(&valid));
        assert!(!is_valid_fn(&invalid));
    }

    #[test]
    fn test_exclusive_minimum_across_drafts() {
        // In Draft 4, exclusiveMinimum is a boolean modifier for minimum
        let draft4_schema = json!({
            "$schema": "http://json-schema.org/draft-04/schema#",
            "minimum": 5,
            "exclusiveMinimum": true
        });
        assert!(crate::meta::is_valid(&draft4_schema));
        assert!(crate::meta::validate(&draft4_schema).is_ok());

        // This is invalid in Draft 4 (exclusiveMinimum must be boolean)
        let invalid_draft4 = json!({
            "$schema": "http://json-schema.org/draft-04/schema#",
            "exclusiveMinimum": 5
        });
        assert!(!crate::meta::is_valid(&invalid_draft4));
        assert!(crate::meta::validate(&invalid_draft4).is_err());

        // In Draft 6 and later, exclusiveMinimum is a numeric value
        let drafts = [
            "http://json-schema.org/draft-06/schema#",
            "http://json-schema.org/draft-07/schema#",
            "https://json-schema.org/draft/2019-09/schema",
            "https://json-schema.org/draft/2020-12/schema",
        ];

        for uri in drafts {
            // Valid in Draft 6+ (numeric exclusiveMinimum)
            let valid_schema = json!({
                "$schema": uri,
                "exclusiveMinimum": 5
            });
            assert!(
                crate::meta::is_valid(&valid_schema),
                "Schema should be valid for {uri}"
            );
            assert!(
                crate::meta::validate(&valid_schema).is_ok(),
                "Schema validation should succeed for {uri}",
            );

            // Invalid in Draft 6+ (can't use boolean with minimum)
            let invalid_schema = json!({
                "$schema": uri,
                "minimum": 5,
                "exclusiveMinimum": true
            });
            assert!(
                !crate::meta::is_valid(&invalid_schema),
                "Schema should be invalid for {uri}",
            );
            assert!(
                crate::meta::validate(&invalid_schema).is_err(),
                "Schema validation should fail for {uri}",
            );
        }
    }

    #[test_case(
        "http://json-schema.org/draft-04/schema#",
        true,
        5,
        true ; "draft4 valid"
    )]
    #[test_case(
        "http://json-schema.org/draft-04/schema#",
        5,
        true,
        false ; "draft4 invalid"
    )]
    #[test_case(
        "http://json-schema.org/draft-06/schema#",
        5,
        true,
        false ; "draft6 invalid"
    )]
    #[test_case(
        "http://json-schema.org/draft-07/schema#",
        5,
        true,
        false ; "draft7 invalid"
    )]
    #[test_case(
        "https://json-schema.org/draft/2019-09/schema",
        5,
        true,
        false ; "draft2019-09 invalid"
    )]
    #[test_case(
        "https://json-schema.org/draft/2020-12/schema",
        5,
        true,
        false ; "draft2020-12 invalid"
    )]
    fn test_exclusive_minimum_detection(
        schema_uri: &str,
        exclusive_minimum: impl Into<serde_json::Value>,
        minimum: impl Into<serde_json::Value>,
        expected: bool,
    ) {
        let schema = json!({
            "$schema": schema_uri,
            "minimum": minimum.into(),
            "exclusiveMinimum": exclusive_minimum.into()
        });

        let is_valid_result = crate::meta::try_is_valid(&schema);
        assert!(is_valid_result.is_ok());
        assert_eq!(is_valid_result.expect("Unknown draft"), expected);

        let validate_result = crate::meta::try_validate(&schema);
        assert!(validate_result.is_ok());
        assert_eq!(validate_result.expect("Unknown draft").is_ok(), expected);
    }

    #[test]
    fn test_invalid_schema_uri() {
        let schema = json!({
            "$schema": "invalid-uri",
            "type": "string"
        });

        assert!(crate::meta::try_is_valid(&schema).is_err());
        assert!(crate::meta::try_validate(&schema).is_err());
    }

    #[test]
    fn test_invalid_schema_keyword() {
        let schema = json!({
            // Note `htt`, not `http`
            "$schema": "htt://json-schema.org/draft-07/schema",
        });
        let error = crate::validator_for(&schema).expect_err("Should fail");
        assert_eq!(
            error.to_string(),
            "Unknown specification: htt://json-schema.org/draft-07/schema"
        );
    }

    #[test_case(Draft::Draft4)]
    #[test_case(Draft::Draft6)]
    #[test_case(Draft::Draft7)]
    fn meta_schemas(draft: Draft) {
        // See GH-258
        for schema in [json!({"enum": [0, 0.0]}), json!({"enum": []})] {
            assert!(crate::options().with_draft(draft).build(&schema).is_ok());
        }
    }

    #[test]
    fn incomplete_escape_in_pattern() {
        // See GH-253
        let schema = json!({"pattern": "\\u"});
        assert!(crate::validator_for(&schema).is_err());
    }

    #[test]
    fn validation_error_propagation() {
        fn foo() -> Result<(), Box<dyn std::error::Error>> {
            let schema = json!({});
            let validator = validator_for(&schema)?;
            let _ = validator.is_valid(&json!({}));
            Ok(())
        }
        let _ = foo();
    }
}

#[cfg(all(test, feature = "resolve-async"))]
mod async_tests {
    use referencing::Resource;
    use std::collections::HashMap;

    use serde_json::json;

    use crate::{AsyncRetrieve, Draft, Uri};

    /// Mock async retriever for testing
    struct TestRetriever {
        schemas: HashMap<String, serde_json::Value>,
    }

    impl TestRetriever {
        fn new() -> Self {
            let mut schemas = HashMap::new();
            schemas.insert(
                "https://example.com/user.json".to_string(),
                json!({
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "age": {"type": "integer", "minimum": 0}
                    },
                    "required": ["name"]
                }),
            );
            Self { schemas }
        }
    }

    #[async_trait::async_trait]
    impl AsyncRetrieve for TestRetriever {
        async fn retrieve(
            &self,
            uri: &Uri<String>,
        ) -> Result<serde_json::Value, Box<dyn std::error::Error + Send + Sync>> {
            self.schemas
                .get(uri.as_str())
                .cloned()
                .ok_or_else(|| "Schema not found".into())
        }
    }

    #[tokio::test]
    async fn test_async_validator_for() {
        let schema = json!({
            "$ref": "https://example.com/user.json"
        });

        let validator = crate::async_options()
            .with_retriever(TestRetriever::new())
            .build(&schema)
            .await
            .unwrap();

        // Valid instance
        assert!(validator.is_valid(&json!({
            "name": "John Doe",
            "age": 30
        })));

        // Invalid instances
        assert!(!validator.is_valid(&json!({
            "age": -5
        })));
        assert!(!validator.is_valid(&json!({
            "name": 123,
            "age": 30
        })));
    }

    #[tokio::test]
    async fn test_async_options_with_draft() {
        let schema = json!({
            "$ref": "https://example.com/user.json"
        });

        let validator = crate::async_options()
            .with_draft(Draft::Draft202012)
            .with_retriever(TestRetriever::new())
            .build(&schema)
            .await
            .unwrap();

        assert!(validator.is_valid(&json!({
            "name": "John Doe",
            "age": 30
        })));
    }

    #[tokio::test]
    async fn test_async_retrieval_failure() {
        let schema = json!({
            "$ref": "https://example.com/nonexistent.json"
        });

        let result = crate::async_options()
            .with_retriever(TestRetriever::new())
            .build(&schema)
            .await;

        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Schema not found"));
    }

    #[tokio::test]
    async fn test_async_nested_references() {
        let mut retriever = TestRetriever::new();
        retriever.schemas.insert(
            "https://example.com/nested.json".to_string(),
            json!({
                "type": "object",
                "properties": {
                    "user": { "$ref": "https://example.com/user.json" }
                }
            }),
        );

        let schema = json!({
            "$ref": "https://example.com/nested.json"
        });

        let validator = crate::async_options()
            .with_retriever(retriever)
            .build(&schema)
            .await
            .unwrap();

        // Valid nested structure
        assert!(validator.is_valid(&json!({
            "user": {
                "name": "John Doe",
                "age": 30
            }
        })));

        // Invalid nested structure
        assert!(!validator.is_valid(&json!({
            "user": {
                "age": -5
            }
        })));
    }

    #[tokio::test]
    async fn test_async_with_registry() {
        use crate::Registry;

        // Create a registry with initial schemas
        let registry = Registry::options()
            .async_retriever(TestRetriever::new())
            .build([(
                "https://example.com/user.json",
                Resource::from_contents(json!({
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "age": {"type": "integer", "minimum": 0}
                    },
                    "required": ["name"]
                }))
                .unwrap(),
            )])
            .await
            .unwrap();

        // Create a validator using the pre-populated registry
        let validator = crate::async_options()
            .with_registry(registry)
            .build(&json!({
                "$ref": "https://example.com/user.json"
            }))
            .await
            .unwrap();

        // Verify that validation works with the registry
        assert!(validator.is_valid(&json!({
            "name": "John Doe",
            "age": 30
        })));
        assert!(!validator.is_valid(&json!({
            "age": -5
        })));
    }

    #[tokio::test]
    async fn test_async_validator_for_basic() {
        let schema = json!({"type": "integer"});

        let validator = crate::async_validator_for(&schema).await.unwrap();

        assert!(validator.is_valid(&json!(42)));
        assert!(!validator.is_valid(&json!("abc")));
    }
}
