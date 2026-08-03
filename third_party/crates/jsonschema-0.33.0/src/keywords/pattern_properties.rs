use crate::{
    compiler, ecma,
    error::{no_error, ErrorIterator, ValidationError},
    keywords::CompilationResult,
    node::SchemaNode,
    options::PatternEngineOptions,
    output::BasicOutput,
    paths::{LazyLocation, Location},
    regex::{build_fancy_regex, build_regex, RegexEngine},
    types::JsonType,
    validator::{PartialApplication, Validate},
};
use serde_json::{Map, Value};

pub(crate) struct PatternPropertiesValidator<R> {
    patterns: Vec<(R, SchemaNode)>,
}

impl<R: RegexEngine> Validate for PatternPropertiesValidator<R> {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let errors: Vec<_> = self
                .patterns
                .iter()
                .flat_map(move |(re, node)| {
                    item.iter()
                        .filter(move |(key, _)| re.is_match(key).unwrap_or(false))
                        .flat_map(move |(key, value)| {
                            let location = location.push(key.as_str());
                            node.iter_errors(value, &location)
                        })
                })
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            self.patterns.iter().all(move |(re, node)| {
                item.iter()
                    .filter(move |(key, _)| re.is_match(key).unwrap_or(false))
                    .all(move |(_key, value)| node.is_valid(value))
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
        if let Value::Object(item) = instance {
            for (re, node) in &self.patterns {
                for (key, value) in item {
                    if re.is_match(key).unwrap_or(false) {
                        node.validate(value, &location.push(key))?;
                    }
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut matched_propnames = Vec::with_capacity(item.len());
            let mut sub_results = BasicOutput::default();
            for (pattern, node) in &self.patterns {
                for (key, value) in item {
                    if pattern.is_match(key).unwrap_or(false) {
                        let path = location.push(key.as_str());
                        matched_propnames.push(key.clone());
                        sub_results += node.apply_rooted(value, &path);
                    }
                }
            }
            let mut result: PartialApplication = sub_results.into();
            result.annotate(Value::from(matched_propnames).into());
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

pub(crate) struct SingleValuePatternPropertiesValidator<R> {
    regex: R,
    node: SchemaNode,
}

impl<R: RegexEngine> Validate for SingleValuePatternPropertiesValidator<R> {
    #[allow(clippy::needless_collect)]
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        if let Value::Object(item) = instance {
            let errors: Vec<_> = item
                .iter()
                .filter(move |(key, _)| self.regex.is_match(key).unwrap_or(false))
                .flat_map(move |(key, value)| {
                    let instance_path = location.push(key.as_str());
                    self.node.iter_errors(value, &instance_path)
                })
                .collect();
            Box::new(errors.into_iter())
        } else {
            no_error()
        }
    }

    fn is_valid(&self, instance: &Value) -> bool {
        if let Value::Object(item) = instance {
            item.iter()
                .filter(move |(key, _)| self.regex.is_match(key).unwrap_or(false))
                .all(move |(_key, value)| self.node.is_valid(value))
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
            for (key, value) in item {
                if self.regex.is_match(key).unwrap_or(false) {
                    self.node.validate(value, &location.push(key))?;
                }
            }
        }
        Ok(())
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        if let Value::Object(item) = instance {
            let mut matched_propnames = Vec::with_capacity(item.len());
            let mut outputs = BasicOutput::default();
            for (key, value) in item {
                if self.regex.is_match(key).unwrap_or(false) {
                    let path = location.push(key.as_str());
                    matched_propnames.push(key.clone());
                    outputs += self.node.apply_rooted(value, &path);
                }
            }
            let mut result: PartialApplication = outputs.into();
            result.annotate(Value::from(matched_propnames).into());
            result
        } else {
            PartialApplication::valid_empty()
        }
    }
}

#[inline]
pub(crate) fn compile<'a>(
    ctx: &compiler::Context,
    parent: &'a Map<String, Value>,
    schema: &'a Value,
) -> Option<CompilationResult<'a>> {
    match parent.get("additionalProperties") {
        // This type of `additionalProperties` validator handles `patternProperties` logic
        Some(Value::Bool(false) | Value::Object(_)) => None,
        _ => {
            if let Value::Object(map) = schema {
                if map.len() == 1 {
                    let (key, value) = map.iter().next().expect("Map is not empty");
                    let kctx = ctx.new_at_location("patternProperties");
                    let pctx = kctx.new_at_location(key);
                    match ctx.config().pattern_options() {
                        PatternEngineOptions::FancyRegex {
                            backtrack_limit,
                            size_limit,
                            dfa_size_limit,
                        } => Some(Ok(Box::new(SingleValuePatternPropertiesValidator {
                            regex: {
                                match ecma::to_rust_regex(key).map(|pattern| {
                                    build_fancy_regex(
                                        &pattern,
                                        backtrack_limit,
                                        size_limit,
                                        dfa_size_limit,
                                    )
                                }) {
                                    Ok(Ok(r)) => r,
                                    _ => {
                                        return Some(Err(invalid_regex(&kctx, schema)));
                                    }
                                }
                            },
                            node: match compiler::compile(&pctx, pctx.as_resource_ref(value)) {
                                Ok(node) => node,
                                Err(error) => return Some(Err(error)),
                            },
                        }))),
                        PatternEngineOptions::Regex {
                            size_limit,
                            dfa_size_limit,
                        } => Some(Ok(Box::new(SingleValuePatternPropertiesValidator {
                            regex: {
                                match ecma::to_rust_regex(key).map(|pattern| {
                                    build_regex(&pattern, size_limit, dfa_size_limit)
                                }) {
                                    Ok(Ok(r)) => r,
                                    _ => {
                                        return Some(Err(invalid_regex(&kctx, schema)));
                                    }
                                }
                            },
                            node: match compiler::compile(&pctx, pctx.as_resource_ref(value)) {
                                Ok(node) => node,
                                Err(error) => return Some(Err(error)),
                            },
                        }))),
                    }
                } else {
                    let ctx = ctx.new_at_location("patternProperties");
                    match ctx.config().pattern_options() {
                        PatternEngineOptions::FancyRegex {
                            backtrack_limit,
                            size_limit,
                            dfa_size_limit,
                        } => {
                            let mut patterns = Vec::with_capacity(map.len());
                            for (pattern, subschema) in map {
                                let pctx = ctx.new_at_location(pattern.as_str());
                                patterns.push((
                                    match ecma::to_rust_regex(pattern).map(|pattern| {
                                        build_fancy_regex(
                                            &pattern,
                                            backtrack_limit,
                                            size_limit,
                                            dfa_size_limit,
                                        )
                                    }) {
                                        Ok(Ok(r)) => r,
                                        _ => return Some(Err(invalid_regex(&ctx, subschema))),
                                    },
                                    match compiler::compile(&pctx, pctx.as_resource_ref(subschema))
                                    {
                                        Ok(node) => node,
                                        Err(error) => return Some(Err(error)),
                                    },
                                ));
                            }
                            Some(Ok(Box::new(PatternPropertiesValidator { patterns })))
                        }
                        PatternEngineOptions::Regex {
                            size_limit,
                            dfa_size_limit,
                        } => {
                            let mut patterns = Vec::with_capacity(map.len());
                            for (pattern, subschema) in map {
                                let pctx = ctx.new_at_location(pattern.as_str());
                                patterns.push((
                                    match ecma::to_rust_regex(pattern).map(|pattern| {
                                        build_regex(&pattern, size_limit, dfa_size_limit)
                                    }) {
                                        Ok(Ok(r)) => r,
                                        _ => return Some(Err(invalid_regex(&ctx, subschema))),
                                    },
                                    match compiler::compile(&pctx, pctx.as_resource_ref(subschema))
                                    {
                                        Ok(node) => node,
                                        Err(error) => return Some(Err(error)),
                                    },
                                ));
                            }
                            Some(Ok(Box::new(PatternPropertiesValidator { patterns })))
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
        }
    }
}

fn invalid_regex<'a>(ctx: &compiler::Context, schema: &'a Value) -> ValidationError<'a> {
    ValidationError::format(Location::new(), ctx.location().clone(), schema, "regex")
}

#[cfg(test)]
mod tests {
    use crate::tests_util;
    use serde_json::{json, Value};
    use test_case::test_case;

    #[test_case(&json!({"patternProperties": {"^f": {"type": "string"}}}), &json!({"f": 42}), "/patternProperties/^f/type")]
    #[test_case(&json!({"patternProperties": {"^f": {"type": "string"}, "^x": {"type": "string"}}}), &json!({"f": 42}), "/patternProperties/^f/type")]
    fn location(schema: &Value, instance: &Value, expected: &str) {
        tests_util::assert_schema_location(schema, instance, expected);
    }
}
