use crate::endian::ParserEndianness;
use crate::meta::attr::{MetaAttr, MetaAttrType};
use proc_macro2::{Span, TokenStream};
use syn::{spanned::Spanned, Error};

#[derive(Debug)]
pub struct Config {
    pub struct_name: String,
    /// Endianness for all parsers, if specified
    pub global_endianness: ParserEndianness,
    /// Endianness for this struct or enum, if specified
    pub object_endianness: ParserEndianness,
    /// Complete option for this struct (default: streaming)
    pub complete: bool,
    pub debug: bool,
    pub debug_derive: bool,
    pub generic_errors: bool,
    selector_type: Option<TokenStream>,
    selector_name: Option<String>,
    input_name: String,
    orig_input_name: String,
    lifetime_name: String,
    error_name: String,
}

impl Config {
    pub fn from_meta_list(name: String, l: &[MetaAttr]) -> Result<Self, Error> {
        let mut req_big_endian = false;
        let mut req_little_endian = false;
        let mut complete = false;
        let mut debug = false;
        let mut debug_derive = false;
        let mut generic_errors = false;
        let mut span_endian = None;
        for meta in l {
            match meta.attr_type {
                MetaAttrType::BigEndian => {
                    req_big_endian = true;
                    span_endian = Some(meta.span());
                }
                MetaAttrType::LittleEndian => req_little_endian = true,
                MetaAttrType::Complete => complete = true,
                MetaAttrType::Debug => debug = true,
                MetaAttrType::DebugDerive => debug_derive = true,
                MetaAttrType::GenericErrors => generic_errors = true,
                _ => (),
            }
        }
        if req_big_endian & req_little_endian {
            return Err(Error::new(
                span_endian.unwrap_or_else(Span::call_site),
                "Struct cannot be both big and little endian",
            ));
        }
        let object_endianness = if req_big_endian {
            ParserEndianness::BigEndian
        } else if req_little_endian {
            ParserEndianness::LittleEndian
        } else {
            ParserEndianness::Unspecified
        };
        let input_name = l
            .iter()
            .find_map(|m| {
                if m.is_type(MetaAttrType::InputName) {
                    Some(m.arg().unwrap().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "i".to_string());
        let selector_type = l.iter().find_map(|m| {
            if m.is_type(MetaAttrType::Selector) {
                Some(m.arg().unwrap().clone())
            } else {
                None
            }
        });
        let selector_name = if selector_type.is_some() {
            Some(String::from("selector"))
        } else {
            None
        };
        Ok(Config {
            struct_name: name,
            global_endianness: ParserEndianness::Unspecified,
            object_endianness,
            complete,
            debug,
            debug_derive,
            generic_errors,
            selector_type,
            selector_name,
            orig_input_name: "orig_".to_string() + &input_name,
            lifetime_name: String::from("'nom"),
            error_name: String::from("NomErr"),
            input_name,
        })
    }

    #[inline]
    pub fn selector_type(&self) -> Option<&TokenStream> {
        self.selector_type.as_ref()
    }

    #[inline]
    pub fn selector_name(&self) -> Option<&str> {
        self.selector_name.as_ref().map(|s| s.as_ref())
    }

    #[inline]
    pub fn input_name(&self) -> &str {
        &self.input_name
    }

    #[inline]
    pub fn orig_input_name(&self) -> &str {
        &self.orig_input_name
    }

    #[inline]
    pub fn lifetime_name(&self) -> &str {
        &self.lifetime_name
    }

    #[inline]
    pub fn error_name(&self) -> &str {
        &self.error_name
    }
}
