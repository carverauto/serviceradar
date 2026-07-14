use crate::config::*;
use crate::endian::*;
use crate::meta;
use crate::meta::attr::{MetaAttr, MetaAttrType};
use crate::parsertree::*;
use proc_macro2::{Span, TokenStream, TokenTree};
use quote::ToTokens;
use syn::spanned::Spanned;
use syn::*;

#[derive(Debug)]
pub(crate) struct StructParser {
    pub name: String,
    pub item: ParserTreeItem,
    pub pre_exec: Option<TokenStream>,
    pub post_exec: Option<TokenStream>,
}

impl StructParser {
    pub fn new(
        name: String,
        item: ParserTreeItem,
        pre_exec: Option<TokenStream>,
        post_exec: Option<TokenStream>,
    ) -> Self {
        StructParser {
            name,
            item,
            pre_exec,
            post_exec,
        }
    }
}

#[derive(Debug)]
pub(crate) struct StructParserTree {
    pub empty: bool,
    pub unnamed: bool,
    pub parsers: Vec<StructParser>,
}

fn get_type_parser(ty: &Type, meta_list: &[MetaAttr], config: &Config) -> Result<ParserExpr> {
    // special case: PhantomData
    let ident = get_type_first_ident(ty)?;
    if ident == "PhantomData" {
        return Ok(ParserExpr::PhantomData);
    }
    let endian = get_local_endianness(ty.span(), meta_list, config)?;
    match endian {
        ParserEndianness::BigEndian => Ok(ParserExpr::CallParseBE(TypeItem(ty.clone()))),
        ParserEndianness::LittleEndian => Ok(ParserExpr::CallParseLE(TypeItem(ty.clone()))),
        ParserEndianness::SetEndian => {
            let be = ParserExpr::CallParseBE(TypeItem(ty.clone()));
            let le = ParserExpr::CallParseLE(TypeItem(ty.clone()));
            let qq = quote! {
                if __endianness == nom::number::Endianness::Big {
                    #be
                } else {
                    #le
                }
            };
            Ok(ParserExpr::Raw(qq))
        }
        ParserEndianness::Unspecified => Ok(ParserExpr::CallParse(TypeItem(ty.clone()))),
    }
}

fn get_item_subtype_parser(ty: &Type, expected: &str, attr: &str) -> Result<TokenStream> {
    if let Type::Path(ref typepath) = ty {
        let path = &typepath.path;
        if path.segments.len() != 1 {
            return Err(Error::new(
                ty.span(),
                "Nom-derive: multiple segments in type path are not supported",
            ));
        }
        let segment = path.segments.last().expect("empty segments list");
        let ident_s = segment.ident.to_string();
        if ident_s == expected {
            // segment.arguments should contain the values, wrapped in AngleBracketed
            if let PathArguments::AngleBracketed(args) = &segment.arguments {
                return Ok(args.args.to_token_stream());
            }
        }
    }
    Err(Error::new(
        ty.span(),
        format!(
            "Nom-derive: unexpected type for {} attribute. Expected type: {}",
            attr, expected
        ),
    ))
}

pub(crate) fn get_type_first_ident(ty: &Type) -> Result<String> {
    match ty {
        Type::Path(ref typepath) => {
            let path = &typepath.path;
            if path.segments.len() != 1 {
                return Err(Error::new(
                    ty.span(),
                    "Nom-derive: multiple segments in type path are not supported",
                ));
            }
            let segment = path.segments.last().expect("empty segments list");
            let ident_s = segment.ident.to_string();
            Ok(ident_s)
        }
        Type::Array(ref typearray) => get_type_first_ident(&typearray.elem),
        _ => Err(Error::new(
            ty.span(),
            "Nom-derive: could not get first path ident",
        )),
    }
}

fn get_type_default(ty: &Type) -> Result<ParserExpr> {
    let ident_s = get_type_first_ident(ty)?;
    let default = match ident_s.as_ref() {
        // "u8" | "u16" | "u32" | "u64" | "u128" | "i8" | "i16" | "i32" | "i64" | "i128" => {
        //     "0".to_string()
        // }
        // "f32" | "f64" => "0.0".to_string(),
        "Option" => quote! { None },
        "PhantomData" => quote! { PhantomData },
        "Vec" => quote! { Vec::new() },
        _ => quote! { <#ty>::default() },
    };
    // ParserTree::Raw(format!("{{ |i| Ok((i, {})) }}", default))
    let ts = quote! {
        { |i| Ok((i, #default )) }
    };
    Ok(ParserExpr::Raw(ts))
}

fn get_parser(
    ident: Option<&Ident>,
    ty: &Type,
    // the list of remaining items to parse
    sub_meta_list: &[MetaAttr],
    // the list of all meta attributes for this type
    meta_list: &[MetaAttr],
    config: &Config,
) -> Result<ParserExpr> {
    // first check if we have attributes set
    // eprintln!("attrs: {:?}", field.attrs);
    // eprintln!("meta_list: {:?}", meta_list);
    let mut sub_meta_list = sub_meta_list;
    while let Some((meta, rem)) = sub_meta_list.split_first() {
        sub_meta_list = rem;
        // eprintln!("  meta {:?}", meta.attr_type);
        // eprintln!("  sub_meta_list: {:?}", sub_meta_list);
        match meta.attr_type {
            MetaAttrType::Tag => {
                let s = meta.arg().unwrap();
                return Ok(ParserExpr::Tag(s.clone()));
            }
            MetaAttrType::Take => {
                // if meta.arg is string, parse content
                let ts = meta.arg().unwrap();
                if let Some(TokenTree::Literal(_)) = ts.clone().into_iter().next() {
                    let ts = syn::parse2::<Expr>(ts.clone())?;
                    return Ok(ParserExpr::Take(ts.to_token_stream()));
                }
                let s = meta.arg().unwrap();
                return Ok(ParserExpr::Take(s.clone()));
            }
            MetaAttrType::Value => {
                let s = meta.arg().unwrap();
                return Ok(ParserExpr::Value(s.clone()));
            }
            MetaAttrType::Parse => {
                let s = meta.arg().unwrap();
                return Ok(ParserExpr::Raw(s.clone()));
            }
            MetaAttrType::Ignore => {
                return get_type_default(ty);
            }
            MetaAttrType::Complete => {
                let expr = get_parser(ident, ty, sub_meta_list, meta_list, config)?;
                return Ok(expr.complete());
            }
            MetaAttrType::Debug => {
                let expr = get_parser(ident, ty, sub_meta_list, meta_list, config)?;
                let ident = match ident {
                    Some(ident) => ident,
                    None => {
                        return Err(Error::new(
                            meta.span(),
                            "Nom-derive: can't use Verify with unnamed fields",
                        ))
                    }
                };
                return Ok(ParserExpr::DbgDmp(Box::new(expr), ident.clone()));
            }
            MetaAttrType::Cond => {
                // try to infer subparser
                // check type is Option<T>, and extract T
                let sub = get_item_subtype_parser(ty, "Option", "Cond")?;
                let sub_ty = syn::parse2::<Type>(sub)?;
                let expr = get_parser(ident, &sub_ty, sub_meta_list, meta_list, config)?;
                let ts = meta.arg().unwrap();
                return Ok(ParserExpr::Cond(Box::new(expr), ts.clone()));
            }
            MetaAttrType::Count => {
                // try to infer subparser
                // check type is Vec<T>, and extract T
                let sub = get_item_subtype_parser(ty, "Vec", "Count")?;
                let sub_ty = syn::parse2::<Type>(sub)?;
                let expr = get_parser(ident, &sub_ty, sub_meta_list, meta_list, config)?;
                let ts = meta.arg().unwrap();
                return Ok(ParserExpr::Count(Box::new(expr), ts.clone()));
            }
            MetaAttrType::Into => {
                let expr = get_parser(ident, ty, sub_meta_list, meta_list, config)?;
                return Ok(ParserExpr::Into(Box::new(expr)));
            }
            MetaAttrType::LengthCount => {
                // try to infer subparser
                // check type is Vec<T>, and extract T
                let sub = get_item_subtype_parser(ty, "Vec", "LengthCount")?;
                let sub_ty = syn::parse2::<Type>(sub)?;
                let expr = get_parser(ident, &sub_ty, sub_meta_list, meta_list, config)?;
                let ts = meta.arg().unwrap();
                return Ok(ParserExpr::LengthCount(Box::new(expr), ts.clone()));
            }
            MetaAttrType::Map => {
                let expr = get_parser(ident, ty, sub_meta_list, meta_list, config)?;
                // if meta.arg is string, parse content
                let ts_arg = meta.arg().unwrap();
                if let Some(TokenTree::Literal(_)) = ts_arg.clone().into_iter().next() {
                    let ts_arg = syn::parse2::<Expr>(ts_arg.clone())?;
                    return Ok(ParserExpr::Map(Box::new(expr), ts_arg.to_token_stream()));
                }
                let ts_arg = meta.arg().unwrap();
                return Ok(ParserExpr::Map(Box::new(expr), ts_arg.clone()));
            }
            MetaAttrType::Verify => {
                let expr = get_parser(ident, ty, sub_meta_list, meta_list, config)?;
                let ident = match ident {
                    Some(ident) => ident,
                    None => {
                        return Err(Error::new(
                            meta.span(),
                            "Nom-derive: can't use Verify with unnamed fields",
                        ))
                    }
                };
                // if meta.arg is string, parse content
                let ts_arg = meta.arg().unwrap();
                if let Some(TokenTree::Literal(_)) = ts_arg.clone().into_iter().next() {
                    let ts_arg = syn::parse2::<Expr>(ts_arg.clone())?;
                    return Ok(ParserExpr::Map(Box::new(expr), ts_arg.to_token_stream()));
                }
                let ts_arg = meta.arg().unwrap();
                return Ok(ParserExpr::Verify(
                    Box::new(expr),
                    ident.clone(),
                    ts_arg.clone(),
                ));
            }
            _ => (),
        }
    }
    // else try primitive types knowledge
    get_type_parser(ty, meta_list, config)
}

fn get_field_parser(field: &Field, meta_list: &[MetaAttr], config: &Config) -> Result<ParserExpr> {
    // eprintln!("field: {:?}", field);
    get_parser(
        field.ident.as_ref(),
        &field.ty,
        meta_list,
        meta_list,
        config,
    )
}

fn quote_align(align: &TokenStream, config: &Config) -> TokenStream {
    let input = syn::Ident::new(config.input_name(), align.span());
    let orig_input = syn::Ident::new(config.orig_input_name(), align.span());
    quote! {
        let (#input, _) = {
            let offset = #input.as_ptr() as usize - #orig_input.as_ptr() as usize;
            let align = #align as usize;
            let align = ((align - (offset % align)) % align);
            nom::bytes::streaming::take(align)(#input)
        }?;
    }
}

// like quote_skip, but offset is an isize
fn quote_move(offset: &TokenStream, config: &Config) -> TokenStream {
    let input = syn::Ident::new(config.input_name(), offset.span());
    let orig_input = syn::Ident::new(config.orig_input_name(), offset.span());
    quote! {
        let #input = {
            let start = #orig_input.as_ptr() as usize;
            let pos = #input.as_ptr() as usize - start;
            let offset = #offset as isize;
            let offset_u = offset.abs() as usize;
            let new_offset = if offset < 0 {
                if offset_u > pos {
                    return Err(nom::Err::Error(nom::error::make_error(#input, nom::error::ErrorKind::TooLarge)));
                }
                pos - offset_u
            } else {
                if pos + offset_u > #orig_input.len() {
                    return Err(nom::Err::Incomplete(nom::Needed::new(offset_u)));
                }
                pos + offset_u
            };
            &#orig_input[new_offset..]
        };
    }
}

// like quote_move, with absolute value as offset
fn quote_move_abs(offset: &TokenStream, config: &Config) -> TokenStream {
    let input = syn::Ident::new(config.input_name(), offset.span());
    let orig_input = syn::Ident::new(config.orig_input_name(), offset.span());
    quote! {
        let #input = {
            let offset = #offset as usize;
            if offset > #orig_input.len() {
                return Err(nom::Err::Incomplete(nom::Needed::new(offset)));
            }
            &#orig_input[offset..]
        };
    }
}

fn quote_skip(skip: &TokenStream, config: &Config) -> TokenStream {
    let input = syn::Ident::new(config.input_name(), skip.span());
    quote! {
        let (#input, _) = {
            let skip = #skip as usize;
            nom::bytes::streaming::take(skip)(#input)
        }?;
    }
}

fn quote_error_if(cond: &TokenStream, config: &Config) -> TokenStream {
    let input = syn::Ident::new(config.input_name(), cond.span());
    quote! {
        if #cond {
            return Err(nom::Err::Error(nom::error::make_error(#input, nom::error::ErrorKind::Verify)));
        }
    }
}

pub(crate) fn get_pre_post_exec(
    meta_list: &[MetaAttr],
    config: &Config,
) -> (Option<TokenStream>, Option<TokenStream>) {
    let mut tk_pre = proc_macro2::TokenStream::new();
    let mut tk_post = proc_macro2::TokenStream::new();
    for m in meta_list {
        match m.attr_type {
            MetaAttrType::PreExec => {
                tk_pre.extend(m.arg().unwrap().clone());
            }
            MetaAttrType::PostExec => {
                tk_post.extend(m.arg().unwrap().clone());
            }
            MetaAttrType::AlignAfter => {
                let align = m.arg().unwrap();
                let qq = quote_align(align, config);
                tk_post.extend(qq);
            }
            MetaAttrType::AlignBefore => {
                let align = m.arg().unwrap();
                let qq = quote_align(align, config);
                tk_pre.extend(qq);
            }
            MetaAttrType::SkipAfter => {
                let skip = m.arg().unwrap();
                let qq = quote_skip(skip, config);
                tk_post.extend(qq);
            }
            MetaAttrType::SkipBefore => {
                let skip = m.arg().unwrap();
                let qq = quote_skip(skip, config);
                tk_pre.extend(qq);
            }
            MetaAttrType::Move => {
                let offset = m.arg().unwrap();
                let qq = quote_move(offset, config);
                tk_pre.extend(qq);
            }
            MetaAttrType::MoveAbs => {
                let offset = m.arg().unwrap();
                let qq = quote_move_abs(offset, config);
                tk_pre.extend(qq);
            }
            MetaAttrType::ErrorIf => {
                let cond = m.arg().unwrap();
                let qq = quote_error_if(cond, config);
                tk_pre.extend(qq);
            }
            MetaAttrType::Exact => {
                let input = syn::Ident::new(config.input_name(), m.span());
                let cond = quote! { !#input.is_empty() };
                let qq = quote_error_if(&cond, config);
                tk_post.extend(qq);
            }
            MetaAttrType::SetEndian => {
                let val = m.arg().unwrap();
                let qq = quote! { let __endianness = #val; };
                // config is updated in `get_parser`
                tk_pre.extend(qq);
            }
            _ => (),
        }
    }
    let pre = if tk_pre.is_empty() {
        None
    } else {
        Some(tk_pre)
    };
    let post = if tk_post.is_empty() {
        None
    } else {
        Some(tk_post)
    };
    (pre, post)
}

pub(crate) fn parse_fields(f: &Fields, config: &mut Config) -> Result<StructParserTree> {
    let mut parsers = vec![];
    let mut empty = false;
    let mut unnamed = false;
    match f {
        Fields::Named(_) => (),
        Fields::Unnamed(_) => {
            unnamed = true;
        }
        Fields::Unit => {
            unnamed = false;
            empty = true;
            // the Parse attribute cannot be checked here (we only have 'Fields'),
            // so the caller must check and add attributes
        }
    }
    for (idx, field) in f.iter().enumerate() {
        let ident_str = if let Some(s) = field.ident.as_ref() {
            s.to_string()
        } else {
            format!("_{}", idx)
        };
        let meta_list = meta::parse_nom_attribute(&field.attrs)?;
        // eprintln!("meta_list: {:?}", meta_list);
        let mut p = get_field_parser(field, &meta_list, config)?;

        if config.complete {
            p = p.complete();
        }

        if config.debug {
            // debug is set for entire struct
            let ident = match &field.ident {
                Some(ident) => ident,
                None => {
                    return Err(Error::new(
                        Span::call_site(),
                        "Nom-derive: can't use Debug with unnamed fields",
                    ))
                }
            };
            p = ParserExpr::DbgDmp(Box::new(p), ident.clone());
        }

        // add pre and post code (also takes care of alignment)
        let (pre, post) = get_pre_post_exec(&meta_list, config);
        let item = ParserTreeItem::new(field.ident.clone(), p);
        let sp = StructParser::new(ident_str, item, pre, post);
        parsers.push(sp);
    }
    Ok(StructParserTree {
        empty,
        unnamed,
        parsers,
    })
}

pub(crate) fn parse_struct(s: &DataStruct, config: &mut Config) -> Result<StructParserTree> {
    parse_fields(&s.fields, config)
}
