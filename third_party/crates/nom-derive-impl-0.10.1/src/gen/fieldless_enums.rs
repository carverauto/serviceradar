use proc_macro2::Ident;
use proc_macro2::Span;
use proc_macro2::TokenStream;
use syn::*;

use crate::config::Config;
use crate::endian::*;
use crate::enums::*;
use crate::gen::get_extra_args;
use crate::meta;
use crate::parsertree::{ParserExpr, TypeItem};
use crate::structs::get_pre_post_exec;
use crate::Result;

use super::Generator;

pub struct GenFieldlessEnum {
    pub name: Ident,
    pub config: Config,

    extra_args: Option<TokenStream>,

    orig_generics: Generics,
    tl_pre: Option<TokenStream>,
    tl_post: Option<TokenStream>,
    repr_parser: ParserExpr,
    variants_code: Vec<TokenStream>,
}

impl Generator for GenFieldlessEnum {
    fn from_ast(ast: &DeriveInput, endianness: ParserEndianness) -> Result<Self> {
        match &ast.data {
            syn::Data::Enum(data_enum) => GenFieldlessEnum::from_data_enum(
                &ast.ident,
                data_enum,
                &ast.attrs,
                &ast.generics,
                endianness,
            ),
            _ => panic!("Wrong type for GenFieldlessEnum::from_ast"),
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
        let variants_code = &self.variants_code;
        let parser = &self.repr_parser.with_endianness(endianness);
        // generate body
        let tokens = quote! {
            let #input = #orig_input;
            #tl_pre
            let (#input, selector) = #parser(#input)?;
            let enum_def =
                #(#variants_code else)*
            { return Err(nom::Err::Error(nom::error::make_error(#orig_input, nom::error::ErrorKind::Switch))); };
            #tl_post
            Ok((#input, enum_def))
        };

        Ok(tokens)
    }
}

impl GenFieldlessEnum {
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

        if extra_args.is_some() {
            panic!("fieldless enums cannot have extra_args");
        }

        let repr = get_repr(attrs).ok_or_else(|| {
            Error::new(
                name.span(),
                "Nom-derive: fieldless enums must have a 'repr' or 'selector' attribute",
            )
        })?;
        let repr_string = repr.to_string();
        let repr_type = syn::parse_str::<Type>(&repr_string).expect("could not parse repr type");

        let repr_parser = match repr_string.as_ref() {
            "u8" | "u16" | "u24" | "u32" | "u64" | "u128" | "i8" | "i16" | "i24" | "i32"
            | "i64" | "i128" => {
                let endian = get_object_endianness(&config);
                match endian {
                    ParserEndianness::BigEndian => {
                        ParserExpr::CallParseBE(TypeItem(repr_type.clone()))
                    }
                    ParserEndianness::LittleEndian => {
                        ParserExpr::CallParseLE(TypeItem(repr_type.clone()))
                    }
                    ParserEndianness::Unspecified => {
                        ParserExpr::CallParse(TypeItem(repr_type.clone()))
                    }
                    ParserEndianness::SetEndian => unimplemented!("SetEndian for fieldless enums"),
                }
            }
            _ => {
                return Err(Error::new(
                    repr.span(),
                    "Nom-derive: cannot parse 'repr' content (must be a primitive type)",
                ))
            }
        };

        let variants_code: Vec<_> = data_enum
            .variants
            .iter()
            .map(|variant| {
                let id = &variant.ident;
                quote! { if selector == #name::#id as #repr_type { #name::#id } }
            })
            .collect();

        Ok(Self {
            name,
            config,
            extra_args,
            orig_generics: generics.clone(),
            tl_pre,
            tl_post,
            repr_parser,
            variants_code,
        })
    }
}
