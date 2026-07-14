pub mod attr;
pub mod attr_list;
pub mod error;

use syn::{spanned::Spanned, Error, Result};

pub fn parse_nom_top_level_attribute(attrs: &[syn::Attribute]) -> Result<Vec<attr::MetaAttr>> {
    // eprintln!("attrs: {:?}", attrs);
    let x: Vec<_> = attrs
        .iter()
        .filter_map(|x| {
            if x.path.is_ident("nom") {
                Some(meta_from_attribute(x))
            } else {
                None
            }
        })
        .collect::<std::result::Result<Vec<_>, _>>()?
        .into_iter()
        .flat_map(|x| x.0.into_iter())
        .collect();
    // eprintln!("XXX: {:?}", x);
    if let Some(attr) = x.iter().find(|m| !m.acceptable_tla()) {
        return Err(Error::new(
            attr.span(),
            format!("Attribute {} is not valid for top-level", attr),
        ));
    }
    Ok(x)
}

fn meta_from_attribute(attr: &syn::Attribute) -> Result<attr_list::AttrList<attr::MetaAttr>> {
    // eprintln!("tlas_from_attribute: {:?}", attr);
    syn::parse2(attr.tokens.clone())
}

pub fn parse_nom_attribute(attrs: &[syn::Attribute]) -> Result<Vec<attr::MetaAttr>> {
    // eprintln!("attrs: {:?}", attrs);
    let x: Vec<_> = attrs
        .iter()
        .filter_map(|x| {
            if x.path.is_ident("nom") {
                Some(meta_from_attribute(x))
            } else {
                None
            }
        })
        .collect::<std::result::Result<Vec<_>, _>>()?
        .into_iter()
        .flat_map(|x| x.0.into_iter())
        .collect();
    // eprintln!("****\nXXX: {:?}\n", x);
    if let Some(attr) = x.iter().find(|m| !m.acceptable_fla()) {
        return Err(Error::new(
            attr.span(),
            format!("Attribute {} is not valid for field-level", attr),
        ));
    }
    Ok(x)
}
