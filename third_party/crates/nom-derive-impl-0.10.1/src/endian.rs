use crate::config::*;
use crate::meta::attr::{MetaAttr, MetaAttrType};
use proc_macro2::Span;
use syn::{spanned::Spanned, Error, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParserEndianness {
    Unspecified,
    LittleEndian,
    BigEndian,
    SetEndian,
}

pub fn get_object_endianness(config: &Config) -> ParserEndianness {
    // first, check struct endianness
    if config.object_endianness != ParserEndianness::Unspecified {
        return config.object_endianness;
    }
    // finally, return global endianness
    config.global_endianness
}

pub fn set_object_endianness(
    span: Span,
    endianness: ParserEndianness,
    meta_list: &[MetaAttr],
    config: &mut Config,
) -> Result<()> {
    config.object_endianness = endianness;
    // first, check local attribute
    let mut req_big_endian = false;
    let mut req_little_endian = false;
    let mut req_set_endian = false;
    let mut span_endian = None;
    for meta in meta_list {
        match meta.attr_type {
            MetaAttrType::BigEndian => req_big_endian = true,
            MetaAttrType::LittleEndian => req_little_endian = true,
            MetaAttrType::SetEndian => req_set_endian = true,
            _ => continue,
        }
        span_endian = Some(meta.span());
    }
    // test if 2 or more flags are set
    if two_or_more(req_big_endian, req_little_endian, req_set_endian) {
        return Err(Error::new(
            span_endian.unwrap_or(span),
            "cannot be both big, little and/or set endian",
        ));
    }
    if req_big_endian {
        config.object_endianness = ParserEndianness::BigEndian;
    } else if req_little_endian {
        config.object_endianness = ParserEndianness::LittleEndian;
    } else if req_set_endian {
        config.object_endianness = ParserEndianness::SetEndian;
    };
    Ok(())
}

fn two_or_more(a: bool, b: bool, c: bool) -> bool {
    if a {
        b | c
    } else {
        b & c
    }
}

pub fn get_local_endianness(
    span: Span,
    meta_list: &[MetaAttr],
    config: &Config,
) -> Result<ParserEndianness> {
    // first, check local attribute
    let mut req_big_endian = false;
    let mut req_little_endian = false;
    let mut req_set_endian = false;
    for meta in meta_list {
        match meta.attr_type {
            MetaAttrType::BigEndian => req_big_endian = true,
            MetaAttrType::LittleEndian => req_little_endian = true,
            MetaAttrType::SetEndian => req_set_endian = true,
            _ => (),
        }
    }
    // test if 2 or more flags are set
    if two_or_more(req_big_endian, req_little_endian, req_set_endian) {
        return Err(Error::new(
            span,
            "cannot be both big, little and/or set endian",
        ));
    }
    if req_big_endian {
        return Ok(ParserEndianness::BigEndian);
    } else if req_little_endian {
        return Ok(ParserEndianness::LittleEndian);
    } else if req_set_endian {
        return Ok(ParserEndianness::SetEndian);
    };
    // otherwise, get object-level endianness
    Ok(get_object_endianness(config))
}

pub fn validate_endianness(
    attr_endianness: ParserEndianness,
    object_endianness: ParserEndianness,
    global_endianness: ParserEndianness,
) -> Result<()> {
    let mut req_big_endian = false;
    let mut req_little_endian = false;
    let mut req_set_endian = false;

    match attr_endianness {
        ParserEndianness::Unspecified => (),
        ParserEndianness::BigEndian => req_big_endian = true,
        ParserEndianness::LittleEndian => req_little_endian = true,
        _ => unreachable!(),
    }

    match object_endianness {
        ParserEndianness::Unspecified => (),
        ParserEndianness::BigEndian => req_big_endian = true,
        ParserEndianness::LittleEndian => req_little_endian = true,
        ParserEndianness::SetEndian => req_set_endian = true,
    }

    match global_endianness {
        ParserEndianness::Unspecified => (),
        ParserEndianness::BigEndian => req_big_endian = true,
        ParserEndianness::LittleEndian => req_little_endian = true,
        _ => unreachable!(),
    }

    if req_big_endian & req_little_endian {
        return Err(Error::new(
            Span::call_site(),
            "Object cannot be both big and little endian",
        ));
    }

    if req_set_endian & (req_big_endian | req_little_endian) {
        return Err(Error::new(
            Span::call_site(),
            "Object cannot be both SetEndian, and specify big or little endian",
        ));
    }

    Ok(())
}
