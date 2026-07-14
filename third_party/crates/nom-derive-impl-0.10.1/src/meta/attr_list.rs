use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::{parenthesized, Token};

#[derive(Debug)]
pub struct AttrList<T: Parse>(pub Vec<T>);

impl<T: Parse> Parse for AttrList<T> {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        // eprintln!("AttrList::parse: {:?}", input);
        let content;
        parenthesized!(content in input);
        Ok(AttrList(
            Punctuated::<T, Token![,]>::parse_terminated(&content)?
                .into_iter()
                .collect(),
        ))
    }
}
