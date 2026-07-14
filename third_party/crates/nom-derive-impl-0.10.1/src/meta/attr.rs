use proc_macro2::{Span, TokenStream};
use quote::ToTokens;
use std::fmt;
use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::{parenthesized, token, Ident, Token};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MetaAttrType {
    AlignAfter,
    AlignBefore,
    BigEndian,
    Complete,
    Cond,
    Count,
    Debug,
    DebugDerive,
    ErrorIf,
    Exact,
    ExtraArgs,
    GenericErrors,
    Ignore,
    InputName,
    Into,
    LengthCount,
    LittleEndian,
    Map,
    Move,
    MoveAbs,
    Parse,
    PostExec,
    PreExec,
    Selector,
    SetEndian,
    SkipAfter,
    SkipBefore,
    Tag,
    Take,
    Value,
    Verify,
}

impl MetaAttrType {
    pub fn from_ident(ident: &syn::Ident) -> Option<Self> {
        match ident.to_string().as_ref() {
            "AlignAfter" => Some(MetaAttrType::AlignAfter),
            "AlignBefore" => Some(MetaAttrType::AlignBefore),
            "BigEndian" => Some(MetaAttrType::BigEndian),
            "Complete" => Some(MetaAttrType::Complete),
            "Count" => Some(MetaAttrType::Count),
            "Debug" => Some(MetaAttrType::Debug),
            "DebugDerive" => Some(MetaAttrType::DebugDerive),
            "ErrorIf" => Some(MetaAttrType::ErrorIf),
            "Exact" => Some(MetaAttrType::Exact),
            "ExtraArgs" => Some(MetaAttrType::ExtraArgs),
            "GenericErrors" => Some(MetaAttrType::GenericErrors),
            "If" | "Cond" => Some(MetaAttrType::Cond),
            "Ignore" | "Default" => Some(MetaAttrType::Ignore),
            "InputName" => Some(MetaAttrType::InputName),
            "Into" => Some(MetaAttrType::Into),
            "LengthCount" => Some(MetaAttrType::LengthCount),
            "LittleEndian" => Some(MetaAttrType::LittleEndian),
            "Map" => Some(MetaAttrType::Map),
            "Move" => Some(MetaAttrType::Move),
            "MoveAbs" => Some(MetaAttrType::MoveAbs),
            "Parse" => Some(MetaAttrType::Parse),
            "PostExec" => Some(MetaAttrType::PostExec),
            "PreExec" => Some(MetaAttrType::PreExec),
            "Selector" => Some(MetaAttrType::Selector),
            "SetEndian" => Some(MetaAttrType::SetEndian),
            "SkipAfter" => Some(MetaAttrType::SkipAfter),
            "SkipBefore" => Some(MetaAttrType::SkipBefore),
            "Tag" => Some(MetaAttrType::Tag),
            "Take" => Some(MetaAttrType::Take),
            "Value" => Some(MetaAttrType::Value),
            "Verify" => Some(MetaAttrType::Verify),
            _ => None,
        }
    }

    pub fn takes_argument(self) -> bool {
        matches!(
            self,
            MetaAttrType::AlignAfter
                | MetaAttrType::AlignBefore
                | MetaAttrType::Cond
                | MetaAttrType::Count
                | MetaAttrType::ErrorIf
                | MetaAttrType::ExtraArgs
                | MetaAttrType::InputName
                | MetaAttrType::LengthCount
                | MetaAttrType::Map
                | MetaAttrType::Move
                | MetaAttrType::MoveAbs
                | MetaAttrType::Parse
                | MetaAttrType::PostExec
                | MetaAttrType::PreExec
                | MetaAttrType::Selector
                | MetaAttrType::SetEndian
                | MetaAttrType::SkipAfter
                | MetaAttrType::SkipBefore
                | MetaAttrType::Tag
                | MetaAttrType::Take
                | MetaAttrType::Value
                | MetaAttrType::Verify
        )
    }
}

impl fmt::Display for MetaAttrType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            MetaAttrType::AlignAfter => "AlignAfter",
            MetaAttrType::AlignBefore => "AlignBefore",
            MetaAttrType::BigEndian => "BigEndian",
            MetaAttrType::Complete => "Complete",
            MetaAttrType::Cond => "Cond",
            MetaAttrType::Count => "Count",
            MetaAttrType::Debug => "Debug",
            MetaAttrType::DebugDerive => "DebugDerive",
            MetaAttrType::ErrorIf => "ErrorIf",
            MetaAttrType::Exact => "Exact",
            MetaAttrType::ExtraArgs => "ExtraArgs",
            MetaAttrType::GenericErrors => "GenericErrors",
            MetaAttrType::Ignore => "Ignore",
            MetaAttrType::InputName => "InputName",
            MetaAttrType::Into => "Into",
            MetaAttrType::LengthCount => "LengthCount",
            MetaAttrType::LittleEndian => "LittleEndian",
            MetaAttrType::Map => "Map",
            MetaAttrType::Move => "Move",
            MetaAttrType::MoveAbs => "MoveAbs",
            MetaAttrType::Parse => "Parse",
            MetaAttrType::PostExec => "PostExec",
            MetaAttrType::PreExec => "PreExec",
            MetaAttrType::Selector => "Selector",
            MetaAttrType::SetEndian => "SetEndian",
            MetaAttrType::SkipAfter => "SkipAfter",
            MetaAttrType::SkipBefore => "SkipBefore",
            MetaAttrType::Tag => "Tag",
            MetaAttrType::Take => "Take",
            MetaAttrType::Value => "Value",
            MetaAttrType::Verify => "Verify",
        };
        f.write_str(s)
    }
}

#[derive(Debug)]
pub struct MetaAttr {
    pub attr_type: MetaAttrType,
    arg0: Option<TokenStream>,
    span: Span,
}

impl MetaAttr {
    pub fn new(attr_type: MetaAttrType, arg0: Option<TokenStream>, span: Span) -> Self {
        MetaAttr {
            attr_type,
            arg0,
            span,
        }
    }

    /// Is attribute acceptable for top-level
    pub fn acceptable_tla(&self) -> bool {
        matches!(
            self.attr_type,
            MetaAttrType::DebugDerive
                | MetaAttrType::Complete
                | MetaAttrType::Debug
                | MetaAttrType::ExtraArgs
                | MetaAttrType::GenericErrors
                | MetaAttrType::InputName
                | MetaAttrType::LittleEndian
                | MetaAttrType::BigEndian
                | MetaAttrType::SetEndian
                | MetaAttrType::PreExec
                | MetaAttrType::PostExec
                | MetaAttrType::Exact
                | MetaAttrType::Selector
        )
    }

    /// Is attribute acceptable for field-level
    pub fn acceptable_fla(&self) -> bool {
        !matches!(
            self.attr_type,
            MetaAttrType::DebugDerive
                | MetaAttrType::Exact
                | MetaAttrType::ExtraArgs
                | MetaAttrType::GenericErrors
                | MetaAttrType::InputName
        )
    }

    #[inline]
    pub fn is_type(&self, attr_type: MetaAttrType) -> bool {
        self.attr_type == attr_type
    }

    #[inline]
    pub fn arg(&self) -> Option<&TokenStream> {
        self.arg0.as_ref()
    }
}

impl fmt::Display for MetaAttr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.attr_type)?;
        if let Some(arg) = &self.arg0 {
            write!(f, "({})", arg)?;
        }
        Ok(())
    }
}

impl Spanned for MetaAttr {
    fn span(&self) -> Span {
        self.span
    }
}

impl Parse for MetaAttr {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let ident: Ident = input.parse()?;
        let attr_type =
            MetaAttrType::from_ident(&ident).unwrap_or_else(|| panic!("Wrong meta name {}", ident));
        let arg0 = if attr_type.takes_argument() {
            // read (value), or ="value"
            let token_stream = match attr_type {
                MetaAttrType::ExtraArgs => {
                    let content;
                    let _paren_token = parenthesized!(content in input);
                    type ExpectedType = Punctuated<syn::Field, Token![,]>;
                    let fields: ExpectedType = content.parse_terminated(syn::Field::parse_named)?;
                    quote! { #fields }
                }
                MetaAttrType::PreExec | MetaAttrType::PostExec => {
                    parse_content::<syn::Stmt>(input)?
                }
                MetaAttrType::Selector => parse_content::<PatternAndGuard>(input)?,
                _ => parse_content::<syn::Expr>(input)?,
            };
            Some(token_stream)
        } else {
            None
        };
        Ok(MetaAttr::new(attr_type, arg0, ident.span()))
    }
}

fn parse_content<P>(input: ParseStream) -> syn::Result<TokenStream>
where
    P: Parse + ToTokens + fmt::Debug,
{
    if input.peek(Token![=]) {
        // eprintln!("Exec Peek: =");
        let _: Token![=] = input.parse()?;
        // next item is a string containing the real value
        let x = syn::Lit::parse(input)?;
        // eprintln!("content: {:?}", x);
        match x {
            syn::Lit::Str(s) => {
                let xx: P = s.parse()?;
                // eprintln!("xx: {:?}", xx);
                Ok(quote! { #xx })
            }
            _ => Err(syn::Error::new(
                x.span(),
                "Unexpected type for nom attribute content (!LitStr)",
            )),
        }
    } else if input.peek(token::Paren) {
        // eprintln!("Exec Peek: (");
        let content;
        let _paren_token = parenthesized!(content in input);
        let x = P::parse(&content)?;
        // let x: Punctuated<Type, Token![,]> = content.parse_terminated(Type::parse)?;
        // eprintln!("content: {:?}", x);
        Ok(quote! { #x })
    } else {
        Err(syn::Error::new(
            input.span(),
            "Unexpected type for nom attribute content (!LitStr)",
        ))
    }
}

#[derive(Debug)]
struct PatternAndGuard {
    pat: syn::Pat,
    guard: Option<(token::If, Box<syn::Expr>)>,
}

impl Parse for PatternAndGuard {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let pat = input.parse()?;
        let guard = if input.peek(Token![if]) {
            let tk_if: Token![if] = input.parse()?;
            let expr: syn::Expr = input.parse()?;
            Some((tk_if, Box::new(expr)))
        } else {
            None
        };
        Ok(PatternAndGuard { pat, guard })
    }
}

impl quote::ToTokens for PatternAndGuard {
    fn to_tokens(&self, tokens: &mut TokenStream) {
        self.pat.to_tokens(tokens);
        if let Some((tk_if, expr)) = &self.guard {
            tk_if.to_tokens(tokens);
            expr.to_tokens(tokens);
        }
    }
}
