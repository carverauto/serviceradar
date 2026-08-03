use crate::{
    compiler::Context,
    error::ErrorIterator,
    keywords::{BoxedValidator, Keyword},
    output::{Annotations, BasicOutput, ErrorDescription, OutputUnit},
    paths::{LazyLocation, Location, LocationSegment},
    validator::{PartialApplication, Validate},
    ValidationError,
};
use ahash::AHashMap;
use referencing::{uri, Uri};
use serde_json::Value;
use std::{cell::OnceCell, collections::VecDeque, fmt};

/// A node in the schema tree, returned by [`compiler::compile`]
#[derive(Debug)]
pub(crate) struct SchemaNode {
    validators: NodeValidators,
    location: Location,
    absolute_path: Option<Uri<String>>,
}

enum NodeValidators {
    /// The result of compiling a boolean valued schema, e.g
    ///
    /// ```json
    /// {
    ///     "additionalProperties": false
    /// }
    /// ```
    ///
    /// Here the result of `compiler::compile` called with the `false` value will return a
    /// `SchemaNode` with a single `BooleanValidator` as it's `validators`.
    Boolean { validator: Option<BoxedValidator> },
    /// The result of compiling a schema which is composed of keywords (almost all schemas)
    Keyword(KeywordValidators),
    /// The result of compiling a schema which is "array valued", e.g the "dependencies" keyword of
    /// draft 7 which can take values which are an array of other property names
    Array { validators: Vec<BoxedValidator> },
}

impl fmt::Debug for NodeValidators {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Boolean { .. } => f.debug_struct("Boolean").finish(),
            Self::Keyword(_) => f.debug_tuple("Keyword").finish(),
            Self::Array { .. } => f.debug_struct("Array").finish(),
        }
    }
}

struct KeywordValidators {
    /// The keywords on this node which were not recognized by any vocabularies. These are
    /// stored so we can later produce them as annotations
    unmatched_keywords: Option<AHashMap<String, Value>>,
    // We should probably use AHashMap here but it breaks a bunch of test which assume
    // validators are in a particular order
    validators: Vec<(Keyword, BoxedValidator)>,
}

impl SchemaNode {
    pub(crate) fn from_boolean(ctx: &Context<'_>, validator: Option<BoxedValidator>) -> SchemaNode {
        SchemaNode {
            location: ctx.location().clone(),
            absolute_path: ctx.base_uri(),
            validators: NodeValidators::Boolean { validator },
        }
    }

    pub(crate) fn from_keywords(
        ctx: &Context<'_>,
        validators: Vec<(Keyword, BoxedValidator)>,
        unmatched_keywords: Option<AHashMap<String, Value>>,
    ) -> SchemaNode {
        SchemaNode {
            location: ctx.location().clone(),
            absolute_path: ctx.base_uri(),
            validators: NodeValidators::Keyword(KeywordValidators {
                unmatched_keywords,
                validators,
            }),
        }
    }

    pub(crate) fn from_array(ctx: &Context<'_>, validators: Vec<BoxedValidator>) -> SchemaNode {
        SchemaNode {
            location: ctx.location().clone(),
            absolute_path: ctx.base_uri(),
            validators: NodeValidators::Array { validators },
        }
    }

    pub(crate) fn validators(&self) -> impl ExactSizeIterator<Item = &BoxedValidator> {
        match &self.validators {
            NodeValidators::Boolean { validator } => {
                if let Some(v) = validator {
                    NodeValidatorsIter::BooleanValidators(std::iter::once(v))
                } else {
                    NodeValidatorsIter::NoValidator
                }
            }
            NodeValidators::Keyword(kvals) => {
                NodeValidatorsIter::KeywordValidators(kvals.validators.iter())
            }
            NodeValidators::Array { validators } => {
                NodeValidatorsIter::ArrayValidators(validators.iter())
            }
        }
    }

    /// This is similar to `Validate::apply` except that `SchemaNode` knows where it is in the
    /// validator tree and so rather than returning a `PartialApplication` it is able to return a
    /// complete `BasicOutput`. This is the mechanism which compositional validators use to combine
    /// results from sub-schemas
    pub(crate) fn apply_rooted(
        &self,
        instance: &Value,
        location: &LazyLocation,
    ) -> BasicOutput<'_> {
        match self.apply(instance, location) {
            PartialApplication::Valid {
                annotations,
                mut child_results,
            } => {
                if let Some(annotations) = annotations {
                    child_results.insert(0, self.annotation_at(location, annotations));
                }
                BasicOutput::Valid(child_results)
            }
            PartialApplication::Invalid {
                errors,
                mut child_results,
            } => {
                for error in errors {
                    child_results.insert(0, self.error_at(location, error));
                }
                BasicOutput::Invalid(child_results)
            }
        }
    }

    /// Create an error output which is marked as occurring at this schema node
    pub(crate) fn error_at(
        &self,
        location: &LazyLocation,
        error: ErrorDescription,
    ) -> OutputUnit<ErrorDescription> {
        OutputUnit::<ErrorDescription>::error(
            self.location.clone(),
            location.into(),
            self.absolute_path.clone(),
            error,
        )
    }

    /// Create an annotation output which is marked as occurring at this schema node
    pub(crate) fn annotation_at<'a>(
        &self,
        location: &LazyLocation,
        annotations: Annotations<'a>,
    ) -> OutputUnit<Annotations<'a>> {
        OutputUnit::<Annotations<'_>>::annotations(
            self.location.clone(),
            location.into(),
            self.absolute_path.clone(),
            annotations,
        )
    }

    /// Helper function to apply an iterator of `(Into<PathChunk>, Validate)` to a value. This is
    /// useful as a keyword schemanode has a set of validators keyed by their keywords, so the
    /// `Into<Pathchunk>` is a `String` whereas an array schemanode has an array of validators so
    /// the `Into<PathChunk>` is a `usize`
    fn apply_subschemas<'a, I, P>(
        &self,
        instance: &Value,
        location: &LazyLocation,
        path_and_validators: I,
        annotations: Option<Annotations<'a>>,
    ) -> PartialApplication<'a>
    where
        I: Iterator<Item = (P, &'a Box<dyn Validate + Send + Sync + 'a>)> + 'a,
        P: Into<LocationSegment<'a>> + fmt::Display,
    {
        let mut success_results: VecDeque<OutputUnit<Annotations>> = VecDeque::new();
        let mut error_results = VecDeque::new();
        let mut buffer = String::new();
        let instance_location: OnceCell<Location> = OnceCell::new();

        macro_rules! instance_location {
            () => {
                instance_location.get_or_init(|| location.into()).clone()
            };
        }

        for (path, validator) in path_and_validators {
            macro_rules! make_absolute_location {
                ($location:expr) => {
                    self.absolute_path.as_ref().map(|absolute_path| {
                        uri::encode_to($location.as_str(), &mut buffer);
                        let resolved = absolute_path
                            .with_fragment(Some(uri::EncodedString::new_or_panic(&buffer)));
                        buffer.clear();
                        resolved
                    })
                };
            }
            match validator.apply(instance, location) {
                PartialApplication::Valid {
                    annotations,
                    child_results,
                } => {
                    if let Some(annotations) = annotations {
                        let location = self.location.join(path);
                        let absolute_location = make_absolute_location!(location);
                        success_results.push_front(OutputUnit::<Annotations<'a>>::annotations(
                            location,
                            instance_location!(),
                            absolute_location,
                            annotations,
                        ));
                    }
                    success_results.extend(child_results);
                }
                PartialApplication::Invalid {
                    errors: these_errors,
                    child_results,
                } => {
                    let location = self.location.join(path);
                    error_results.reserve(child_results.len() + these_errors.len());
                    error_results.extend(child_results);
                    error_results.extend(these_errors.into_iter().map(|error| {
                        OutputUnit::<ErrorDescription>::error(
                            location.clone(),
                            instance_location!(),
                            // Resolving & encoding is faster than cloning because one of the
                            // values won't be used when cloning
                            make_absolute_location!(location),
                            error,
                        )
                    }));
                }
            }
        }
        if error_results.is_empty() {
            PartialApplication::Valid {
                annotations,
                child_results: success_results,
            }
        } else {
            PartialApplication::Invalid {
                errors: Vec::new(),
                child_results: error_results,
            }
        }
    }

    pub(crate) fn location(&self) -> &Location {
        &self.location
    }
}

impl Validate for SchemaNode {
    fn iter_errors<'i>(&self, instance: &'i Value, location: &LazyLocation) -> ErrorIterator<'i> {
        match &self.validators {
            NodeValidators::Keyword(kvs) if kvs.validators.len() == 1 => {
                kvs.validators[0].1.iter_errors(instance, location)
            }
            NodeValidators::Keyword(kvs) => Box::new(
                kvs.validators
                    .iter()
                    .flat_map(|(_, v)| v.iter_errors(instance, location))
                    .collect::<Vec<_>>()
                    .into_iter(),
            ),
            NodeValidators::Boolean {
                validator: Some(v), ..
            } => v.iter_errors(instance, location),
            NodeValidators::Boolean {
                validator: None, ..
            } => Box::new(std::iter::empty()),
            NodeValidators::Array { validators } => Box::new(
                validators
                    .iter()
                    .flat_map(move |v| v.iter_errors(instance, location))
                    .collect::<Vec<_>>()
                    .into_iter(),
            ),
        }
    }

    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        match &self.validators {
            NodeValidators::Keyword(kvs) => {
                for (_, validator) in &kvs.validators {
                    validator.validate(instance, location)?;
                }
            }
            NodeValidators::Array { validators } => {
                for validator in validators {
                    validator.validate(instance, location)?;
                }
            }
            NodeValidators::Boolean { validator: Some(_) } => {
                return Err(ValidationError::false_schema(
                    self.location.clone(),
                    location.into(),
                    instance,
                ))
            }
            NodeValidators::Boolean { validator: None } => return Ok(()),
        }
        Ok(())
    }

    fn is_valid(&self, instance: &Value) -> bool {
        match &self.validators {
            // If we only have one validator then calling it's `is_valid` directly does
            // actually save the 20 or so instructions required to call the `slice::Iter::all`
            // implementation. Validators at the leaf of a tree are all single node validators so
            // this optimization can have significant cumulative benefits
            NodeValidators::Keyword(kvs) if kvs.validators.len() == 1 => {
                kvs.validators[0].1.is_valid(instance)
            }
            NodeValidators::Keyword(kvs) => {
                for (_, v) in &kvs.validators {
                    if !v.is_valid(instance) {
                        return false;
                    }
                }
                true
            }
            NodeValidators::Array { validators } => validators.iter().all(|v| v.is_valid(instance)),
            NodeValidators::Boolean { validator: Some(_) } => false,
            NodeValidators::Boolean { validator: None } => true,
        }
    }

    fn apply<'a>(&'a self, instance: &Value, location: &LazyLocation) -> PartialApplication<'a> {
        match self.validators {
            NodeValidators::Array { ref validators } => {
                self.apply_subschemas(instance, location, validators.iter().enumerate(), None)
            }
            NodeValidators::Boolean { ref validator } => {
                if let Some(validator) = validator {
                    validator.apply(instance, location)
                } else {
                    PartialApplication::Valid {
                        annotations: None,
                        child_results: VecDeque::new(),
                    }
                }
            }
            NodeValidators::Keyword(ref kvals) => {
                let KeywordValidators {
                    ref unmatched_keywords,
                    ref validators,
                } = *kvals;
                let annotations: Option<Annotations<'a>> =
                    unmatched_keywords.as_ref().map(Annotations::from);
                self.apply_subschemas(
                    instance,
                    location,
                    validators.iter().map(|(p, v)| (p, v)),
                    annotations,
                )
            }
        }
    }
}

enum NodeValidatorsIter<'a> {
    NoValidator,
    BooleanValidators(std::iter::Once<&'a BoxedValidator>),
    KeywordValidators(std::slice::Iter<'a, (Keyword, BoxedValidator)>),
    ArrayValidators(std::slice::Iter<'a, BoxedValidator>),
}

impl<'a> Iterator for NodeValidatorsIter<'a> {
    type Item = &'a BoxedValidator;

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Self::NoValidator => None,
            Self::BooleanValidators(i) => i.next(),
            Self::KeywordValidators(v) => v.next().map(|(_, v)| v),
            Self::ArrayValidators(v) => v.next(),
        }
    }

    fn all<F>(&mut self, mut f: F) -> bool
    where
        Self: Sized,
        F: FnMut(Self::Item) -> bool,
    {
        match self {
            Self::NoValidator => true,
            Self::BooleanValidators(i) => i.all(f),
            Self::KeywordValidators(v) => v.all(|(_, v)| f(v)),
            Self::ArrayValidators(v) => v.all(f),
        }
    }
}

impl ExactSizeIterator for NodeValidatorsIter<'_> {
    fn len(&self) -> usize {
        match self {
            Self::NoValidator => 0,
            Self::BooleanValidators(..) => 1,
            Self::KeywordValidators(v) => v.len(),
            Self::ArrayValidators(v) => v.len(),
        }
    }
}
