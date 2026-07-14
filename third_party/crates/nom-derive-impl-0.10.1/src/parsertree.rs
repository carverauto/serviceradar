use proc_macro2::TokenStream;
use quote::ToTokens;
use syn::Ident;

use crate::endian::ParserEndianness;

#[derive(Debug)]
pub struct ParserTree {
    root: ParserExpr,
}

impl ToTokens for ParserTree {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        self.root.to_tokens(tokens)
    }
}

#[derive(Debug)]
pub struct ParserTreeItem {
    pub ident: Option<Ident>,
    pub expr: ParserExpr,
}

impl ParserTreeItem {
    pub fn new(ident: Option<Ident>, expr: ParserExpr) -> Self {
        ParserTreeItem { ident, expr }
    }

    pub fn with_endianness(&self, endianness: ParserEndianness) -> Self {
        ParserTreeItem {
            ident: self.ident.clone(),
            expr: self.expr.with_endianness(endianness),
        }
    }
}

impl ToTokens for ParserTreeItem {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        self.expr.to_tokens(tokens)
    }
}

#[allow(clippy::upper_case_acronyms)]
#[derive(Clone, Debug)]
pub enum ParserExpr {
    CallParse(TypeItem),
    CallParseBE(TypeItem),
    CallParseLE(TypeItem),
    Complete(Box<ParserExpr>),
    Cond(Box<ParserExpr>, TokenStream),
    Count(Box<ParserExpr>, TokenStream),
    DbgDmp(Box<ParserExpr>, Ident),
    Into(Box<ParserExpr>),
    LengthCount(Box<ParserExpr>, TokenStream),
    Map(Box<ParserExpr>, TokenStream),
    Nop,
    PhantomData,
    Raw(TokenStream),
    Tag(TokenStream),
    Take(TokenStream),
    Value(TokenStream),
    Verify(Box<ParserExpr>, Ident, TokenStream),
}

impl ParserExpr {
    pub fn with_endianness(&self, endianness: ParserEndianness) -> Self {
        match self {
            ParserExpr::CallParse(item) => match endianness {
                ParserEndianness::BigEndian => ParserExpr::CallParseBE(item.clone()),
                ParserEndianness::LittleEndian => ParserExpr::CallParseLE(item.clone()),
                _ => unreachable!(),
            },
            expr => expr.clone(),
        }
    }

    #[inline]
    pub fn complete(self) -> Self {
        ParserExpr::Complete(Box::new(self))
    }

    pub fn last_type(&self) -> Option<&TypeItem> {
        match self {
            ParserExpr::CallParse(e) | ParserExpr::CallParseBE(e) | ParserExpr::CallParseLE(e) => {
                Some(e)
            }
            ParserExpr::Complete(expr)
            | ParserExpr::Cond(expr, _)
            | ParserExpr::Count(expr, _)
            | ParserExpr::DbgDmp(expr, _)
            | ParserExpr::Into(expr)
            | ParserExpr::LengthCount(expr, _)
            | ParserExpr::Map(expr, _)
            | ParserExpr::Verify(expr, _, _) => expr.last_type(),
            _ => None,
        }
    }
}

impl ToTokens for ParserExpr {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        let ts = match self {
            ParserExpr::CallParse(s) => {
                quote! { <#s>::parse }
            }
            ParserExpr::CallParseBE(s) => {
                quote! { <#s>::parse_be }
            }
            ParserExpr::CallParseLE(s) => {
                quote! { <#s>::parse_le }
            }
            ParserExpr::Complete(expr) => {
                quote! { nom::combinator::complete(#expr) }
            }
            ParserExpr::Cond(expr, c) => {
                quote! { nom::combinator::cond(#c, #expr) }
            }
            ParserExpr::Count(expr, n) => {
                quote! { nom::multi::count(#expr, #n as usize) }
            }
            ParserExpr::DbgDmp(expr, i) => {
                let ident = format!("{}", i);
                quote! { nom::error::dbg_dmp(#expr, #ident) }
            }
            ParserExpr::Into(expr) => {
                quote! { nom::combinator::into(#expr) }
            }
            ParserExpr::LengthCount(expr, n) => {
                quote! { nom::multi::length_count(#n, #expr) }
            }
            ParserExpr::Map(expr, m) => {
                quote! { nom::combinator::map(#expr, #m) }
            }
            ParserExpr::Nop => {
                quote! {
                    { |__i__| Ok((__i__, ())) }
                }
            }
            ParserExpr::PhantomData => {
                quote! {
                    { |__i__| Ok((__i__, PhantomData)) }
                }
            }
            ParserExpr::Raw(s) => s.to_token_stream(),
            ParserExpr::Tag(s) => {
                quote! { nom::bytes::streaming::tag(#s) }
            }
            ParserExpr::Take(s) => {
                quote! { nom::bytes::streaming::take(#s as usize) }
            }
            ParserExpr::Value(ts) => {
                quote! {
                    { |__i__| Ok((__i__, #ts)) }
                }
            }
            ParserExpr::Verify(expr, i, v) => {
                quote! {
                    nom::combinator::verify(#expr, |#i| { #v })
                }
            }
        };
        tokens.extend(ts);
    }
}

#[derive(Clone, Debug)]
pub struct TypeItem(pub syn::Type);

impl ToTokens for TypeItem {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        self.0.to_tokens(tokens)
    }
}
