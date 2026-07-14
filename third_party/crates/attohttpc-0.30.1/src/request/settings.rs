use std::sync::Arc;
use std::time::Duration;

use http::header::IntoHeaderName;
use http::{HeaderMap, HeaderValue};

#[cfg(feature = "charsets")]
use crate::charsets::Charset;
use crate::error::{Error, Result};
use crate::request::proxy::ProxySettings;
use crate::skip_debug::SkipDebug;
use crate::tls::Certificate;

use super::{header_append, header_insert};

#[derive(Clone, Debug)]
pub struct BaseSettings {
    pub headers: HeaderMap,
    pub root_certificates: SkipDebug<Vec<Certificate>>,
    pub max_headers: usize,
    pub max_redirections: u32,
    pub follow_redirects: bool,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
    pub timeout: Option<Duration>,
    pub proxy_settings: ProxySettings,
    pub accept_invalid_certs: bool,
    pub accept_invalid_hostnames: bool,
    #[cfg(feature = "charsets")]
    pub default_charset: Option<Charset>,
    #[cfg(feature = "flate2")]
    pub allow_compression: bool,
}

impl Default for BaseSettings {
    fn default() -> Self {
        BaseSettings {
            headers: HeaderMap::new(),
            max_headers: 100,
            max_redirections: 5,
            follow_redirects: true,
            connect_timeout: Duration::from_secs(30),
            read_timeout: Duration::from_secs(30),
            timeout: None,
            proxy_settings: ProxySettings::from_env(),
            accept_invalid_certs: false,
            accept_invalid_hostnames: false,
            root_certificates: SkipDebug(Vec::new()),

            #[cfg(feature = "charsets")]
            default_charset: None,
            #[cfg(feature = "flate2")]
            allow_compression: true,
        }
    }
}

macro_rules! basic_setter {
    ($name:ident, $param:ident, $type:ty) => {
        #[inline]
        pub(crate) fn $name(self: &mut Arc<Self>, $param: $type) {
            Arc::make_mut(self).$param = $param;
        }
    };
}

impl BaseSettings {
    #[inline]
    fn headers_mut(self: &mut Arc<Self>) -> &mut HeaderMap {
        &mut Arc::make_mut(self).headers
    }

    #[inline]
    pub(crate) fn try_header<H, V>(self: &mut Arc<Self>, header: H, value: V) -> Result<()>
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        header_insert(self.headers_mut(), header, value)
    }

    #[inline]
    pub(crate) fn try_header_append<H, V>(self: &mut Arc<Self>, header: H, value: V) -> Result<()>
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        header_append(self.headers_mut(), header, value)
    }

    #[inline]
    pub(crate) fn add_root_certificate(self: &mut Arc<Self>, cert: Certificate) {
        Arc::make_mut(self).root_certificates.0.push(cert);
    }

    basic_setter!(set_max_headers, max_headers, usize);
    basic_setter!(set_max_redirections, max_redirections, u32);
    basic_setter!(set_follow_redirects, follow_redirects, bool);
    basic_setter!(set_connect_timeout, connect_timeout, Duration);
    basic_setter!(set_read_tmeout, read_timeout, Duration);
    basic_setter!(set_timeout, timeout, Option<Duration>);
    basic_setter!(set_proxy_settings, proxy_settings, ProxySettings);
    basic_setter!(set_accept_invalid_certs, accept_invalid_certs, bool);
    basic_setter!(set_accept_invalid_hostnames, accept_invalid_hostnames, bool);
    #[cfg(feature = "charsets")]
    basic_setter!(set_default_charset, default_charset, Option<Charset>);
    #[cfg(feature = "flate2")]
    basic_setter!(set_allow_compression, allow_compression, bool);
}
