use crate::{
    content_encoding::{ContentEncodingCheckType, ContentEncodingConverterType},
    content_media_type::ContentMediaTypeCheckType,
    keywords::{
        self,
        custom::{CustomKeyword, KeywordFactory},
        format::Format,
        BoxedValidator, BuiltinKeyword, Keyword,
    },
    node::SchemaNode,
    options::ValidationOptions,
    paths::{Location, LocationSegment},
    types::{JsonType, JsonTypeSet},
    ValidationError, Validator,
};
use ahash::{AHashMap, AHashSet};
use referencing::{
    uri, Draft, List, Registry, Resolved, Resolver, Resource, ResourceRef, Uri, Vocabulary,
    VocabularySet,
};
use serde_json::Value;
use std::{borrow::Cow, cell::RefCell, iter::once, rc::Rc, sync::Arc};

const DEFAULT_SCHEME: &str = "json-schema";
pub(crate) const DEFAULT_BASE_URI: &str = "json-schema:///";
type BaseUri = Uri<String>;
type ResolverComponents = (Arc<BaseUri>, List<BaseUri>, Resource);

/// Container for information required to build a tree.
///
/// Tracks the path to the current keyword, and a resolver for the current resource.
#[derive(Debug, Clone)]
pub(crate) struct Context<'a> {
    config: Arc<ValidationOptions>,
    pub(crate) registry: Arc<Registry>,
    resolver: Rc<Resolver<'a>>,
    vocabularies: VocabularySet,
    location: Location,
    pub(crate) draft: Draft,
    seen: Rc<RefCell<AHashSet<Arc<Uri<String>>>>>,
}

impl<'a> Context<'a> {
    pub(crate) fn new(
        config: Arc<ValidationOptions>,
        registry: Arc<Registry>,
        resolver: Rc<Resolver<'a>>,
        vocabularies: VocabularySet,
        draft: Draft,
        location: Location,
    ) -> Self {
        Context {
            config,
            registry,
            resolver,
            location,
            vocabularies,
            draft,
            seen: Rc::new(RefCell::new(AHashSet::new())),
        }
    }
    pub(crate) fn draft(&self) -> Draft {
        self.draft
    }
    pub(crate) fn config(&self) -> &Arc<ValidationOptions> {
        &self.config
    }

    /// Create a context for this schema.
    pub(crate) fn in_subresource(
        &'a self,
        resource: ResourceRef<'_>,
    ) -> Result<Context<'a>, referencing::Error> {
        let resolver = self.resolver.in_subresource(resource)?;
        Ok(Context {
            config: Arc::clone(&self.config),
            registry: Arc::clone(&self.registry),
            resolver: Rc::new(resolver),
            vocabularies: self.vocabularies.clone(),
            draft: resource.draft(),
            location: self.location.clone(),
            seen: Rc::clone(&self.seen),
        })
    }
    pub(crate) fn as_resource_ref<'r>(&'a self, contents: &'r Value) -> ResourceRef<'r> {
        self.draft
            .detect(contents)
            .unwrap_or_default()
            .create_resource_ref(contents)
    }

    #[inline]
    pub(crate) fn new_at_location(&'a self, chunk: impl Into<LocationSegment<'a>>) -> Self {
        let location = self.location.join(chunk);
        Context {
            config: Arc::clone(&self.config),
            registry: Arc::clone(&self.registry),
            resolver: Rc::clone(&self.resolver),
            vocabularies: self.vocabularies.clone(),
            location,
            draft: self.draft,
            seen: Rc::clone(&self.seen),
        }
    }

    pub(crate) fn lookup(&'a self, reference: &str) -> Result<Resolved<'a>, referencing::Error> {
        self.resolver.lookup(reference)
    }

    pub(crate) fn scopes(&self) -> List<Uri<String>> {
        self.resolver.dynamic_scope()
    }

    pub(crate) fn base_uri(&self) -> Option<Uri<String>> {
        let base_uri = self.resolver.base_uri();
        if base_uri.scheme().as_str() == DEFAULT_SCHEME {
            None
        } else {
            Some((*base_uri).clone())
        }
    }
    fn is_known_keyword(&self, keyword: &str) -> bool {
        self.draft.is_known_keyword(keyword)
    }
    pub(crate) fn supports_adjacent_validation(&self) -> bool {
        !matches!(self.draft, Draft::Draft4 | Draft::Draft6 | Draft::Draft7)
    }
    pub(crate) fn supports_integer_valued_numbers(&self) -> bool {
        !matches!(self.draft, Draft::Draft4)
    }
    pub(crate) fn validates_formats_by_default(&self) -> bool {
        self.config.validate_formats().unwrap_or(matches!(
            self.draft,
            Draft::Draft4 | Draft::Draft6 | Draft::Draft7
        ))
    }
    pub(crate) fn are_unknown_formats_ignored(&self) -> bool {
        self.config.are_unknown_formats_ignored()
    }
    pub(crate) fn with_resolver_and_draft(
        &'a self,
        resolver: Resolver<'a>,
        draft: Draft,
        vocabularies: VocabularySet,
        location: Location,
    ) -> Context<'a> {
        Context {
            config: Arc::clone(&self.config),
            registry: Arc::clone(&self.registry),
            resolver: Rc::new(resolver),
            draft,
            vocabularies,
            location,
            seen: Rc::clone(&self.seen),
        }
    }
    pub(crate) fn get_content_media_type_check(
        &self,
        media_type: &str,
    ) -> Option<ContentMediaTypeCheckType> {
        self.config.get_content_media_type_check(media_type)
    }
    pub(crate) fn get_content_encoding_check(
        &self,
        content_encoding: &str,
    ) -> Option<ContentEncodingCheckType> {
        self.config.content_encoding_check(content_encoding)
    }

    pub(crate) fn get_content_encoding_convert(
        &self,
        content_encoding: &str,
    ) -> Option<ContentEncodingConverterType> {
        self.config.get_content_encoding_convert(content_encoding)
    }
    pub(crate) fn get_keyword_factory(&self, name: &str) -> Option<&Arc<dyn KeywordFactory>> {
        self.config.get_keyword_factory(name)
    }
    pub(crate) fn get_format(&self, format: &str) -> Option<(&String, &Arc<dyn Format>)> {
        self.config.get_format(format)
    }
    pub(crate) fn is_circular_reference(
        &self,
        reference: &str,
    ) -> Result<bool, referencing::Error> {
        let uri = self
            .resolver
            .resolve_against(&self.resolver.base_uri().borrow(), reference)?;
        Ok(self.seen.borrow().contains(&*uri))
    }
    pub(crate) fn mark_seen(&self, reference: &str) -> Result<(), referencing::Error> {
        let uri = self
            .resolver
            .resolve_against(&self.resolver.base_uri().borrow(), reference)?;
        self.seen.borrow_mut().insert(uri);
        Ok(())
    }

    pub(crate) fn lookup_recursive_reference(&self) -> Result<Resolved<'_>, referencing::Error> {
        self.resolver.lookup_recursive_ref()
    }
    /// Lookup a reference that is potentially recursive.
    /// Return base URI & resource for known recursive references.
    pub(crate) fn lookup_maybe_recursive(
        &self,
        reference: &str,
        is_recursive: bool,
    ) -> Result<Option<ResolverComponents>, ValidationError<'static>> {
        let resolved = if self.is_circular_reference(reference)? {
            // Otherwise we need to manually check whether this location has already been explored
            self.resolver.lookup(reference)?
        } else {
            // This is potentially recursive, but it is unknown yet
            if !is_recursive {
                self.mark_seen(reference)?;
            }
            return Ok(None);
        };
        let resource = self.draft().create_resource(resolved.contents().clone());
        let mut base_uri = resolved.resolver().base_uri();
        let scopes = resolved.resolver().dynamic_scope();
        if let Some(id) = resource.id() {
            base_uri = self.registry.resolve_against(&base_uri.borrow(), id)?;
        }
        Ok(Some((base_uri, scopes, resource)))
    }

    pub(crate) fn location(&self) -> &Location {
        &self.location
    }

    pub(crate) fn vocabularies(&self) -> &VocabularySet {
        &self.vocabularies
    }

    pub(crate) fn has_vocabulary(&self, vocabulary: &Vocabulary) -> bool {
        if self.draft() < Draft::Draft201909 || vocabulary == &Vocabulary::Core {
            true
        } else {
            self.vocabularies.contains(vocabulary)
        }
    }
}

pub(crate) fn build_validator(
    mut config: ValidationOptions,
    schema: &Value,
) -> Result<Validator, ValidationError<'static>> {
    let draft = config.draft_for(schema)?;
    let resource_ref = draft.create_resource_ref(schema);
    let resource = draft.create_resource(schema.clone());
    let base_uri = if let Some(base_uri) = config.base_uri.as_ref() {
        uri::from_str(base_uri)?
    } else {
        uri::from_str(resource_ref.id().unwrap_or(DEFAULT_BASE_URI))?
    };

    // Build a registry & resolver needed for validator compilation
    let pairs = collect_resource_pairs(base_uri.as_str(), resource, &mut config.resources);

    let registry = if let Some(registry) = config.registry.take() {
        Arc::new(registry.try_with_resources_and_retriever(pairs, &*config.retriever, draft)?)
    } else {
        Arc::new(
            Registry::options()
                .draft(draft)
                .retriever(Arc::clone(&config.retriever))
                .build(pairs)?,
        )
    };
    let vocabularies = registry.find_vocabularies(draft, schema);
    let resolver = Rc::new(registry.resolver(base_uri));

    let config = Arc::new(config);
    let ctx = Context::new(
        Arc::clone(&config),
        Arc::clone(&registry),
        resolver,
        vocabularies,
        draft,
        Location::new(),
    );

    // Validate the schema itself
    if config.validate_schema {
        validate_schema(draft, schema)?;
    }

    // Finally, compile the validator
    let root = compile(&ctx, resource_ref).map_err(ValidationError::to_owned)?;
    Ok(Validator { root, config })
}

#[cfg(feature = "resolve-async")]
pub(crate) async fn build_validator_async(
    mut config: ValidationOptions<Arc<dyn referencing::AsyncRetrieve>>,
    schema: &Value,
) -> Result<Validator, ValidationError<'static>> {
    let draft = config.draft_for(schema).await?;
    let resource_ref = draft.create_resource_ref(schema);
    let resource = draft.create_resource(schema.clone());
    let base_uri = if let Some(base_uri) = config.base_uri.as_ref() {
        uri::from_str(base_uri)?
    } else {
        uri::from_str(resource_ref.id().unwrap_or(DEFAULT_BASE_URI))?
    };

    let pairs = collect_resource_pairs(base_uri.as_str(), resource, &mut config.resources);

    let registry = if let Some(registry) = config.registry.take() {
        Arc::new(
            registry
                .try_with_resources_and_retriever_async(pairs, &*config.retriever, draft)
                .await?,
        )
    } else {
        Arc::new(
            Registry::options()
                .async_retriever(Arc::clone(&config.retriever))
                .draft(draft)
                .build(pairs)
                .await?,
        )
    };

    let vocabularies = registry.find_vocabularies(draft, schema);
    let resolver = Rc::new(registry.resolver(base_uri));
    // HACK: As we store the config and it has a type parameter we need to apply a small hack here.
    //       `ValidationOptions` struct has a default type parameter as `Arc<dyn Retrieve>` and to
    //       avoid propagating types everywhere in `Context`, it is easier to just replace the
    //       retriever to one that implements `Retrieve`, as it is not used anymore anyway.
    //       In the future it might be better to avoid storing the context anyway.
    let config = Arc::new(config.with_blocking_retriever(crate::retriever::DefaultRetriever));
    let ctx = Context::new(
        Arc::clone(&config),
        Arc::clone(&registry),
        resolver,
        vocabularies,
        draft,
        Location::new(),
    );

    if config.validate_schema {
        validate_schema(draft, schema)?;
    }

    let root = compile(&ctx, resource_ref).map_err(ValidationError::to_owned)?;
    Ok(Validator { root, config })
}

fn collect_resource_pairs<'a>(
    base_uri: &'a str,
    resource: Resource,
    resources: &'a mut AHashMap<String, Resource>,
) -> impl IntoIterator<Item = (Cow<'a, str>, Resource)> {
    once((Cow::Borrowed(base_uri), resource)).chain(
        resources
            .drain()
            .map(|(uri, resource)| (Cow::Owned(uri), resource)),
    )
}

fn validate_schema(draft: Draft, schema: &Value) -> Result<(), ValidationError<'static>> {
    let validator = match draft {
        Draft::Draft4 => &crate::draft4::meta::VALIDATOR,
        Draft::Draft6 => &crate::draft6::meta::VALIDATOR,
        Draft::Draft7 => &crate::draft7::meta::VALIDATOR,
        Draft::Draft201909 => &crate::draft201909::meta::VALIDATOR,
        Draft::Draft202012 => &crate::draft202012::meta::VALIDATOR,
        _ => unreachable!("Unknown draft"),
    };
    if let Err(error) = validator.validate(schema) {
        return Err(error.to_owned());
    }
    Ok(())
}

/// Compile a JSON Schema instance to a tree of nodes.
pub(crate) fn compile<'a>(
    ctx: &Context,
    resource: ResourceRef<'a>,
) -> Result<SchemaNode, ValidationError<'a>> {
    let ctx = ctx.in_subresource(resource)?;
    compile_with(&ctx, resource)
}

pub(crate) fn compile_with<'a>(
    ctx: &Context,
    resource: ResourceRef<'a>,
) -> Result<SchemaNode, ValidationError<'a>> {
    let location = ctx.location().clone();
    match resource.contents() {
        Value::Bool(value) => match value {
            true => Ok(SchemaNode::from_boolean(ctx, None)),
            false => Ok(SchemaNode::from_boolean(
                ctx,
                Some(
                    keywords::boolean::FalseValidator::compile(location)
                        .expect("Should always compile"),
                ),
            )),
        },
        Value::Object(schema) => {
            // A schema could contain validation keywords along with annotations and we need to
            // collect annotations separately
            if !ctx.supports_adjacent_validation() {
                // Older drafts ignore all other keywords if `$ref` is present
                if let Some(reference) = schema.get("$ref") {
                    // Treat all keywords other than `$ref` as annotations
                    let annotations = schema
                        .iter()
                        .filter_map(|(k, v)| {
                            if k.as_str() == "$ref" {
                                None
                            } else {
                                Some((k.clone(), v.clone()))
                            }
                        })
                        .collect();
                    return if let Some(validator) =
                        keywords::ref_::compile_ref(ctx, schema, reference)
                    {
                        let validators = vec![(BuiltinKeyword::Ref.into(), validator?)];
                        Ok(SchemaNode::from_keywords(
                            ctx,
                            validators,
                            Some(annotations),
                        ))
                    } else {
                        // Infinite reference to the same location
                        Ok(SchemaNode::from_boolean(ctx, None))
                    };
                }
            }

            let mut validators = Vec::with_capacity(schema.len());
            let mut annotations = AHashMap::new();
            for (keyword, value) in schema {
                // Check if this keyword is overridden, then check the standard definitions
                if let Some(factory) = ctx.get_keyword_factory(keyword) {
                    let path = ctx.location().join(keyword);
                    let validator = CustomKeyword::new(factory.init(schema, value, path)?);
                    let validator: BoxedValidator = Box::new(validator);
                    validators.push((Keyword::custom(keyword), validator));
                } else if let Some((keyword, validator)) = keywords::get_for_draft(ctx, keyword)
                    .and_then(|(keyword, f)| f(ctx, schema, value).map(|v| (keyword, v)))
                {
                    validators.push((keyword, validator.map_err(ValidationError::to_owned)?));
                } else if !ctx.is_known_keyword(keyword) {
                    // Treat all non-validation keywords as annotations
                    annotations.insert(keyword.to_string(), value.clone());
                }
            }
            let annotations = if annotations.is_empty() {
                None
            } else {
                Some(annotations)
            };
            Ok(SchemaNode::from_keywords(ctx, validators, annotations))
        }
        _ => Err(ValidationError::multiple_type_error(
            Location::new(),
            location,
            resource.contents(),
            JsonTypeSet::empty()
                .insert(JsonType::Boolean)
                .insert(JsonType::Object),
        )),
    }
}
