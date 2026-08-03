#[cfg(feature = "net")]
use core::net::{Ipv4Addr, Ipv6Addr};

use fluent_uri::{component::Host, encoding::EStr, Uri, UriRef};

#[test]
fn parse_absolute() {
    let r = UriRef::parse("file:///etc/hosts").unwrap();
    assert_eq!(r.as_str(), "file:///etc/hosts");
    assert_eq!(r.scheme().unwrap().as_str(), "file");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "");
    assert!(matches!(a.host_parsed(), Host::RegName(n) if n == ""));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "/etc/hosts");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("ftp://ftp.is.co.za/rfc/rfc1808.txt").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "ftp");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "ftp.is.co.za");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "ftp.is.co.za");
    assert!(matches!(a.host_parsed(), Host::RegName(name) if name == "ftp.is.co.za"));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "/rfc/rfc1808.txt");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("http://www.ietf.org/rfc/rfc2396.txt").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "http");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "www.ietf.org");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "www.ietf.org");
    assert!(matches!(a.host_parsed(), Host::RegName(name) if name == "www.ietf.org"));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "/rfc/rfc2396.txt");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("ldap://[2001:db8::7]/c=GB?objectClass?one").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "ldap");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "[2001:db8::7]");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "[2001:db8::7]");
    #[cfg(feature = "net")]
    assert!(matches!(
        a.host_parsed(),
        Host::Ipv6(addr) if addr == Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x7)
    ));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "/c=GB");
    assert_eq!(r.query(), Some(EStr::new_or_panic("objectClass?one")));
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("mailto:John.Doe@example.com").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "mailto");
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "John.Doe@example.com");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("news:comp.infosystems.www.servers.unix").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "news");
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "comp.infosystems.www.servers.unix");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("tel:+1-816-555-1212").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "tel");
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "+1-816-555-1212");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("telnet://192.0.2.16:80/").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "telnet");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "192.0.2.16:80");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "192.0.2.16");
    #[cfg(feature = "net")]
    assert!(matches!(a.host_parsed(), Host::Ipv4(addr) if addr == Ipv4Addr::new(192, 0, 2, 16)));
    assert_eq!(a.port(), Some(EStr::new_or_panic("80")));
    assert_eq!(r.path(), "/");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("urn:oasis:names:specification:docbook:dtd:xml:4.1.2").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "urn");
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "oasis:names:specification:docbook:dtd:xml:4.1.2");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("foo://example.com:8042/over/there?name=ferret#nose").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "foo");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "example.com:8042");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "example.com");
    assert!(matches!(a.host_parsed(), Host::RegName(name) if name == "example.com"));
    assert_eq!(a.port(), Some(EStr::new_or_panic("8042")));
    assert_eq!(r.path(), "/over/there");
    assert_eq!(r.query(), Some(EStr::new_or_panic("name=ferret")));
    assert_eq!(r.fragment(), Some(EStr::new_or_panic("nose")));

    let r =
        UriRef::parse("ftp://cnn.example.com&story=breaking_news@10.0.0.1/top_story.htm").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "ftp");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "cnn.example.com&story=breaking_news@10.0.0.1");
    assert_eq!(
        a.userinfo(),
        Some(EStr::new_or_panic("cnn.example.com&story=breaking_news"))
    );
    assert_eq!(a.host(), "10.0.0.1");
    #[cfg(feature = "net")]
    assert!(matches!(a.host_parsed(), Host::Ipv4(addr) if addr == Ipv4Addr::new(10, 0, 0, 1)));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "/top_story.htm");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("http://[vFe.foo.bar]").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "http");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "[vFe.foo.bar]");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "[vFe.foo.bar]");
    assert!(matches!(a.host_parsed(), Host::IpvFuture { .. }));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("http://127.0.0.1:/").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "http");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "127.0.0.1:");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "127.0.0.1");
    #[cfg(feature = "net")]
    assert!(matches!(a.host_parsed(), Host::Ipv4(addr) if addr == Ipv4Addr::new(127, 0, 0, 1)));
    assert_eq!(a.port(), Some(EStr::EMPTY));
    assert_eq!(r.path(), "/");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("http://127.0.0.1:8080/").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "http");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "127.0.0.1:8080");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "127.0.0.1");
    #[cfg(feature = "net")]
    assert!(matches!(a.host_parsed(), Host::Ipv4(addr) if addr == Ipv4Addr::new(127, 0, 0, 1)));
    assert_eq!(a.port(), Some(EStr::new_or_panic("8080")));
    assert_eq!(r.path(), "/");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("http://127.0.0.1:80808/").unwrap();
    assert_eq!(r.scheme().unwrap().as_str(), "http");
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "127.0.0.1:80808");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "127.0.0.1");
    #[cfg(feature = "net")]
    assert!(matches!(a.host_parsed(), Host::Ipv4(addr) if addr == Ipv4Addr::new(127, 0, 0, 1)));
    assert_eq!(a.port(), Some(EStr::new_or_panic("80808")));
    assert_eq!(r.path(), "/");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);
}

#[test]
fn parse_relative() {
    let r = UriRef::parse("").unwrap();
    assert!(r.scheme().is_none());
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("foo.txt").unwrap();
    assert!(r.scheme().is_none());
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "foo.txt");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse(".").unwrap();
    assert!(r.scheme().is_none());
    assert!(r.authority().is_none());
    assert_eq!(r.path(), ".");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("./this:that").unwrap();
    assert!(r.scheme().is_none());
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "./this:that");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("//example.com").unwrap();
    assert!(r.scheme().is_none());
    let a = r.authority().unwrap();
    assert_eq!(a.as_str(), "example.com");
    assert_eq!(a.userinfo(), None);
    assert_eq!(a.host(), "example.com");
    assert!(matches!(a.host_parsed(), Host::RegName(name) if name == "example.com"));
    assert_eq!(a.port(), None);
    assert_eq!(r.path(), "");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("?query").unwrap();
    assert!(r.scheme().is_none());
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "");
    assert_eq!(r.query(), Some(EStr::new_or_panic("query")));
    assert_eq!(r.fragment(), None);

    let r = UriRef::parse("#fragment").unwrap();
    assert!(r.scheme().is_none());
    assert!(r.authority().is_none());
    assert_eq!(r.path(), "");
    assert_eq!(r.query(), None);
    assert_eq!(r.fragment(), Some(EStr::new_or_panic("fragment")));
}

#[test]
fn parse_error_uri() {
    // No scheme
    let e = Uri::parse("foo").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 3");

    // Empty scheme
    let e = Uri::parse(":hello").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 0");

    // Scheme starts with non-letter
    let e = Uri::parse("3ttp://a.com").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 0");

    // Unexpected char in scheme
    let e = Uri::parse("exam=ple:foo").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 4");

    let e = Uri::parse("(:").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 0");

    // Percent-encoded scheme
    let e = Uri::parse("a%20:foo").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 1");
}

#[test]
fn parse_error_uri_ref() {
    // Empty scheme
    let e = UriRef::parse(":hello").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 0");

    // Scheme starts with non-letter
    let e = UriRef::parse("3ttp://a.com").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 0");

    // After rewriting the parser, the following two cases are interpreted as
    // containing colon in the first path segment of a relative reference.

    // Unexpected char in scheme
    let e = UriRef::parse("exam=ple:foo").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 8");

    let e = UriRef::parse("(:").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 1");

    // Percent-encoded scheme
    let e = UriRef::parse("a%20:foo").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 4");

    // Unexpected char in path
    let e = UriRef::parse("foo\\bar").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 3");

    // Non-hexadecimal percent-encoded octet
    let e = UriRef::parse("foo%xxd").unwrap_err();
    assert_eq!(e.to_string(), "invalid percent-encoded octet at index 3");

    // Incomplete percent-encoded octet
    let e = UriRef::parse("text%a").unwrap_err();
    assert_eq!(e.to_string(), "invalid percent-encoded octet at index 4");

    // A single percent
    let e = UriRef::parse("%").unwrap_err();
    assert_eq!(e.to_string(), "invalid percent-encoded octet at index 0");

    // Non-decimal port
    let e = UriRef::parse("http://example.com:80ab").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 21");

    let e = UriRef::parse("http://user@example.com:80ab").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 26");

    // Multiple colons in authority
    let e = UriRef::parse("http://user:pass:example.com/").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 16");

    // Unclosed bracket
    let e = UriRef::parse("https://[::1/").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 12");

    // Not port after IP literal
    let e = UriRef::parse("https://[::1]wrong").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 13");

    // IP literal too short
    let e = UriRef::parse("http://[:]").unwrap_err();
    assert_eq!(e.to_string(), "invalid IPv6 address at index 8");
    let e = UriRef::parse("http://[]").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 8");

    // Non-hexadecimal version in IPvFuture
    let e = UriRef::parse("http://[vG.addr]").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 9");

    // Empty version in IPvFuture
    let e = UriRef::parse("http://[v.addr]").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 9");

    // Empty address in IPvFuture
    let e = UriRef::parse("ftp://[vF.]").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 10");

    // Percent-encoded address in IPvFuture
    let e = UriRef::parse("ftp://[vF.%20]").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 10");

    // With zone identifier
    let e = UriRef::parse("ftp://[fe80::abcd%eth0]").unwrap_err();
    assert_eq!(e.to_string(), "unexpected character at index 17");

    // Invalid IPv6 address
    let e = UriRef::parse("example://[44:55::66::77]").unwrap_err();
    assert_eq!(e.to_string(), "invalid IPv6 address at index 11");
}

#[test]
fn strict_ip_addr() {
    let r = UriRef::parse("//127.0.0.001").unwrap();
    let a = r.authority().unwrap();
    assert!(matches!(a.host_parsed(), Host::RegName(_)));

    let r = UriRef::parse("//127.1").unwrap();
    let a = r.authority().unwrap();
    assert!(matches!(a.host_parsed(), Host::RegName(_)));

    let r = UriRef::parse("//127.00.00.1").unwrap();
    let a = r.authority().unwrap();
    assert!(matches!(a.host_parsed(), Host::RegName(_)));

    assert!(UriRef::parse("//[::1.1.1.1]").is_ok());
    assert!(UriRef::parse("//[::ffff:1.1.1.1]").is_ok());
    assert!(UriRef::parse("//[0000:0000:0000:0000:0000:0000:255.255.255.255]").is_ok());

    assert_eq!(
        UriRef::parse("//[::01.1.1.1]").unwrap_err().to_string(),
        "invalid IPv6 address at index 3"
    );
    assert_eq!(
        UriRef::parse("//[::00.1.1.1]").unwrap_err().to_string(),
        "invalid IPv6 address at index 3"
    );
}
