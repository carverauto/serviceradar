#![allow(missing_debug_implementations)]

use crate::{
    encoding::{encoder, Encoder},
    error::ParseError,
    parser,
};
use alloc::string::String;
use core::{num::NonZeroUsize, str};

#[cfg(feature = "net")]
use crate::net::{Ipv4Addr, Ipv6Addr};

pub trait Value: Default {}

impl Value for &str {}
impl Value for String {}

pub struct NoInput;

pub struct Criteria {
    pub must_be_ascii: bool,
    pub must_have_scheme: bool,
}

pub trait RiRef: Sized {
    type Val;
    type UserinfoE: Encoder;
    type RegNameE: Encoder;
    type PathE: Encoder;
    type QueryE: Encoder;
    type FragmentE: Encoder;

    fn new(val: Self::Val, meta: Meta) -> Self;

    fn from_pair((val, meta): (Self::Val, Meta)) -> Self {
        Self::new(val, meta)
    }

    fn criteria() -> Criteria;
}

pub trait Parse {
    type Val;
    type Err;

    fn parse<R: RiRef<Val = Self::Val>>(self) -> Result<R, Self::Err>;
}

impl<'a> Parse for &'a str {
    type Val = &'a str;
    type Err = ParseError;

    fn parse<R: RiRef<Val = Self::Val>>(self) -> Result<R, Self::Err> {
        parser::parse(self.as_bytes(), R::criteria()).map(|meta| R::new(self, meta))
    }
}

impl Parse for String {
    type Val = String;
    type Err = ParseError<String>;

    fn parse<R: RiRef<Val = Self::Val>>(self) -> Result<R, Self::Err> {
        match parser::parse(self.as_bytes(), R::criteria()) {
            Ok(meta) => Ok(R::new(self, meta)),
            Err(e) => Err(e.with_input(self)),
        }
    }
}

#[derive(Clone, Copy, Default)]
pub struct Meta {
    // The index of the trailing colon.
    pub scheme_end: Option<NonZeroUsize>,
    pub auth_meta: Option<AuthMeta>,
    pub path_bounds: (usize, usize),
    // One byte past the last byte of query.
    pub query_end: Option<NonZeroUsize>,
}

impl Meta {
    #[inline]
    pub fn query_or_path_end(&self) -> usize {
        self.query_end.map_or(self.path_bounds.1, |i| i.get())
    }
}

#[derive(Clone, Copy, Default)]
pub struct AuthMeta {
    pub host_bounds: (usize, usize),
    pub host_meta: HostMeta,
}

impl AuthMeta {
    pub const EMPTY: Self = Self {
        host_bounds: (0, 0),
        host_meta: HostMeta::RegName,
    };
}

#[derive(Clone, Copy, Default)]
pub enum HostMeta {
    Ipv4(#[cfg(feature = "net")] Ipv4Addr),
    Ipv6(#[cfg(feature = "net")] Ipv6Addr),
    IpvFuture,
    #[default]
    RegName,
}

pub trait PathEncoder: Encoder {}

impl PathEncoder for encoder::Path {}
impl PathEncoder for encoder::IPath {}
