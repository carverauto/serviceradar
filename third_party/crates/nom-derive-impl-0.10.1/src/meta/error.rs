use std::convert::From;

#[derive(Debug)]
pub struct MetaError;

impl From<syn::Error> for MetaError {
    fn from(_e: syn::Error) -> Self {
        MetaError
    }
}
