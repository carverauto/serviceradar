//! # Description
//! This module contains various validators for the `additionalProperties` keyword.
//!
//! The goal here is to compute intersections with another keywords affecting properties validation:
//!   - `properties`
//!   - `patternProperties`
//!
//! Each valid combination of these keywords has a validator here.
use crate::{
    compiler,
    error::{no_error, ErrorIterator, ValidationError},
    keywords::CompilationResult,
    node::SchemaNode,
    options::PatternEngineOptions,
    output::{Annotations, BasicOutput, OutputUnit},
    paths::{LazyLocation, Location},
    properties::{
        are_properties_valid, compile_big_map, compile_dynamic_prop_map_validator,
        compile_fancy_regex_patterns, compile_regex_patterns, compile_small_map, BigValidatorsMap,
        PropertiesValidatorsMap, SmallValidatorsMap,
    },
    regex::RegexEngine,
    types::JsonType,
    validator::{PartialApplication, Validate},
};
use referencing::Uri;
use serde_json::{Map, Value};

macro_rules! is_valid {
    ($node:expr, $value:ident) => {{
        $node.is_valid($value)
    }};
}

macro_rules! is_valid_pattern_schema {
    ($node:expr, $value:ident) => {{
        if $node.is_valid($value) {
            // Matched & valid - check the next pattern
            continue;
        }
        // Invalid - there is no reason to check other patterns
        return false;
    }};
}

macro_rules! is_valid_patterns {
    ($patterns:expr, $property:ident, $value:ident) => {{
        // One property may match multiple patterns, therefore we need to check them all
        let mut has_match = false;
        for (re, node) in $patterns {
            // If there is a match, then the value should match the sub-schema
            if re.is_match($property).unwrap_or(false) {
                has_match = true;
                is_valid_pattern_schema!(node, $value)
            }
        }
        if !has_match {
            // No pattern matched - INVALID property
            return false;
        }
    }};
}

macro_rules! iter_errors {
    ($node:expr, $value:ident, $instance_path:expr, $property_name:expr) => {{
        let location = $instance_path.push($property_name.as_str());
        $node.iter_errors($value, &location)
    }};
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": {"type": "integer"},
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "bar": 6
/// }
/// ```
pub(crate) struct AdditionalPropertiesValidator {
    node: SchemaNode,
}
impl AdditionalPropertiesValidator {
    #[inline]
    pub(crate) fn compile<'a>(schema: &'a Value, ctx: &compiler::Context) -> CompilationResult<'a> {
        let ctx = ctx.new_at_location("additionalProperties");
        Ok(Box::new(AdditionalPropertiesValidator {
            node: compiler::compile(&ctx, ctx.as_resource_ref(schema))?,
        }))
    }
}
impl Validate for AdditionalPropertiesValidator {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let errors: Vec<_> = item
                .iter()
                .flat_map(|(name, value)| iter_errors!(self.node, value, location, name))
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            item.values().all(|i| self.node.is_valid(i))
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            for (name, value) in item {
                self.node.validate(value, &location.push(name))?;
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut matched_props = Vec::with_capacity(item.len());
            let mut output = BasicOutput::default();
            for (name, value) in item {
                let path = location.push(name.as_str());
                output += self.node.apply_rooted(value, &path);
                matched_props.push(name.clone());
            }
            let mut result: PartialApplication = output.into();
            result.annotate(Value::from(matched_props).into());
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": false
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {}
/// ```
pub(crate) struct AdditionalPropertiesFalseValidator {
    location: Location,
}
impl AdditionalPropertiesFalseValidator {
    #[inline]
    pub(crate) fn compile<'a>(location: Location) -> CompilationResult<'a> {
        Ok(Box::new(AdditionalPropertiesFalseValidator { location }))
    }
}
impl Validate for AdditionalPropertiesFalseValidator {
    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            item.iter().next().is_none()
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            if let Some((_, value)) = item.iter().next() {
                return Err(ValidationError::false_schema(
                    self.location.clone(),
                    location.into(),
                    value,
                ));
            }
        }
        Ok(())
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": false,
///     "properties": {
///         "foo": {"type": "string"}
///     },
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "foo": "bar",
/// }
/// ```
pub(crate) struct AdditionalPropertiesNotEmptyFalseValidator<M: PropertiesValidatorsMap> {
    properties: M,
    location: Location,
}
impl AdditionalPropertiesNotEmptyFalseValidator<SmallValidatorsMap> {
    #[inline]
    pub(crate) fn compile<'a>(
        map: &'a Map<String, Value>,
        ctx: &compiler::Context,
    ) -> CompilationResult<'a> {
        Ok(Box::new(AdditionalPropertiesNotEmptyFalseValidator {
            properties: compile_small_map(ctx, map)?,
            location: ctx.location().join("additionalProperties"),
        }))
    }
}
impl AdditionalPropertiesNotEmptyFalseValidator<BigValidatorsMap> {
    #[inline]
    pub(crate) fn compile<'a>(
        map: &'a Map<String, Value>,
        ctx: &compiler::Context,
    ) -> CompilationResult<'a> {
        Ok(Box::new(AdditionalPropertiesNotEmptyFalseValidator {
            properties: compile_big_map(ctx, map)?,
            location: ctx.location().join("additionalProperties"),
        }))
    }
}
impl<M: PropertiesValidatorsMap> Validate for AdditionalPropertiesNotEmptyFalseValidator<M> {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let mut errors = vec![];
            let mut unexpected = vec![];
            for (property, value) in item {
                if let Some((name, node)) = self.properties.get_key_validator(property) {
                    // When a property is in `properties`, then it should be VALID
                    errors.extend(iter_errors!(node, value, location, name));
                } else {
                    // No extra properties are allowed
                    unexpected.push(property.clone());
                }
            }
            if !unexpected.is_empty() {
                errors.push(ValidationError::additional_properties(
                    self.location.clone(),
                    location.into(),
                    instance,
                    unexpected,
                ));
            }
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(props) = instance {
            are_properties_valid(&self.properties, props, |_| false)
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            for (property, value) in item {
                if let Some((name, node)) = self.properties.get_key_validator(property) {
                    node.validate(value, &location.push(name))?;
                } else {
                    return Err(ValidationError::additional_properties(
                        self.location.clone(),
                        location.into(),
                        instance,
                        vec![property.clone()],
                    ));
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut unexpected = Vec::with_capacity(item.len());
            let mut output = BasicOutput::default();
            for (property, value) in item {
                if let Some((_name, node)) = self.properties.get_key_validator(property) {
                    let path = location.push(property.as_str());
                    output += node.apply_rooted(value, &path);
                } else {
                    unexpected.push(property.clone());
                }
            }
            let mut result: PartialApplication = output.into();
            if !unexpected.is_empty() {
                result.mark_errored(
                    ValidationError::additional_properties(
                        self.location.clone(),
                        location.into(),
                        instance,
                        unexpected,
                    )
                    .into(),
                );
            }
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": {"type": "integer"},
///     "properties": {
///         "foo": {"type": "string"}
///     }
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "foo": "bar",
///     "bar": 6
/// }
/// ```
pub(crate) struct AdditionalPropertiesNotEmptyValidator<M: PropertiesValidatorsMap> {
    node: SchemaNode,
    properties: M,
}
impl AdditionalPropertiesNotEmptyValidator<SmallValidatorsMap> {
    #[inline]
    pub(crate) fn compile<'a>(
        map: &'a Map<String, Value>,
        ctx: &compiler::Context,
        schema: &'a Value,
    ) -> CompilationResult<'a> {
        let kctx = ctx.new_at_location("additionalProperties");
        Ok(Box::new(AdditionalPropertiesNotEmptyValidator {
            properties: compile_small_map(ctx, map)?,
            node: compiler::compile(&kctx, kctx.as_resource_ref(schema))?,
        }))
    }
}
impl AdditionalPropertiesNotEmptyValidator<BigValidatorsMap> {
    #[inline]
    pub(crate) fn compile<'a>(
        map: &'a Map<String, Value>,
        ctx: &compiler::Context,
        schema: &'a Value,
    ) -> CompilationResult<'a> {
        let kctx = ctx.new_at_location("additionalProperties");
        Ok(Box::new(AdditionalPropertiesNotEmptyValidator {
            properties: compile_big_map(ctx, map)?,
            node: compiler::compile(&kctx, kctx.as_resource_ref(schema))?,
        }))
    }
}
impl<M: PropertiesValidatorsMap> Validate for AdditionalPropertiesNotEmptyValidator<M> {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(map) = instance {
            let mut errors = vec![];
            for (property, value) in map {
                if let Some((name, property_validators)) =
                    self.properties.get_key_validator(property)
                {
                    errors.extend(iter_errors!(property_validators, value, location, name));
                } else {
                    errors.extend(iter_errors!(self.node, value, location, property));
                }
            }
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(props) = instance {
            are_properties_valid(&self.properties, props, |instance| {
                self.node.is_valid(instance)
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
        if let Value::Object(props) = instance {
            for (property, instance) in props {
                if let Some(validator) = self.properties.get_validator(property) {
                    validator.validate(instance, &location.push(property))?;
                } else {
                    self.node.validate(instance, &location.push(property))?;
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(map) = instance {
            let mut matched_propnames = Vec::with_capacity(map.len());
            let mut output = BasicOutput::default();
            for (property, value) in map {
                let path = location.push(property.as_str());
                if let Some((_name, property_validators)) =
                    self.properties.get_key_validator(property)
                {
                    output += property_validators.apply_rooted(value, &path);
                } else {
                    output += self.node.apply_rooted(value, &path);
                    matched_propnames.push(property.clone());
                }
            }
            let mut result: PartialApplication = output.into();
            if !matched_propnames.is_empty() {
                result.annotate(Value::from(matched_propnames).into());
            }
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": {"type": "integer"},
///     "patternProperties": {
///         "^x-": {"type": "integer", "minimum": 5},
///         "-x$": {"type": "integer", "maximum": 10}
///     }
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "x-foo": 6,
///     "foo-x": 7,
///     "bar": 8
/// }
/// ```
pub(crate) struct AdditionalPropertiesWithPatternsValidator<R> {
    node: SchemaNode,
    patterns: Vec<(R, SchemaNode)>,
    /// We need this because `compiler::compile` uses the additionalProperties keyword to compile
    /// this validator. That means that the schema node which contains this validator has
    /// "additionalProperties" as it's path. However, we need to produce annotations which have the
    /// patternProperties keyword as their path so we store the paths here.
    pattern_keyword_path: Location,
    pattern_keyword_absolute_location: Option<Uri<String>>,
}

impl<R: RegexEngine> Validate for AdditionalPropertiesWithPatternsValidator<R> {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let mut errors = vec![];
            for (property, value) in item {
                let mut has_match = false;
                errors.extend(
                    self.patterns
                        .iter()
                        .filter(|(re, _)| re.is_match(property).unwrap_or(false))
                        .flat_map(|(_, node)| {
                            has_match = true;
                            iter_errors!(node, value, location, property)
                        }),
                );
                if !has_match {
                    errors.extend(iter_errors!(self.node, value, location, property));
                }
            }
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            for (property, value) in item {
                let mut has_match = false;
                for (re, node) in &self.patterns {
                    if re.is_match(property).unwrap_or(false) {
                        has_match = true;
                        is_valid_pattern_schema!(node, value)
                    }
                }
                if !has_match && !is_valid!(self.node, value) {
                    return false;
                }
            }
        }
        true
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            for (property, value) in item {
                let mut has_match = false;
                for (re, node) in &self.patterns {
                    if re.is_match(property).unwrap_or(false) {
                        has_match = true;
                        node.validate(value, &location.push(property))?;
                    }
                }
                if !has_match {
                    self.node.validate(value, &location.push(property))?;
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut output = BasicOutput::default();
            let mut pattern_matched_propnames = Vec::with_capacity(item.len());
            let mut additional_matched_propnames = Vec::with_capacity(item.len());
            for (property, value) in item {
                let path = location.push(property.as_str());
                let mut has_match = false;
                for (pattern, node) in &self.patterns {
                    if pattern.is_match(property).unwrap_or(false) {
                        has_match = true;
                        pattern_matched_propnames.push(property.clone());
                        output += node.apply_rooted(value, &path);
                    }
                }
                if !has_match {
                    additional_matched_propnames.push(property.clone());
                    output += self.node.apply_rooted(value, &path);
                }
            }
            if !pattern_matched_propnames.is_empty() {
                output += OutputUnit::<Annotations<'_>>::annotations(
                    self.pattern_keyword_path.clone(),
                    location.into(),
                    self.pattern_keyword_absolute_location.clone(),
                    Value::from(pattern_matched_propnames).into(),
                )
                .into();
            }
            let mut result: PartialApplication = output.into();
            if !additional_matched_propnames.is_empty() {
                result.annotate(Value::from(additional_matched_propnames).into());
            }
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": false,
///     "patternProperties": {
///         "^x-": {"type": "integer", "minimum": 5},
///         "-x$": {"type": "integer", "maximum": 10}
///     }
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "x-bar": 6,
///     "spam-x": 7,
///     "x-baz-x": 8,
/// }
/// ```
pub(crate) struct AdditionalPropertiesWithPatternsFalseValidator<R> {
    patterns: Vec<(R, SchemaNode)>,
    location: Location,
    pattern_keyword_path: Location,
    pattern_keyword_absolute_location: Option<Uri<String>>,
}

impl<R: RegexEngine> Validate for AdditionalPropertiesWithPatternsFalseValidator<R> {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let mut errors = vec![];
            let mut unexpected = vec![];
            for (property, value) in item {
                let mut has_match = false;
                errors.extend(
                    self.patterns
                        .iter()
                        .filter(|(re, _)| re.is_match(property).unwrap_or(false))
                        .flat_map(|(_, node)| {
                            has_match = true;
                            iter_errors!(node, value, location, property)
                        }),
                );
                if !has_match {
                    unexpected.push(property.clone());
                }
            }
            if !unexpected.is_empty() {
                errors.push(ValidationError::additional_properties(
                    self.location.clone(),
                    location.into(),
                    instance,
                    unexpected,
                ));
            }
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            // No properties are allowed, except ones defined in `patternProperties`
            for (property, value) in item {
                is_valid_patterns!(&self.patterns, property, value);
            }
        }
        true
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            for (property, value) in item {
                let mut has_match = false;
                for (re, node) in &self.patterns {
                    if re.is_match(property).unwrap_or(false) {
                        has_match = true;
                        node.validate(value, &location.push(property))?;
                    }
                }
                if !has_match {
                    return Err(ValidationError::additional_properties(
                        self.location.clone(),
                        location.into(),
                        instance,
                        vec![property.clone()],
                    ));
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut output = BasicOutput::default();
            let mut unexpected = Vec::with_capacity(item.len());
            let mut pattern_matched_props = Vec::with_capacity(item.len());
            for (property, value) in item {
                let path = location.push(property.as_str());
                let mut has_match = false;
                for (pattern, node) in &self.patterns {
                    if pattern.is_match(property).unwrap_or(false) {
                        has_match = true;
                        pattern_matched_props.push(property.clone());
                        output += node.apply_rooted(value, &path);
                    }
                }
                if !has_match {
                    unexpected.push(property.clone());
                }
            }
            if !pattern_matched_props.is_empty() {
                output += OutputUnit::<Annotations<'_>>::annotations(
                    self.pattern_keyword_path.clone(),
                    location.into(),
                    self.pattern_keyword_absolute_location.clone(),
                    Value::from(pattern_matched_props).into(),
                )
                .into();
            }
            let mut result: PartialApplication = output.into();
            if !unexpected.is_empty() {
                result.mark_errored(
                    ValidationError::additional_properties(
                        self.location.clone(),
                        location.into(),
                        instance,
                        unexpected,
                    )
                    .into(),
                );
            }
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": {"type": "integer"},
///     "properties": {
///         "foo": {"type": "string"}
///     },
///     "patternProperties": {
///         "^x-": {"type": "integer", "minimum": 5},
///         "-x$": {"type": "integer", "maximum": 10}
///     }
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "foo": "a",
///     "x-spam": 6,
///     "spam-x": 7,
///     "x-spam-x": 8,
///     "bar": 42
/// }
/// ```
pub(crate) struct AdditionalPropertiesWithPatternsNotEmptyValidator<M: PropertiesValidatorsMap, R> {
    node: SchemaNode,
    properties: M,
    patterns: Vec<(R, SchemaNode)>,
}

impl<M: PropertiesValidatorsMap, R: RegexEngine> Validate
    for AdditionalPropertiesWithPatternsNotEmptyValidator<M, R>
{
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let mut errors = vec![];
            for (property, value) in item {
                if let Some((name, node)) = self.properties.get_key_validator(property) {
                    errors.extend(iter_errors!(node, value, location, name));
                    errors.extend(
                        self.patterns
                            .iter()
                            .filter(|(re, _)| re.is_match(property).unwrap_or(false))
                            .flat_map(|(_, node)| iter_errors!(node, value, location, name)),
                    );
                } else {
                    let mut has_match = false;
                    errors.extend(
                        self.patterns
                            .iter()
                            .filter(|(re, _)| re.is_match(property).unwrap_or(false))
                            .flat_map(|(_, node)| {
                                has_match = true;
                                iter_errors!(node, value, location, property)
                            }),
                    );
                    if !has_match {
                        errors.extend(iter_errors!(self.node, value, location, property));
                    }
                }
            }
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            for (property, value) in item {
                if let Some(node) = self.properties.get_validator(property) {
                    if is_valid!(node, value) {
                        // Valid for `properties`, check `patternProperties`
                        for (re, node) in &self.patterns {
                            // If there is a match, then the value should match the sub-schema
                            if re.is_match(property).unwrap_or(false) {
                                is_valid_pattern_schema!(node, value)
                            }
                        }
                    } else {
                        // INVALID, no reason to check the next one
                        return false;
                    }
                } else {
                    let mut has_match = false;
                    for (re, node) in &self.patterns {
                        // If there is a match, then the value should match the sub-schema
                        if re.is_match(property).unwrap_or(false) {
                            has_match = true;
                            is_valid_pattern_schema!(node, value)
                        }
                    }
                    if !has_match && !is_valid!(self.node, value) {
                        return false;
                    }
                }
            }
            true
        } else {
            true
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            for (property, value) in item {
                if let Some((name, node)) = self.properties.get_key_validator(property) {
                    node.validate(value, &location.push(name))?;
                    for (re, node) in &self.patterns {
                        if re.is_match(property).unwrap_or(false) {
                            node.validate(value, &location.push(name))?;
                        }
                    }
                } else {
                    let mut has_match = false;
                    for (re, node) in &self.patterns {
                        if re.is_match(property).unwrap_or(false) {
                            has_match = true;
                            node.validate(value, &location.push(property))?;
                        }
                    }

                    if !has_match {
                        self.node.validate(value, &location.push(property))?;
                    }
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut output = BasicOutput::default();
            let mut additional_matches = Vec::with_capacity(item.len());
            for (property, value) in item {
                let path = location.push(property.as_str());
                if let Some((_name, node)) = self.properties.get_key_validator(property) {
                    output += node.apply_rooted(value, &path);
                    for (pattern, node) in &self.patterns {
                        if pattern.is_match(property).unwrap_or(false) {
                            output += node.apply_rooted(value, &path);
                        }
                    }
                } else {
                    let mut has_match = false;
                    for (pattern, node) in &self.patterns {
                        if pattern.is_match(property).unwrap_or(false) {
                            has_match = true;
                            output += node.apply_rooted(value, &path);
                        }
                    }
                    if !has_match {
                        additional_matches.push(property.clone());
                        output += self.node.apply_rooted(value, &path);
                    }
                }
            }
            let mut result: PartialApplication = output.into();
            result.annotate(Value::from(additional_matches).into());
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

/// # Schema example
///
/// ```json
/// {
///     "additionalProperties": false,
///     "properties": {
///         "foo": {"type": "string"}
///     },
///     "patternProperties": {
///         "^x-": {"type": "integer", "minimum": 5},
///         "-x$": {"type": "integer", "maximum": 10}
///     }
/// }
/// ```
///
/// # Valid value
///
/// ```json
/// {
///     "foo": "bar",
///     "x-bar": 6,
///     "spam-x": 7,
///     "x-baz-x": 8,
/// }
/// ```
pub(crate) struct AdditionalPropertiesWithPatternsNotEmptyFalseValidator<
    M: PropertiesValidatorsMap,
    R,
> {
    properties: M,
    patterns: Vec<(R, SchemaNode)>,
    location: Location,
}

impl<M: PropertiesValidatorsMap, R: RegexEngine> Validate
    for AdditionalPropertiesWithPatternsNotEmptyFalseValidator<M, R>
{
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let mut errors = vec![];
            let mut unexpected = vec![];
            // No properties are allowed, except ones defined in `properties` or `patternProperties`
            for (property, value) in item {
                if let Some((name, node)) = self.properties.get_key_validator(property) {
                    errors.extend(iter_errors!(node, value, location, name));
                    errors.extend(
                        self.patterns
                            .iter()
                            .filter(|(re, _)| re.is_match(property).unwrap_or(false))
                            .flat_map(|(_, node)| iter_errors!(node, value, location, name)),
                    );
                } else {
                    let mut has_match = false;
                    errors.extend(
                        self.patterns
                            .iter()
                            .filter(|(re, _)| re.is_match(property).unwrap_or(false))
                            .flat_map(|(_, node)| {
                                has_match = true;
                                iter_errors!(node, value, location, property)
                            }),
                    );
                    if !has_match {
                        unexpected.push(property.clone());
                    }
                }
            }
            if !unexpected.is_empty() {
                errors.push(ValidationError::additional_properties(
                    self.location.clone(),
                    location.into(),
                    instance,
                    unexpected,
                ));
            }
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            // No properties are allowed, except ones defined in `properties` or `patternProperties`
            for (property, value) in item {
                if let Some(node) = self.properties.get_validator(property) {
                    if is_valid!(node, value) {
                        // Valid for `properties`, check `patternProperties`
                        for (re, node) in &self.patterns {
                            // If there is a match, then the value should match the sub-schema
                            if re.is_match(property).unwrap_or(false) {
                                is_valid_pattern_schema!(node, value)
                            }
                        }
                    } else {
                        // INVALID, no reason to check the next one
                        return false;
                    }
                } else {
                    is_valid_patterns!(&self.patterns, property, value);
                }
            }
        }
        true
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if let Value::Object(item) = instance {
            // No properties are allowed, except ones defined in `properties` or `patternProperties`
            for (property, value) in item {
                if let Some((name, node)) = self.properties.get_key_validator(property) {
                    node.validate(value, &location.push(name))?;
                    for (re, node) in &self.patterns {
                        if re.is_match(property).unwrap_or(false) {
                            node.validate(value, &location.push(name))?;
                        }
                    }
                } else {
                    let mut has_match = false;
                    for (re, node) in &self.patterns {
                        if re.is_match(property).unwrap_or(false) {
                            has_match = true;
                            node.validate(value, &location.push(property))?;
                        }
                    }
                    if !has_match {
                        return Err(ValidationError::additional_properties(
                            self.location.clone(),
                            location.into(),
                            instance,
                            vec![property.clone()],
                        ));
                    }
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut output = BasicOutput::default();
            let mut unexpected = vec![];
            // No properties are allowed, except ones defined in `properties` or `patternProperties`
            for (property, value) in item {
                let path = location.push(property.as_str());
                if let Some((_name, node)) = self.properties.get_key_validator(property) {
                    output += node.apply_rooted(value, &path);
                    for (pattern, node) in &self.patterns {
                        if pattern.is_match(property).unwrap_or(false) {
                            output += node.apply_rooted(value, &path);
                        }
                    }
                } else {
                    let mut has_match = false;
                    for (pattern, node) in &self.patterns {
                        if pattern.is_match(property).unwrap_or(false) {
                            has_match = true;
                            output += node.apply_rooted(value, &path);
                        }
                    }
                    if !has_match {
                        unexpected.push(property.clone());
                    }
                }
            }
            let mut result: PartialApplication = output.into();
            if !unexpected.is_empty() {
                result.mark_errored(
                    ValidationError::additional_properties(
                        self.location.clone(),
                        location.into(),
                        instance,
                        unexpected,
                    )
                    .into(),
                );
            }
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

macro_rules! try_compile {
    ($expr:expr) => {
        match $expr {
            Ok(result) => result,
            Err(error) => return Some(Err(error)),
        }
    };
}

fn compile_pattern_non_empty<'a, R>(
    ctx: &compiler::Context,
    map: &'a Map<String, Value>,
    patterns: Vec<(R, SchemaNode)>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>>
where
    R: RegexEngine + 'static,
{
    let kctx = ctx.new_at_location("additionalProperties");
    if map.len() < 40 {
        Some(Ok(Box::new(
            AdditionalPropertiesWithPatternsNotEmptyValidator::<SmallValidatorsMap, R> {
                node: try_compile!(compiler::compile(&kctx, kctx.as_resource_ref(schema))),
                properties: try_compile!(compile_small_map(ctx, map)),
                patterns,
            },
        )))
    } else {
        Some(Ok(Box::new(
            AdditionalPropertiesWithPatternsNotEmptyValidator::<BigValidatorsMap, R> {
                node: try_compile!(compiler::compile(&kctx, kctx.as_resource_ref(schema))),
                properties: try_compile!(compile_big_map(ctx, map)),
                patterns,
            },
        )))
    }
}

fn compile_pattern_non_empty_false<'a, R>(
    ctx: &compiler::Context,
    map: &'a Map<String, Value>,
    patterns: Vec<(R, SchemaNode)>,
) -> Option<CompilationResult<'a>>
where
    R: RegexEngine + 'static,
{
    let kctx = ctx.new_at_location("additionalProperties");
    if map.len() < 40 {
        Some(Ok(Box::new(
            AdditionalPropertiesWithPatternsNotEmptyFalseValidator::<SmallValidatorsMap, R> {
                properties: try_compile!(compile_small_map(ctx, map)),
                patterns,
                location: kctx.location().clone(),
            },
        )))
    } else {
        Some(Ok(Box::new(
            AdditionalPropertiesWithPatternsNotEmptyFalseValidator::<BigValidatorsMap, R> {
                properties: try_compile!(compile_big_map(ctx, map)),
                patterns,
                location: kctx.location().clone(),
            },
        )))
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    parent: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    let properties = parent.get("properties");
    if let Some(patterns) = parent.get("patternProperties") {
        if let Value::Object(obj) = patterns {
            // Compile all patterns & their validators to avoid doing work in the `patternProperties` validator
            match ctx.config().pattern_options() {
                PatternEngineOptions::FancyRegex {
                    backtrack_limit,
                    size_limit,
                    dfa_size_limit,
                } => {
                    let patterns = match compile_fancy_regex_patterns(
                        ctx,
                        obj,
                        backtrack_limit,
                        size_limit,
                        dfa_size_limit,
                    ) {
                        Ok(patterns) => patterns,
                        Err(error) => return Some(Err(error)),
                    };
                    match schema {
                        Value::Bool(true) => None, // "additionalProperties" are "true" by default
                        Value::Bool(false) => {
                            if let Some(properties) = properties {
                                if let Value::Object(map) = properties {
                                    compile_pattern_non_empty_false::<fancy_regex::Regex>(
                                        ctx, map, patterns,
                                    )
                                } else {
                                    Some(Err(ValidationError::custom(
                                        Location::new(),
                                        Location::new(),
                                        properties,
                                        "Unexpected type",
                                    )))
                                }
                            } else {
                                Some(Ok(Box::new(
                                    AdditionalPropertiesWithPatternsFalseValidator {
                                        patterns,
                                        location: ctx.location().join("additionalProperties"),
                                        pattern_keyword_path: ctx
                                            .location()
                                            .join("patternProperties"),
                                        pattern_keyword_absolute_location: ctx
                                            .new_at_location("patternProperties")
                                            .base_uri(),
                                    },
                                )))
                            }
                        }
                        _ => {
                            if let Some(properties) = properties {
                                if let Value::Object(map) = properties {
                                    compile_pattern_non_empty::<fancy_regex::Regex>(
                                        ctx, map, patterns, schema,
                                    )
                                } else {
                                    Some(Err(ValidationError::custom(
                                        Location::new(),
                                        Location::new(),
                                        properties,
                                        "Unexpected type",
                                    )))
                                }
                            } else {
                                let kctx = ctx.new_at_location("additionalProperties");
                                Some(Ok(Box::new(AdditionalPropertiesWithPatternsValidator {
                                    node: try_compile!(compiler::compile(
                                        &kctx,
                                        kctx.as_resource_ref(schema),
                                    )),
                                    patterns,
                                    pattern_keyword_path: ctx.location().join("patternProperties"),
                                    pattern_keyword_absolute_location: ctx
                                        .new_at_location("patternProperties")
                                        .base_uri(),
                                })))
                            }
                        }
                    }
                }
                PatternEngineOptions::Regex {
                    size_limit,
                    dfa_size_limit,
                } => {
                    let patterns =
                        match compile_regex_patterns(ctx, obj, size_limit, dfa_size_limit) {
                            Ok(patterns) => patterns,
                            Err(error) => return Some(Err(error)),
                        };
                    match schema {
                        Value::Bool(true) => None, // "additionalProperties" are "true" by default
                        Value::Bool(false) => {
                            if let Some(properties) = properties {
                                if let Value::Object(map) = properties {
                                    compile_pattern_non_empty_false::<regex::Regex>(
                                        ctx, map, patterns,
                                    )
                                } else {
                                    Some(Err(ValidationError::custom(
                                        Location::new(),
                                        Location::new(),
                                        properties,
                                        "Unexpected type",
                                    )))
                                }
                            } else {
                                Some(Ok(Box::new(
                                    AdditionalPropertiesWithPatternsFalseValidator {
                                        patterns,
                                        location: ctx.location().join("additionalProperties"),
                                        pattern_keyword_path: ctx
                                            .location()
                                            .join("patternProperties"),
                                        pattern_keyword_absolute_location: ctx
                                            .new_at_location("patternProperties")
                                            .base_uri(),
                                    },
                                )))
                            }
                        }
                        _ => {
                            if let Some(properties) = properties {
                                if let Value::Object(map) = properties {
                                    compile_pattern_non_empty::<regex::Regex>(
                                        ctx, map, patterns, schema,
                                    )
                                } else {
                                    Some(Err(ValidationError::custom(
                                        Location::new(),
                                        Location::new(),
                                        properties,
                                        "Unexpected type",
                                    )))
                                }
                            } else {
                                let kctx = ctx.new_at_location("additionalProperties");
                                Some(Ok(Box::new(AdditionalPropertiesWithPatternsValidator {
                                    node: try_compile!(compiler::compile(
                                        &kctx,
                                        kctx.as_resource_ref(schema),
                                    )),
                                    patterns,
                                    pattern_keyword_path: ctx.location().join("patternProperties"),
                                    pattern_keyword_absolute_location: ctx
                                        .new_at_location("patternProperties")
                                        .base_uri(),
                                })))
                            }
                        }
                    }
                }
            }
        } else {
            Some(Err(ValidationError::single_type_error(
                Location::new(),
                ctx.location().clone(),
                schema,
                JsonType::Object,
            )))
        }
    } else {
        match schema {
            Value::Bool(true) => None, // "additionalProperties" are "true" by default
            Value::Bool(false) => {
                if let Some(properties) = properties {
                    compile_dynamic_prop_map_validator!(
                        AdditionalPropertiesNotEmptyFalseValidator,
                        properties,
                        ctx,
                    )
                } else {
                    let location = ctx.location().join("additionalProperties");
                    Some(AdditionalPropertiesFalseValidator::compile(location))
                }
            }
            _ => {
                if let Some(properties) = properties {
                    compile_dynamic_prop_map_validator!(
                        AdditionalPropertiesNotEmptyValidator,
                        properties,
                        ctx,
                        schema,
                    )
                } else {
                    Some(AdditionalPropertiesValidator::compile(schema, ctx))
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    fn schema_1() -> Value {
        // For `AdditionalPropertiesWithPatternsNotEmptyFalseValidator`
        json!({
            "additionalProperties": false,
            "properties": {
                "foo": {"type": "string"},
                "barbaz": {"type": "integer", "multipleOf": 3},
            },
            "patternProperties": {
                "^bar": {"type": "integer", "minimum": 5},
                "spam$": {"type": "integer", "maximum": 10},
            }
        })
    }

    // Another type
    #[test_case(&json!([1]))]
    // The right type
    #[test_case(&json!({}))]
    // Match `properties.foo`
    #[test_case(&json!({"foo": "a"}))]
    // Match `properties.barbaz` & `patternProperties.^bar`
    #[test_case(&json!({"barbaz": 6}))]
    // Match `patternProperties.^bar`
    #[test_case(&json!({"bar": 6}))]
    // Match `patternProperties.spam$`
    #[test_case(&json!({"spam": 7}))]
    // All `patternProperties` rules match on different values
    #[test_case(&json!({"bar": 6, "spam": 7}))]
    // All `patternProperties` rules match on the same value
    #[test_case(&json!({"barspam": 7}))]
    // All combined
    #[test_case(&json!({"barspam": 7, "bar": 6, "spam": 7, "foo": "a", "barbaz": 6}))]
    fn schema_1_valid(instance: &Value) {
        let schema = schema_1();
        tests_util::is_valid(&schema, instance);
    }

    // `properties.foo` - should be a string
    #[test_case(&json!({"foo": 3}), &["3 is not of type \"string\""], &["/properties/foo/type"])]
    // `additionalProperties` - extra keyword & not in `properties` / `patternProperties`
    #[test_case(&json!({"faz": 1}), &["Additional properties are not allowed (\'faz\' was unexpected)"], &["/additionalProperties"])]
    #[test_case(&json!({"faz": 1, "haz": 1}), &["Additional properties are not allowed (\'faz\', \'haz\' were unexpected)"], &["/additionalProperties"])]
    // `properties.foo` - should be a string & `patternProperties.^bar` - invalid
    #[test_case(&json!({"foo": 3, "bar": 4}), &["4 is less than the minimum of 5", "3 is not of type \"string\""], &["/patternProperties/^bar/minimum", "/properties/foo/type"])]
    // `properties.barbaz` - valid; `patternProperties.^bar` - invalid
    #[test_case(&json!({"barbaz": 3}), &["3 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.^bar` (should be >=5)
    #[test_case(&json!({"bar": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` (should be <=10)
    #[test_case(&json!({"spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - both values are invalid
    #[test_case(&json!({"bar": 4, "spam": 11}), &["4 is less than the minimum of 5", "11 is greater than the maximum of 10"], &["/patternProperties/^bar/minimum", "/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is valid, `spam` is invalid
    #[test_case(&json!({"bar": 6, "spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is invalid, `spam` is valid
    #[test_case(&json!({"bar": 4, "spam": 8}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.^bar` - (should be >=5), but valid for `patternProperties.spam$`
    #[test_case(&json!({"barspam": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` - (should be <=10), but valid for `patternProperties.^bar`
    #[test_case(&json!({"barspam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // All combined
    #[test_case(
      &json!({"bar": 4, "spam": 11, "foo": 3, "faz": 1}),
      &[
          "4 is less than the minimum of 5",
          "3 is not of type \"string\"",
          "11 is greater than the maximum of 10",
          "Additional properties are not allowed (\'faz\' was unexpected)"
      ],
      &[
          "/patternProperties/^bar/minimum",
          "/properties/foo/type",
          "/patternProperties/spam$/maximum",
          "/additionalProperties"
      ]
    )]
    fn schema_1_invalid(instance: &Value, expected: &[&str], locations: &[&str]) {
        let schema = schema_1();
        tests_util::is_not_valid(&schema, instance);
        tests_util::expect_errors(&schema, instance, expected);
        tests_util::assert_locations(&schema, instance, locations);
    }

    fn schema_2() -> Value {
        // For `AdditionalPropertiesWithPatternsFalseValidator`
        json!({
            "additionalProperties": false,
            "patternProperties": {
                "^bar": {"type": "integer", "minimum": 5},
                "spam$": {"type": "integer", "maximum": 10},
            }
        })
    }

    // Another type
    #[test_case(&json!([1]))]
    // The right type
    #[test_case(&json!({}))]
    // Match `patternProperties.^bar`
    #[test_case(&json!({"bar": 6}))]
    // Match `patternProperties.spam$`
    #[test_case(&json!({"spam": 7}))]
    // All `patternProperties` rules match on different values
    #[test_case(&json!({"bar": 6, "spam": 7}))]
    // All `patternProperties` rules match on the same value
    #[test_case(&json!({"barspam": 7}))]
    // All combined
    #[test_case(&json!({"barspam": 7, "bar": 6, "spam": 7}))]
    fn schema_2_valid(instance: &Value) {
        let schema = schema_2();
        tests_util::is_valid(&schema, instance);
    }

    // `additionalProperties` - extra keyword & not in `patternProperties`
    #[test_case(&json!({"faz": "a"}), &["Additional properties are not allowed (\'faz\' was unexpected)"], &["/additionalProperties"])]
    // `patternProperties.^bar` (should be >=5)
    #[test_case(&json!({"bar": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` (should be <=10)
    #[test_case(&json!({"spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - both values are invalid
    #[test_case(&json!({"bar": 4, "spam": 11}), &["4 is less than the minimum of 5", "11 is greater than the maximum of 10"], &["/patternProperties/^bar/minimum", "/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is valid, `spam` is invalid
    #[test_case(&json!({"bar": 6, "spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is invalid, `spam` is valid
    #[test_case(&json!({"bar": 4, "spam": 8}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.^bar` - (should be >=5), but valid for `patternProperties.spam$`
    #[test_case(&json!({"barspam": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` - (should be <=10), but valid for `patternProperties.^bar`
    #[test_case(&json!({"barspam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // All combined
    #[test_case(
      &json!({"bar": 4, "spam": 11, "faz": 1}),
      &[
          "4 is less than the minimum of 5",
          "11 is greater than the maximum of 10",
          "Additional properties are not allowed (\'faz\' was unexpected)"
      ],
      &[
          "/patternProperties/^bar/minimum",
          "/patternProperties/spam$/maximum",
          "/additionalProperties"
      ]
    )]
    fn schema_2_invalid(instance: &Value, expected: &[&str], locations: &[&str]) {
        let schema = schema_2();
        tests_util::is_not_valid(&schema, instance);
        tests_util::expect_errors(&schema, instance, expected);
        tests_util::assert_locations(&schema, instance, locations);
    }

    fn schema_3() -> Value {
        // For `AdditionalPropertiesNotEmptyFalseValidator`
        json!({
            "additionalProperties": false,
            "properties": {
                "foo": {"type": "string"}
            }
        })
    }

    // Another type
    #[test_case(&json!([1]))]
    // The right type
    #[test_case(&json!({}))]
    // Match `properties`
    #[test_case(&json!({"foo": "a"}))]
    fn schema_3_valid(instance: &Value) {
        let schema = schema_3();
        tests_util::is_valid(&schema, instance);
    }

    // `properties` - should be a string
    #[test_case(&json!({"foo": 3}), &["3 is not of type \"string\""], &["/properties/foo/type"])]
    // `additionalProperties` - extra keyword & not in `properties`
    #[test_case(&json!({"faz": "a"}), &["Additional properties are not allowed (\'faz\' was unexpected)"], &["/additionalProperties"])]
    // All combined
    #[test_case(
      &json!(
        {"foo": 3, "faz": "a"}),
        &[
            "3 is not of type \"string\"",
            "Additional properties are not allowed (\'faz\' was unexpected)",
        ],
        &[
            "/properties/foo/type",
            "/additionalProperties",
        ]
    )]
    fn schema_3_invalid(instance: &Value, expected: &[&str], locations: &[&str]) {
        let schema = schema_3();
        tests_util::is_not_valid(&schema, instance);
        tests_util::expect_errors(&schema, instance, expected);
        tests_util::assert_locations(&schema, instance, locations);
    }

    fn schema_4() -> Value {
        // For `AdditionalPropertiesNotEmptyValidator`
        json!({
            "additionalProperties": {"type": "integer"},
            "properties": {
                "foo": {"type": "string"}
            }
        })
    }

    // Another type
    #[test_case(&json!([1]))]
    // The right type
    #[test_case(&json!({}))]
    // Match `properties`
    #[test_case(&json!({"foo": "a"}))]
    // Match `additionalProperties`
    #[test_case(&json!({"bar": 4}))]
    // All combined
    #[test_case(&json!({"foo": "a", "bar": 4}))]
    fn schema_4_valid(instance: &Value) {
        let schema = schema_4();
        tests_util::is_valid(&schema, instance);
    }

    // `properties` - should be a string
    #[test_case(&json!({"foo": 3}), &["3 is not of type \"string\""], &["/properties/foo/type"])]
    // `additionalProperties` - should be an integer
    #[test_case(&json!({"bar": "a"}), &["\"a\" is not of type \"integer\""], &["/additionalProperties/type"])]
    // All combined
    #[test_case(
      &json!(
        {"foo": 3, "bar": "a"}),
        &[
            "\"a\" is not of type \"integer\"",
            "3 is not of type \"string\""
        ],
        &[
            "/additionalProperties/type",
            "/properties/foo/type",
        ]
    )]
    fn schema_4_invalid(instance: &Value, expected: &[&str], locations: &[&str]) {
        let schema = schema_4();
        tests_util::is_not_valid(&schema, instance);
        tests_util::expect_errors(&schema, instance, expected);
        tests_util::assert_locations(&schema, instance, locations);
    }

    fn schema_5() -> Value {
        // For `AdditionalPropertiesWithPatternsNotEmptyValidator`
        json!({
            "additionalProperties": {"type": "integer"},
            "properties": {
                "foo": {"type": "string"},
                "barbaz": {"type": "integer", "multipleOf": 3},
            },
            "patternProperties": {
                "^bar": {"type": "integer", "minimum": 5},
                "spam$": {"type": "integer", "maximum": 10},
            }
        })
    }

    // Another type
    #[test_case(&json!([1]))]
    // The right type
    #[test_case(&json!({}))]
    // Match `properties.foo`
    #[test_case(&json!({"foo": "a"}))]
    // Match `additionalProperties`
    #[test_case(&json!({"faz": 42}))]
    // Match `properties.barbaz` & `patternProperties.^bar`
    #[test_case(&json!({"barbaz": 6}))]
    // Match `patternProperties.^bar`
    #[test_case(&json!({"bar": 6}))]
    // Match `patternProperties.spam$`
    #[test_case(&json!({"spam": 7}))]
    // All `patternProperties` rules match on different values
    #[test_case(&json!({"bar": 6, "spam": 7}))]
    // All `patternProperties` rules match on the same value
    #[test_case(&json!({"barspam": 7}))]
    // All combined
    #[test_case(&json!({"barspam": 7, "bar": 6, "spam": 7, "foo": "a", "barbaz": 6, "faz": 42}))]
    fn schema_5_valid(instance: &Value) {
        let schema = schema_5();
        tests_util::is_valid(&schema, instance);
    }

    // `properties.bar` - should be a string
    #[test_case(&json!({"foo": 3}), &["3 is not of type \"string\""], &["/properties/foo/type"])]
    // `additionalProperties` - extra keyword that doesn't match `additionalProperties`
    #[test_case(&json!({"faz": "a"}), &["\"a\" is not of type \"integer\""], &["/additionalProperties/type"])]
    #[test_case(&json!({"faz": "a", "haz": "a"}), &["\"a\" is not of type \"integer\"", "\"a\" is not of type \"integer\""], &["/additionalProperties/type", "/additionalProperties/type"])]
    // `properties.foo` - should be a string & `patternProperties.^bar` - invalid
    #[test_case(&json!({"foo": 3, "bar": 4}), &["4 is less than the minimum of 5", "3 is not of type \"string\""], &["/patternProperties/^bar/minimum", "/properties/foo/type"])]
    // `properties.barbaz` - valid; `patternProperties.^bar` - invalid
    #[test_case(&json!({"barbaz": 3}), &["3 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.^bar` (should be >=5)
    #[test_case(&json!({"bar": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` (should be <=10)
    #[test_case(&json!({"spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - both values are invalid
    #[test_case(&json!({"bar": 4, "spam": 11}), &["4 is less than the minimum of 5", "11 is greater than the maximum of 10"], &["/patternProperties/^bar/minimum", "/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is valid, `spam` is invalid
    #[test_case(&json!({"bar": 6, "spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is invalid, `spam` is valid
    #[test_case(&json!({"bar": 4, "spam": 8}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.^bar` - (should be >=5), but valid for `patternProperties.spam$`
    #[test_case(&json!({"barspam": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` - (should be <=10), but valid for `patternProperties.^bar`
    #[test_case(&json!({"barspam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // All combined + valid via `additionalProperties`
    #[test_case(
      &json!({"bar": 4, "spam": 11, "foo": 3, "faz": "a", "fam": 42}),
      &[
          "4 is less than the minimum of 5",
          "\"a\" is not of type \"integer\"",
          "3 is not of type \"string\"",
          "11 is greater than the maximum of 10",
      ],
      &[
          "/patternProperties/^bar/minimum",
          "/additionalProperties/type",
          "/properties/foo/type",
          "/patternProperties/spam$/maximum",
      ]
    )]
    fn schema_5_invalid(instance: &Value, expected: &[&str], locations: &[&str]) {
        let schema = schema_5();
        tests_util::is_not_valid(&schema, instance);
        tests_util::expect_errors(&schema, instance, expected);
        tests_util::assert_locations(&schema, instance, locations);
    }

    fn schema_6() -> Value {
        // For `AdditionalPropertiesWithPatternsValidator`
        json!({
            "additionalProperties": {"type": "integer"},
            "patternProperties": {
                "^bar": {"type": "integer", "minimum": 5},
                "spam$": {"type": "integer", "maximum": 10},
            }
        })
    }

    // Another type
    #[test_case(&json!([1]))]
    // The right type
    #[test_case(&json!({}))]
    // Match `additionalProperties`
    #[test_case(&json!({"faz": 42}))]
    // Match `patternProperties.^bar`
    #[test_case(&json!({"bar": 6}))]
    // Match `patternProperties.spam$`
    #[test_case(&json!({"spam": 7}))]
    // All `patternProperties` rules match on different values
    #[test_case(&json!({"bar": 6, "spam": 7}))]
    // All `patternProperties` rules match on the same value
    #[test_case(&json!({"barspam": 7}))]
    // All combined
    #[test_case(&json!({"barspam": 7, "bar": 6, "spam": 7, "faz": 42}))]
    fn schema_6_valid(instance: &Value) {
        let schema = schema_6();
        tests_util::is_valid(&schema, instance);
    }

    // `additionalProperties` - extra keyword that doesn't match `additionalProperties`
    #[test_case(&json!({"faz": "a"}), &["\"a\" is not of type \"integer\""], &["/additionalProperties/type"])]
    #[test_case(&json!({"faz": "a", "haz": "a"}), &["\"a\" is not of type \"integer\"", "\"a\" is not of type \"integer\""], &["/additionalProperties/type", "/additionalProperties/type"])]
    // `additionalProperties` - should be an integer & `patternProperties.^bar` - invalid
    #[test_case(&json!({"foo": "a", "bar": 4}), &["4 is less than the minimum of 5", "\"a\" is not of type \"integer\""], &["/patternProperties/^bar/minimum", "/additionalProperties/type"])]
    // `patternProperties.^bar` (should be >=5)
    #[test_case(&json!({"bar": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` (should be <=10)
    #[test_case(&json!({"spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - both values are invalid
    #[test_case(&json!({"bar": 4, "spam": 11}), &["4 is less than the minimum of 5", "11 is greater than the maximum of 10"], &["/patternProperties/^bar/minimum", "/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is valid, `spam` is invalid
    #[test_case(&json!({"bar": 6, "spam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // `patternProperties` - `bar` is invalid, `spam` is valid
    #[test_case(&json!({"bar": 4, "spam": 8}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.^bar` - (should be >=5), but valid for `patternProperties.spam$`
    #[test_case(&json!({"barspam": 4}), &["4 is less than the minimum of 5"], &["/patternProperties/^bar/minimum"])]
    // `patternProperties.spam$` - (should be <=10), but valid for `patternProperties.^bar`
    #[test_case(&json!({"barspam": 11}), &["11 is greater than the maximum of 10"], &["/patternProperties/spam$/maximum"])]
    // All combined + valid via `additionalProperties`
    #[test_case(
      &json!({"bar": 4, "spam": 11, "faz": "a", "fam": 42}),
      &[
          "4 is less than the minimum of 5",
          "\"a\" is not of type \"integer\"",
          "11 is greater than the maximum of 10",
      ],
      &[
          "/patternProperties/^bar/minimum",
          "/additionalProperties/type",
          "/patternProperties/spam$/maximum",
      ]
    )]
    fn schema_6_invalid(instance: &Value, expected: &[&str], locations: &[&str]) {
        let schema = schema_6();
        tests_util::is_not_valid(&schema, instance);
        tests_util::expect_errors(&schema, instance, expected);
        tests_util::assert_locations(&schema, instance, locations);
    }
}
