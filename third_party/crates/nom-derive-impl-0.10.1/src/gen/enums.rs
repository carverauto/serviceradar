use proc_macro2::Ident;
use proc_macro2::Span;
use proc_macro2::TokenStream;
use syn::*;

use crate::config::Config;
use crate::endian::*;
use crate::enums::*;
use crate::gen::get_extra_args;
use crate::meta;
use crate::structs::get_pre_post_exec;
use crate::Result;

use super::Generator;

pub struct GenEnum {
    pub name: Ident,
    pub config: Config,

    extra_args: Option<TokenStream>,

    orig_generics: Generics,
    tl_pre: Option<TokenStream>,
    tl_post: Option<TokenStream>,
    variants_defs: Vec<VariantParserTree>,
}

impl Generator for GenEnum {
    fn from_ast(ast: &DeriveInput, endianness: ParserEndianness) -> Result<Self> {
        match &ast.data {
            syn::Data::Enum(data_enum) => GenEnum::from_data_enum(
                &ast.ident,
                data_enum,
                &ast.attrs,
                &ast.generics,
                endianness,
            ),
            _ => panic!("Wrong type for GenEnum::from_ast"),
        }
    }

    #[inline]
    fn name(&self) -> &Ident {
        &self.name
    }

    fn set_debug(&mut self, debug_derive: bool) {
        self.config.debug_derive |= debug_derive;
    }

    #[inline]
    fn extra_args(&self) -> Option<&TokenStream> {
        self.extra_args.as_ref()
    }

    #[inline]
    fn orig_generics(&self) -> &Generics {
        &self.orig_generics
    }

    #[inline]
    fn config(&self) -> &Config {
        &self.config
    }

    fn gen_fn_body(&self, endianness: ParserEndianness) -> Result<TokenStream> {
        let orig_input = Ident::new(self.config.orig_input_name(), Span::call_site());
        let input = Ident::new(self.config.input_name(), Span::call_site());
        let (tl_pre, tl_post) = (&self.tl_pre, &self.tl_post);
        // generate body
        let (default_case_handled, variants_code) = self.gen_variants(endianness)?;
        let default_case = if default_case_handled {
            quote! {}
        } else {
            quote! { _ => Err(nom::Err::Error(nom::error_position!(#input, nom::error::ErrorKind::Switch))) }
        };
        let tokens = quote! {
            let #input = #orig_input;
            #tl_pre
            let (#input, enum_def) = match selector {
                #(#variants_code)*
                #default_case
            }?;
            #tl_post
            Ok((#input, enum_def))
        };
        Ok(tokens)
    }
}

impl GenEnum {
    pub fn from_data_enum(
        name: &Ident,
        data_enum: &DataEnum,
        attrs: &[Attribute],
        generics: &Generics,
        endianness: ParserEndianness,
    ) -> Result<Self> {
        let name = name.clone();

        // parse top-level attributes and prepare tokens for each field parser
        let meta = meta::parse_nom_top_level_attribute(attrs)?;
        // eprintln!("top-level meta: {:?}", meta);
        let mut config = Config::from_meta_list(name.to_string(), &meta)?;

        // endianness must be set before parsing struct
        set_object_endianness(name.span(), endianness, &meta, &mut config)?;

        let extra_args = get_extra_args(&meta).map(Clone::clone);

        // test endianness validity (not 2 or more)
        validate_endianness(
            endianness,
            config.object_endianness,
            config.global_endianness,
        )?;

        // save global pre/post exec
        let (tl_pre, tl_post) = get_pre_post_exec(&meta, &config);

        // fieldless enums should not be handled by this generator
        assert!(config.selector_type().is_some());

        // iter fields / variants and store info
        let variants_defs = data_enum
            .variants
            .iter()
            .map(|v| parse_variant(v, &mut config))
            .collect::<Result<Vec<_>>>()?;

        Ok(Self {
            name,
            config,
            extra_args,
            orig_generics: generics.clone(),
            tl_pre,
            tl_post,
            variants_defs,
        })
    }

    /// Generate parser code for every variant of the enum
    ///
    /// Returns a boolean indicating if default case was handled, and the list of tokens for each variant
    fn gen_variants(&self, endianness: ParserEndianness) -> Result<(bool, Vec<TokenStream>)> {
        let name = &self.name;
        let input = syn::Ident::new(self.config.input_name(), Span::call_site());
        let mut default_case_handled = false;
        let mut variants_code: Vec<_> = {
            self.variants_defs
                .iter()
                .map(|def| {
                    if def.selector_type == "_" {
                        default_case_handled = true;
                    }
                    let m: proc_macro2::TokenStream =
                        def.selector_type.parse().expect("invalid selector value");
                    let variantname = &def.ident;
                    let (idents, parser_tokens): (Vec<_>, Vec<_>) = def
                        .struct_def
                        .parsers
                        .iter()
                        .map(|sp| {
                            let id = syn::Ident::new(&sp.name, Span::call_site());
                            // set current endianness for functions that do not specify it
                            let item = sp.item.with_endianness(endianness);
                            (id, item)
                        })
                        .unzip();
                    let (pre, post): (Vec<_>, Vec<_>) = def
                        .struct_def
                        .parsers
                        .iter()
                        .map(|sp| (sp.pre_exec.as_ref(), sp.post_exec.as_ref()))
                        .unzip();
                    let idents2 = idents.clone();
                    let struct_def = match (def.struct_def.empty, def.struct_def.unnamed) {
                        (true, _) => quote! { ( #name::#variantname ) },
                        (_, true) => quote! { ( #name::#variantname ( #(#idents2),* ) ) },
                        (_, false) => quote! { ( #name::#variantname { #(#idents2),* } ) },
                    };
                    //
                    // XXX this looks wrong: endianness does not appear in this function!
                    // XXX parser_tokens should specify endianness
                    // XXX
                    // XXX this is caused by quote!{} calling to_string()
                    quote! {
                    #m => {
                        #(
                            #pre
                            let (#input, #idents) = #parser_tokens (#input) ?;
                            #post
                        )*
                        let struct_def = #struct_def;
                        Ok((#input, struct_def))
                            // Err(nom::Err::Error(error_position!(#input_name, nom::ErrorKind::Switch)))
                    },
                    }
                })
                .collect()
        };
        // if we have a default case, make sure it is the last entry
        if default_case_handled {
            let pos = self
                .variants_defs
                .iter()
                .position(|def| def.selector_type == "_")
                .expect("default case is handled but couldn't find index");
            let last_index = self.variants_defs.len() - 1;
            if pos != last_index {
                // self.variants_defs.swap(pos, last_index);
                variants_code.swap(pos, last_index);
            }
        }
        Ok((default_case_handled, variants_code))
    }
}
