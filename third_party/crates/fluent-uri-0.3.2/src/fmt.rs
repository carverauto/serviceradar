use crate::{
    component::{Authority, Host, Scheme},
    encoding::{EStr, EString, Encoder},
    error::{
        BuildError, BuildErrorKind, ParseError, ParseErrorKind, ResolveError, ResolveErrorKind,
    },
};
use core::fmt::{Debug, Display, Formatter, Result};

impl<E: Encoder> Debug for EStr<E> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Debug::fmt(self.as_str(), f)
    }
}

impl<E: Encoder> Display for EStr<E> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Display::fmt(self.as_str(), f)
    }
}

impl<E: Encoder> Debug for EString<E> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Debug::fmt(self.as_str(), f)
    }
}

impl<E: Encoder> Display for EString<E> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Display::fmt(self.as_str(), f)
    }
}

impl<I> Debug for ParseError<I> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        f.debug_struct("ParseError")
            .field("index", &self.index)
            .field("kind", &self.kind)
            .finish()
    }
}

impl<I> Display for ParseError<I> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        let msg = match self.kind {
            ParseErrorKind::InvalidOctet => "invalid percent-encoded octet at index ",
            ParseErrorKind::UnexpectedChar => "unexpected character at index ",
            ParseErrorKind::InvalidIpv6Addr => "invalid IPv6 address at index ",
            ParseErrorKind::NoScheme => return f.write_str("scheme not present"),
        };
        write!(f, "{}{}", msg, self.index)
    }
}

impl Display for BuildError {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        let msg = match self.0 {
            BuildErrorKind::NonAbemptyPath => {
                "path must either be empty or start with '/' when authority is present"
            }
            BuildErrorKind::PathStartingWithDoubleSlash => {
                "path cannot start with \"//\" when authority is absent"
            }
            BuildErrorKind::ColonInFirstPathSegment => {
                "first path segment cannot contain ':' in relative-path reference"
            }
        };
        f.write_str(msg)
    }
}

impl Display for ResolveError {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        let msg = match self.0 {
            ResolveErrorKind::InvalidBase => "base URI/IRI with fragment",
            ResolveErrorKind::OpaqueBase => {
                "relative reference must be empty or start with '#' when resolved against authority-less base URI/IRI with rootless path"
            }
        };
        f.write_str(msg)
    }
}

impl Debug for Scheme {
    #[inline]
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Debug::fmt(self.as_str(), f)
    }
}

impl Display for Scheme {
    #[inline]
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Display::fmt(self.as_str(), f)
    }
}

impl<RegNameE: Encoder> Debug for Host<'_, RegNameE> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        match self {
            #[cfg(feature = "net")]
            Host::Ipv4(addr) => f.debug_tuple("Ipv4").field(addr).finish(),
            #[cfg(feature = "net")]
            Host::Ipv6(addr) => f.debug_tuple("Ipv6").field(addr).finish(),

            #[cfg(not(feature = "net"))]
            Host::Ipv4() => f.debug_struct("Ipv4").finish_non_exhaustive(),
            #[cfg(not(feature = "net"))]
            Host::Ipv6() => f.debug_struct("Ipv6").finish_non_exhaustive(),

            Host::IpvFuture => f.debug_struct("IpvFuture").finish_non_exhaustive(),
            Host::RegName(name) => f.debug_tuple("RegName").field(name).finish(),
        }
    }
}

impl<UserinfoE: Encoder, RegNameE: Encoder> Debug for Authority<'_, UserinfoE, RegNameE> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        f.debug_struct("Authority")
            .field("userinfo", &self.userinfo())
            .field("host", &self.host())
            .field("host_parsed", &self.host_parsed())
            .field("port", &self.port())
            .finish()
    }
}

impl Display for Authority<'_> {
    #[inline]
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        Display::fmt(self.as_str(), f)
    }
}
