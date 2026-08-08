use std::{collections::BTreeMap, iter::FromIterator};

use syn::{
    meta::ParseNestedMeta, punctuated::Punctuated, token::Paren, Attribute, Expr, Lit, LitStr,
    Token,
};

use super::Symbol;

fn get_lit_str2(
    attr_name: Symbol,
    meta_item_name: Symbol,
    meta: &ParseNestedMeta,
) -> syn::Result<LitStr> {
    let expr: Expr = meta.value()?.parse()?;
    let mut value = &expr;
    while let Expr::Group(e) = value {
        value = &e.expr;
    }
    if let Expr::Lit(syn::ExprLit {
        lit: Lit::Str(lit), ..
    }) = value
    {
        Ok(lit.clone())
    } else {
        Err(syn::Error::new_spanned(
            expr,
            format!(
                "expected borsh {} attribute to be a string: `{} = \"...\"`",
                attr_name.0, meta_item_name.0
            ),
        ))
    }
}

pub(super) fn parse_lit_into<T: syn::parse::Parse>(
    attr_name: Symbol,
    meta_item_name: Symbol,
    meta: &ParseNestedMeta,
) -> syn::Result<T> {
    let string = get_lit_str2(attr_name, meta_item_name, meta)?;

    match string.parse() {
        Ok(expr) => Ok(expr),
        Err(err) => Err(syn::Error::new_spanned(string, err)),
    }
}

pub(super) fn parse_lit_into_vec<T: syn::parse::Parse>(
    attr_name: Symbol,
    meta_item_name: Symbol,
    meta: &ParseNestedMeta,
) -> syn::Result<Vec<T>> {
    let string = get_lit_str2(attr_name, meta_item_name, meta)?;

    match string.parse_with(Punctuated::<T, Token![,]>::parse_terminated) {
        Ok(elements) => Ok(Vec::from_iter(elements)),
        Err(err) => Err(syn::Error::new_spanned(string, err)),
    }
}

fn get_nested_meta_logic<T, F>(
    attr_name: Symbol,
    meta: ParseNestedMeta,
    map: &BTreeMap<Symbol, F>,
    result: &mut BTreeMap<Symbol, T>,
) -> syn::Result<()>
where
    F: Fn(Symbol, Symbol, &ParseNestedMeta) -> syn::Result<T>,
{
    let mut match_ = false;
    for (symbol_key, func) in map.iter() {
        if meta.path == *symbol_key {
            // This duplicate check runs at every nesting level: at the top
            // level (via `attrs_get_by_symbol_keys` / `meta_get_by_symbol_keys`)
            // and again for keys nested inside a group such as `schema(...)`,
            // whose `func` recurses through `meta_get_by_symbol_keys` with its
            // own `result`. So a key repeated at the same level is rejected here
            // -- whether it is a top-level key spread across several
            // `#[borsh(...)]` attributes or a nested key such as
            // `schema(params = ...)` supplied twice.
            //
            // Merging is per key at a single level, not a deep merge: `schema`
            // is itself one top-level key, so two separate `schema(...)` groups
            // collide rather than having their inner keys combined -- inner keys
            // must be written together inside one group.
            //
            // Before this check a repeated key silently kept the last `v`
            // produced by `func` (the `insert` below overwrote the earlier one);
            // it is now an error instead.
            if result.contains_key(symbol_key) {
                return Err(meta.error(format_args!("duplicate `{}` attribute", symbol_key.0)));
            }
            let v = func(attr_name, *symbol_key, &meta)?;
            result.insert(*symbol_key, v);
            match_ = true;
        }
    }
    if !match_ {
        let keys_strs = map.keys().map(|symbol| symbol.1).collect::<Vec<_>>();
        let keys_strs = keys_strs.join(", ");
        return Err(meta.error(format_args!(
            "malformed {0} attribute, expected `{0}({1})`",
            attr_name.0, keys_strs
        )));
    }
    Ok(())
}

pub(super) fn meta_get_by_symbol_keys<T, F>(
    attr_name: Symbol,
    meta: &ParseNestedMeta,
    map: &BTreeMap<Symbol, F>,
) -> syn::Result<BTreeMap<Symbol, T>>
where
    F: Fn(Symbol, Symbol, &ParseNestedMeta) -> syn::Result<T>,
{
    let mut result = BTreeMap::new();

    let lookahead = meta.input.lookahead1();
    if lookahead.peek(Paren) {
        meta.parse_nested_meta(|meta| get_nested_meta_logic(attr_name, meta, map, &mut result))?;
    } else {
        return Err(lookahead.error());
    }

    Ok(result)
}

/// Parses the nested meta of every given `#[borsh(...)]` attribute, folding
/// them into a single shared map.
///
/// Disjoint top-level keys spread across multiple attributes merge cleanly. A
/// top-level key supplied more than once (whether within one attribute or
/// across several) is reported as a duplicate by [`get_nested_meta_logic`].
pub(super) fn attrs_get_by_symbol_keys<T, F>(
    attr_name: Symbol,
    attrs: &[&Attribute],
    map: &BTreeMap<Symbol, F>,
) -> syn::Result<BTreeMap<Symbol, T>>
where
    F: Fn(Symbol, Symbol, &ParseNestedMeta) -> syn::Result<T>,
{
    let mut result = BTreeMap::new();

    for attr in attrs {
        attr.parse_nested_meta(|meta| get_nested_meta_logic(attr_name, meta, map, &mut result))?;
    }

    Ok(result)
}
