use crate::config::Config;
use crate::endian::*;
use crate::meta::attr::{MetaAttr, MetaAttrType};
use proc_macro2::{Span, TokenStream};
use quote::ToTokens;
use syn::parse::Parser;
use syn::punctuated::Punctuated;
use syn::token::Comma;
use syn::*;

pub(crate) trait Generator {
    fn from_ast(ast: &DeriveInput, endianness: ParserEndianness) -> Result<Self>
    where
        Self: Sized;

    fn name(&self) -> &Ident;

    fn set_debug(&mut self, debug_derive: bool);

    fn extra_args(&self) -> Option<&TokenStream>;

    fn orig_generics(&self) -> &Generics;

    fn impl_where_predicates(&self) -> Option<&Vec<WherePredicate>> {
        None
    }

    fn config(&self) -> &Config;

    fn gen_fn_body(&self, endianness: ParserEndianness) -> Result<TokenStream>;

    fn gen_parse_be(&self) -> Result<TokenStream> {
        let fn_decl = gen_fn_decl(
            ParserEndianness::BigEndian,
            self.extra_args(),
            self.config(),
        );
        if self.has_impl_for_endianness(ParserEndianness::BigEndian) {
            let fn_body = self.gen_fn_body(ParserEndianness::BigEndian)?;

            let fn_tokens = quote! {
                #fn_decl
                {
                    #fn_body
                }
            };
            Ok(fn_tokens)
        } else {
            let call_args = self.get_call_args();
            let ts = quote! {
                #fn_decl {
                    Self::parse_le(#call_args)
                }
            };
            Ok(ts)
        }
    }

    fn gen_parse_le(&self) -> Result<TokenStream> {
        let fn_decl = gen_fn_decl(
            ParserEndianness::LittleEndian,
            self.extra_args(),
            self.config(),
        );
        if self.has_impl_for_endianness(ParserEndianness::LittleEndian) {
            let fn_body = self.gen_fn_body(ParserEndianness::LittleEndian)?;

            let fn_tokens = quote! {
                #fn_decl
                {
                    #fn_body
                }
            };
            Ok(fn_tokens)
        } else {
            let call_args = self.get_call_args();
            let ts = quote! {
                #fn_decl {
                    Self::parse_be(#call_args)
                }
            };
            Ok(ts)
        }
    }

    fn gen_parse(&self) -> Result<TokenStream> {
        let ident_e = Ident::new(self.config().error_name(), Span::call_site());
        let lft = Lifetime::new(self.config().lifetime_name(), Span::call_site());
        // 'parse' function
        let maybe_err = if self.config().generic_errors {
            quote!( , #ident_e )
        } else {
            quote!()
        };
        let special_case = self.extra_args().is_some() || self.config().selector_type().is_some();
        let scope = if special_case {
            quote! { pub }
        } else {
            quote! {}
        };
        let tokens_parse = {
            let (fn_generics, where_clause) = if self.config().generic_errors && special_case {
                (
                    quote!(<#ident_e>),
                    quote! {where
                        #ident_e: nom_derive::nom::error::ParseError<&#lft [u8]>,
                        #ident_e: std::fmt::Debug,
                    },
                )
            } else {
                (quote!(), quote!())
            };
            let call_args = self.get_call_args();
            let fn_args = get_fn_args(self.extra_args(), self.config());
            quote! {
               #scope fn parse#fn_generics(#fn_args) -> nom::IResult<&'nom [u8], Self #maybe_err> #where_clause {
                    Self::parse_be(#call_args)
                }
            }
        };
        Ok(tokens_parse)
    }

    fn gen_impl(&self) -> Result<TokenStream> {
        let name = self.name();
        let lft = Lifetime::new(self.config().lifetime_name(), Span::call_site());
        let ident_e = Ident::new(self.config().error_name(), Span::call_site());
        let maybe_err = if self.config().generic_errors {
            quote!( , #ident_e )
        } else {
            quote!()
        };

        let tokens_parse = self.gen_parse()?;
        let tokens_parse_be = self.gen_parse_be()?;
        let tokens_parse_le = self.gen_parse_le()?;

        // extract impl parameters from struct
        let orig_generics = &self.orig_generics();
        let (impl_generics, ty_generics, where_clause) = orig_generics.split_for_impl();

        let mut gen_impl: Generics = parse_quote!(#impl_generics);
        gen_impl
            .params
            .push(GenericParam::Lifetime(LifetimeDef::new(lft.clone())));
        let param_e = TypeParam::from(ident_e.clone());

        let mut gen_wh: WhereClause = if where_clause.is_none() {
            parse_quote!(where)
        } else {
            parse_quote!(#where_clause)
        };
        let lfts: Vec<_> = orig_generics.lifetimes().collect();
        if !lfts.is_empty() {
            // input slice must outlive all lifetimes from Self
            let wh: WherePredicate = parse_quote! { #lft: #(#lfts)+* };
            gen_wh.predicates.push(wh);
        };

        // make sure generic parameters inplement Parse
        for param in orig_generics.type_params() {
            let param_ident = &param.ident;
            let dep: WherePredicate = parse_quote! { #param_ident: Parse< &#lft [u8] #maybe_err > };
            gen_wh.predicates.push(dep);
        }
        if let Some(impl_where_predicates) = self.impl_where_predicates() {
            for wh in impl_where_predicates {
                gen_wh.predicates.push(wh.clone());
            }
        }

        // Global impl
        let impl_tokens = if self.extra_args().is_some() || self.config().selector_type().is_some()
        {
            // There are extra arguments, so we can't generate the Parse impl
            // Generate an equivalent implementation
            if self.config().generic_errors {
                // XXX will fail: generic type should be added to function (npt struct), or
                // XXX compiler will complain that
                // XXX "the type parameter `NomErr` is not constrained by the impl trait, self type, or predicates"
                // this happens only when not implementing trait (the trait constrains NomErr)
                // let wh: WherePredicate = parse_quote!(#ident_e: nom::error::ParseError<& #lft [u8]>);
                // gen_wh.predicates.push(wh);
                // gen_impl.params.push(GenericParam::Type(param_e));
            }
            quote! {
                impl #gen_impl #name #ty_generics #gen_wh {
                    #tokens_parse_be
                    #tokens_parse_le
                    #tokens_parse
                }
            }
        } else {
            // Generate an impl block for the Parse trait
            let error = if self.config().generic_errors {
                let wh: WherePredicate =
                    parse_quote!(#ident_e: nom::error::ParseError<& #lft [u8]>);
                gen_wh.predicates.push(wh);
                gen_impl.params.push(GenericParam::Type(param_e));
                quote! { #ident_e }
            } else {
                quote! { nom::error::Error<&#lft [u8]> }
            };
            quote! {
                    impl #gen_impl nom_derive::Parse<& #lft [u8], #error> for #name #ty_generics #gen_wh {
                        #tokens_parse_be
                        #tokens_parse_le
                        #tokens_parse
                    }

            }
        };

        if self.config().debug_derive {
            eprintln!("tokens:\n{}", impl_tokens);
        }

        Ok(impl_tokens)
    }

    fn has_impl_for_endianness(&self, endianness: ParserEndianness) -> bool {
        assert!(
            endianness == ParserEndianness::BigEndian
                || endianness == ParserEndianness::LittleEndian
        );

        //
        if self.config().object_endianness == endianness
            || self.config().global_endianness == endianness
        {
            return true;
        }

        if self.config().object_endianness == ParserEndianness::Unspecified
            || self.config().global_endianness == ParserEndianness::Unspecified
        {
            return true;
        }

        false
    }

    fn get_call_args(&self) -> TokenStream {
        let mut call_args: Punctuated<_, Token![,]> = Punctuated::new();
        let orig_input = Ident::new(self.config().orig_input_name(), Span::call_site());
        call_args.push(orig_input);
        // selector, if present
        if let Some(s) = self.config().selector_name() {
            let selector = Ident::new(s, Span::call_site());
            call_args.push(selector);
        }
        // extra args, if any
        if let Some(ts) = self.extra_args() {
            let ts = ts.clone();
            let parser = Punctuated::<syn::FnArg, Comma>::parse_separated_nonempty;
            let extra_args = parser.parse2(ts).expect("parse extra_args");
            for extra_arg in &extra_args {
                match extra_arg {
                    syn::FnArg::Receiver(_) => panic!("self should not be used in extra_args"),
                    syn::FnArg::Typed(t) => {
                        if let syn::Pat::Ident(pat_ident) = t.pat.as_ref() {
                            call_args.push(pat_ident.ident.clone());
                        } else {
                            panic!("unexpected pattern in extra_args");
                        }
                    }
                }
            }
        };
        call_args.to_token_stream()
    }
}

pub(crate) fn gen_fn_decl(
    endianness: ParserEndianness,
    extra_args: Option<&TokenStream>,
    config: &Config,
) -> TokenStream {
    let parse = match endianness {
        ParserEndianness::BigEndian => "parse_be",
        ParserEndianness::LittleEndian => "parse_le",
        ParserEndianness::SetEndian => panic!("gen_fn_decl should never receive SetEndian"),
        ParserEndianness::Unspecified => "parse",
    };
    let parse = Ident::new(parse, Span::call_site());
    let fn_args = get_fn_args(extra_args, config);
    // get lifetimes
    let lft = Lifetime::new(config.lifetime_name(), Span::call_site());
    let mut fn_where_clause = WhereClause {
        where_token: Token![where](Span::call_site()),
        predicates: punctuated::Punctuated::new(),
    };

    // if we are generating a stub, we need to mark the function as `pub`
    let special_case = extra_args.is_some() || config.selector_type().is_some();
    let scope = if special_case {
        quote! { pub }
    } else {
        quote! {}
    };

    // function declaration line
    if config.generic_errors {
        let ident_e = Ident::new(config.error_name(), Span::call_site());
        let mut fn_generics = None;
        if special_case {
            // special case: not implementing the Parse trait,
            // generic errors must be added to function, not struct
            //
            // extend where clause for generic parameters
            let dep: WherePredicate = parse_quote! {
                #ident_e: nom_derive::nom::error::ParseError<&#lft [u8]>
            };
            fn_where_clause.predicates.push(dep);
            let dep: WherePredicate = parse_quote! { #ident_e: std::fmt::Debug };
            fn_where_clause.predicates.push(dep);
            // add error type to function generics
            fn_generics = Some(quote!(<#ident_e>));
        }
        quote! {
           #scope fn #parse#fn_generics(#fn_args) -> nom::IResult<&#lft [u8], Self, #ident_e>
            #fn_where_clause
        }
    } else {
        quote! {
           #scope fn #parse(#fn_args) -> nom::IResult<&#lft [u8], Self>
            #fn_where_clause
        }
    }
}

pub(crate) fn get_extra_args(meta_list: &[MetaAttr]) -> Option<&TokenStream> {
    meta_list
        .iter()
        .find(|m| m.attr_type == MetaAttrType::ExtraArgs)
        .and_then(MetaAttr::arg)
}

pub(crate) fn get_fn_args(
    extra_args: Option<&TokenStream>,
    config: &Config,
) -> Punctuated<FnArg, Comma> {
    let orig_input = Ident::new(config.orig_input_name(), Span::call_site());
    // get lifetimes
    let lft = Lifetime::new(config.lifetime_name(), Span::call_site());

    // function arguments: input first
    let mut fn_args: Punctuated<_, Token![,]> = Punctuated::new();
    let arg_input: FnArg = parse_quote!(#orig_input: &#lft [u8]);
    fn_args.push(arg_input);
    // selector, if present
    if let Some(sel_type) = config.selector_type() {
        let s = config.selector_name().unwrap_or("selector");
        let sel_name = Ident::new(s, Span::call_site());
        let selector: FnArg = parse_quote!(#sel_name: #sel_type);
        fn_args.push(selector);
    }
    // extra args, if any
    if let Some(ts) = extra_args {
        let ts = ts.clone();
        type Comma = syn::Token![,];
        let parser = Punctuated::<syn::FnArg, Comma>::parse_separated_nonempty;
        let extra_args = parser.parse2(ts).expect("parse extra_args");
        for extra_arg in &extra_args {
            fn_args.push(extra_arg.clone());
        }
    };
    fn_args
}
