use crate::{endian::ParserEndianness, enums::is_input_fieldless_enum, meta};
use proc_macro2::{Span, TokenStream};
use syn::*;

mod enums;
mod fieldless_enums;
mod generator;
mod structs;

use enums::GenEnum;
use fieldless_enums::GenFieldlessEnum;
pub(crate) use generator::*;
use structs::GenStruct;

pub(crate) fn gen_impl(
    ast: &syn::DeriveInput,
    endianness: ParserEndianness,
) -> Result<TokenStream> {
    // eprintln!("ast: {:#?}", ast);
    let generator: Box<dyn Generator> = match &ast.data {
        syn::Data::Enum(_) => {
            // look for a selector
            let meta = meta::parse_nom_top_level_attribute(&ast.attrs)?;
            if meta
                .iter()
                .any(|m| m.is_type(meta::attr::MetaAttrType::Selector))
            {
                Box::new(GenEnum::from_ast(ast, endianness)?)
            } else {
                // no selector, try fieldless enum
                if is_input_fieldless_enum(ast) {
                    Box::new(GenFieldlessEnum::from_ast(ast, endianness)?)
                } else {
                    return Err(Error::new(
                        ast.ident.span(),
                        "Nom-derive: enums must have a 'selector' attribute",
                    ));
                }
            }
        }
        syn::Data::Struct(_) => Box::new(GenStruct::from_ast(ast, endianness)?),
        syn::Data::Union(_) => panic!("Unions not supported"),
    };

    let impl_tokens = generator.gen_impl()?;
    // eprintln!("\n***\nglobal_impl: {}\n---\n", impl_tokens);
    Ok(impl_tokens)
}
