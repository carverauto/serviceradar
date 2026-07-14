use std::{env, vec};

use url::Url;

fn get_env(name: &str) -> Option<String> {
    match env::var(name.to_ascii_lowercase()).or_else(|_| env::var(name.to_ascii_uppercase())) {
        Ok(s) => Some(s),
        Err(env::VarError::NotPresent) => None,
        Err(env::VarError::NotUnicode(_)) => {
            warn!(
                "Environment variable {} contains non-unicode characters",
                name.to_ascii_uppercase()
            );
            None
        }
    }
}

fn get_env_url(name: &str) -> Option<Url> {
    match get_env(name) {
        Some(val) if val.trim().is_empty() => None,
        Some(val) => match Url::parse(&val) {
            Ok(url) => match url.scheme() {
                "http" | "https" => Some(url),
                _ => {
                    warn!(
                        "Environment variable {} contains unsupported proxy scheme: {}",
                        name.to_ascii_uppercase(),
                        url.scheme()
                    );
                    None
                }
            },
            Err(err) => {
                warn!(
                    "Environment variable {} contains invalid URL: {}",
                    name.to_ascii_uppercase(),
                    err
                );
                None
            }
        },
        None => None,
    }
}

/// Contains proxy settings and utilities to find which proxy to use for a given URL.
#[derive(Clone, Debug)]
pub struct ProxySettings {
    http_proxy: Option<Url>,
    https_proxy: Option<Url>,
    disable_proxies: bool,
    no_proxy_hosts: Vec<String>,
}

impl ProxySettings {
    /// Get a new builder for ProxySettings.
    pub fn builder() -> ProxySettingsBuilder {
        ProxySettingsBuilder::new()
    }

    /// Get the proxy configuration from the environment using the `curl`/Unix proxy conventions.
    ///
    /// Only `ALL_PROXY`, `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` are supported.
    /// Proxies can be disabled on all requests by setting `NO_PROXY` to `*`, similar to `curl`.
    /// `HTTP_PROXY` or `HTTPS_PROXY` take precedence over values set by `ALL_PROXY` for their
    /// respective schemes.
    ///
    /// See <https://curl.se/docs/manpage.html#--noproxy>
    pub fn from_env() -> ProxySettings {
        let all_proxy = get_env_url("all_proxy");
        let http_proxy = get_env_url("http_proxy");
        let https_proxy = get_env_url("https_proxy");
        let no_proxy = get_env("no_proxy");

        let disable_proxies = no_proxy.as_deref().unwrap_or("") == "*";
        let mut no_proxy_hosts = vec![];

        if !disable_proxies {
            if let Some(no_proxy) = no_proxy {
                no_proxy_hosts.extend(
                    no_proxy
                        .split(',')
                        .map(|s| s.trim().trim_start_matches('.').to_lowercase()),
                );
            }
        }

        ProxySettings {
            http_proxy: http_proxy.or_else(|| all_proxy.clone()),
            https_proxy: https_proxy.or(all_proxy),
            disable_proxies,
            no_proxy_hosts,
        }
    }

    /// Get the proxy URL to use for the given URL.
    ///
    /// None is returned if there is no proxy configured for the scheme or if the hostname
    /// matches a pattern in the no proxy list.
    pub fn for_url(&self, url: &Url) -> Option<&Url> {
        if self.disable_proxies {
            return None;
        }

        if let Some(host) = url.host_str() {
            if !self
                .no_proxy_hosts
                .iter()
                .any(|x| host.ends_with(x.to_lowercase().as_str()))
            {
                return match url.scheme() {
                    "http" => self.http_proxy.as_ref(),
                    "https" => self.https_proxy.as_ref(),
                    _ => None,
                };
            }
        }
        None
    }
}

/// Utility to build ProxySettings easily.
#[derive(Clone, Debug)]
pub struct ProxySettingsBuilder {
    inner: ProxySettings,
}

impl ProxySettingsBuilder {
    /// Create a new ProxySetting builder with no initial configuration.
    pub fn new() -> Self {
        ProxySettingsBuilder {
            inner: ProxySettings {
                http_proxy: None,
                https_proxy: None,
                disable_proxies: false,
                no_proxy_hosts: vec![],
            },
        }
    }

    /// Set the proxy for http requests.
    pub fn http_proxy<V>(mut self, val: V) -> Self
    where
        V: Into<Option<Url>>,
    {
        self.inner.http_proxy = val.into();
        self
    }

    /// Set the proxy for https requests.
    pub fn https_proxy<V>(mut self, val: V) -> Self
    where
        V: Into<Option<Url>>,
    {
        self.inner.https_proxy = val.into();
        self
    }

    /// Add a hostname pattern to ignore when finding the proxy to use for a URL.
    ///
    /// For instance `mycompany.local` will make requests with the hostname `mycompany.local`
    /// not go trough the proxy.
    pub fn add_no_proxy_host(mut self, pattern: impl AsRef<str>) -> Self {
        self.inner.no_proxy_hosts.push(pattern.as_ref().to_lowercase());
        self
    }

    /// Build the settings.
    pub fn build(self) -> ProxySettings {
        self.inner
    }
}

impl Default for ProxySettingsBuilder {
    fn default() -> Self {
        ProxySettingsBuilder::new()
    }
}

#[test]
fn test_proxy_for_url() {
    let s = ProxySettings {
        http_proxy: Some("http://proxy1:3128".parse().unwrap()),
        https_proxy: Some("http://proxy2:3128".parse().unwrap()),
        disable_proxies: false,
        no_proxy_hosts: vec!["reddit.com".into()],
    };

    assert_eq!(
        s.for_url(&Url::parse("http://google.ca").unwrap()),
        Some(&"http://proxy1:3128".parse().unwrap())
    );

    assert_eq!(
        s.for_url(&Url::parse("https://google.ca").unwrap()),
        Some(&"http://proxy2:3128".parse().unwrap())
    );

    assert_eq!(s.for_url(&Url::parse("https://reddit.com").unwrap()), None);
}

#[test]
fn test_proxy_for_url_disabled() {
    let s = ProxySettings {
        http_proxy: Some("http://proxy1:3128".parse().unwrap()),
        https_proxy: Some("http://proxy2:3128".parse().unwrap()),
        disable_proxies: true,
        no_proxy_hosts: vec![],
    };

    assert_eq!(s.for_url(&Url::parse("https://reddit.com").unwrap()), None);
    assert_eq!(s.for_url(&Url::parse("https://www.google.ca").unwrap()), None);
}

#[cfg(test)]
fn with_reset_proxy_vars<T>(test: T)
where
    T: FnOnce() + std::panic::UnwindSafe,
{
    use std::sync::Mutex;

    lazy_static::lazy_static! {
        static ref LOCK: Mutex<()> = Mutex::new(());
    };

    let _guard = LOCK.lock().unwrap();

    env::remove_var("ALL_PROXY");
    env::remove_var("HTTP_PROXY");
    env::remove_var("HTTPS_PROXY");
    env::remove_var("NO_PROXY");

    let result = std::panic::catch_unwind(test);

    // teardown if ever needed

    if let Err(ctx) = result {
        std::panic::resume_unwind(ctx);
    }
}

#[test]
fn test_proxy_from_env_all_proxy() {
    with_reset_proxy_vars(|| {
        env::set_var("ALL_PROXY", "http://proxy:3128");

        let s = ProxySettings::from_env();

        assert_eq!(s.http_proxy.unwrap().as_str(), "http://proxy:3128/");
        assert_eq!(s.https_proxy.unwrap().as_str(), "http://proxy:3128/");
    });
}

#[test]
fn test_proxy_from_env_override() {
    with_reset_proxy_vars(|| {
        env::set_var("ALL_PROXY", "http://proxy:3128");
        env::set_var("HTTP_PROXY", "http://proxy:3129");
        env::set_var("HTTPS_PROXY", "http://proxy:3130");

        let s = ProxySettings::from_env();

        assert_eq!(s.http_proxy.unwrap().as_str(), "http://proxy:3129/");
        assert_eq!(s.https_proxy.unwrap().as_str(), "http://proxy:3130/");
    });
}

#[test]
fn test_proxy_from_env_no_proxy_wildcard() {
    with_reset_proxy_vars(|| {
        env::set_var("NO_PROXY", "*");

        let s = ProxySettings::from_env();

        assert!(s.disable_proxies);
    });
}

#[test]
fn test_proxy_from_env_no_proxy_root_domain() {
    with_reset_proxy_vars(|| {
        env::set_var("NO_PROXY", ".myroot.com");

        let s = ProxySettings::from_env();

        let url = Url::parse("https://mysub.myroot.com").unwrap();
        assert!(s.for_url(&url).is_none());
        assert_eq!(s.no_proxy_hosts[0], "myroot.com");
    });
}

#[test]
fn test_proxy_from_env_no_proxy() {
    with_reset_proxy_vars(|| {
        env::set_var("NO_PROXY", "example.com, www.reddit.com, google.ca ");

        let s = ProxySettings::from_env();

        assert_eq!(s.no_proxy_hosts, vec!["example.com", "www.reddit.com", "google.ca"]);
    });
}
