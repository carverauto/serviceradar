use fluent_uri::{Uri, UriRef};

trait Test {
    fn pass(&self, r: &str, res: &str);
    fn fail(&self, r: &str, msg: &str);
}

impl Test for Uri<&str> {
    fn pass(&self, r: &str, res: &str) {
        assert_eq!(
            UriRef::parse(r).unwrap().resolve_against(self).unwrap(),
            res
        )
    }

    fn fail(&self, r: &str, msg: &str) {
        let e = UriRef::parse(r).unwrap().resolve_against(self).unwrap_err();
        assert_eq!(e.to_string(), msg);
    }
}

#[test]
fn resolve() {
    // Examples from Section 5.4 of RFC 3986.
    let base = Uri::parse("http://a/b/c/d;p?q").unwrap();

    base.pass("g:h", "g:h");
    base.pass("g", "http://a/b/c/g");
    base.pass("./g", "http://a/b/c/g");
    base.pass("g/", "http://a/b/c/g/");
    base.pass("/g", "http://a/g");
    base.pass("//g", "http://g");
    base.pass("?y", "http://a/b/c/d;p?y");
    base.pass("g?y", "http://a/b/c/g?y");
    base.pass("#s", "http://a/b/c/d;p?q#s");
    base.pass("g#s", "http://a/b/c/g#s");
    base.pass("g?y#s", "http://a/b/c/g?y#s");
    base.pass(";x", "http://a/b/c/;x");
    base.pass("g;x", "http://a/b/c/g;x");
    base.pass("g;x?y#s", "http://a/b/c/g;x?y#s");
    base.pass("", "http://a/b/c/d;p?q");
    base.pass(".", "http://a/b/c/");
    base.pass("./", "http://a/b/c/");
    base.pass("..", "http://a/b/");
    base.pass("../", "http://a/b/");
    base.pass("../g", "http://a/b/g");
    base.pass("../..", "http://a/");
    base.pass("../../", "http://a/");
    base.pass("../../g", "http://a/g");

    base.pass("../../../g", "http://a/g");
    base.pass("../../../../g", "http://a/g");

    base.pass("/./g", "http://a/g");
    base.pass("/../g", "http://a/g");
    base.pass("g.", "http://a/b/c/g.");
    base.pass(".g", "http://a/b/c/.g");
    base.pass("g..", "http://a/b/c/g..");
    base.pass("..g", "http://a/b/c/..g");

    base.pass("./../g", "http://a/b/g");
    base.pass("./g/.", "http://a/b/c/g/");
    base.pass("g/./h", "http://a/b/c/g/h");
    base.pass("g/../h", "http://a/b/c/h");
    base.pass("g;x=1/./y", "http://a/b/c/g;x=1/y");
    base.pass("g;x=1/../y", "http://a/b/c/y");

    base.pass("g?y/./x", "http://a/b/c/g?y/./x");
    base.pass("g?y/../x", "http://a/b/c/g?y/../x");
    base.pass("g#s/./x", "http://a/b/c/g#s/./x");
    base.pass("g#s/../x", "http://a/b/c/g#s/../x");

    base.pass("http:g", "http:g");

    // Non-hierarchical base URI.
    let base = Uri::parse("foo:bar").unwrap();

    base.pass("", "foo:bar");
    base.pass("#baz", "foo:bar#baz");
    base.pass("http://example.com/", "http://example.com/");
    base.pass("foo:baz", "foo:baz");
    base.pass("bar:baz", "bar:baz");

    let base = Uri::parse("foo:/").unwrap();
    // The result would be "foo://@@" using the original algorithm.
    base.pass(".//@@", "foo:/.//@@");

    let base = Uri::parse("foo:/bar/.%2E/").unwrap();
    // The result would be "foo:/bar/" using the original algorithm.
    base.pass("..", "foo:/");

    let base = Uri::parse("foo:/bar/..").unwrap();
    // The result would be "foo:/bar/" using the original algorithm.
    base.pass(".", "foo:/");

    let base = base.normalize();
    base.borrow().pass(".", "foo:/");
}

#[test]
fn resolve_error() {
    let base = Uri::parse("http://example.com/#title1").unwrap();
    base.fail("foo", "base URI/IRI with fragment");

    let base = Uri::parse("foo:bar").unwrap();
    base.fail(
        "baz",
        "relative reference must be empty or start with '#' when resolved against authority-less base URI/IRI with rootless path",
    );
    base.fail(
        "?baz",
        "relative reference must be empty or start with '#' when resolved against authority-less base URI/IRI with rootless path",
    );
}
