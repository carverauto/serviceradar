//! Private class field.

use crate::{
    Choice, Class, Decode, DecodeValue, DerOrd, Encode, EncodeValue, EncodeValueRef, Error, Header,
    Length, Reader, Tag, TagMode, TagNumber, Tagged, ValueOrd, Writer, asn1::AnyRef,
    tag::IsConstructed,
};
use core::cmp::Ordering;

#[cfg(doc)]
use crate::ErrorKind;

impl_custom_class!(Private, Private, "PRIVATE", "0b11000000");
impl_custom_class_ref!(PrivateRef, Private, "PRIVATE", "0b11000000");
