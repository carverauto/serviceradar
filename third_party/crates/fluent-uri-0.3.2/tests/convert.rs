use fluent_uri::{Iri, IriRef, Uri, UriRef};

#[test]
fn iri_to_uri() {
    let iri = Iri::parse("http://résumé.example.org").unwrap();
    assert_eq!(iri.to_uri(), "http://r%C3%A9sum%C3%A9.example.org");

    let iri = Iri::parse("http://www.example.org/red%09rosé#red").unwrap();
    assert_eq!(iri.to_uri(), "http://www.example.org/red%09ros%C3%A9#red");

    let iri = Iri::parse("foo://user@example.com:8042/over/there?name=ferret#nose").unwrap();
    assert_eq!(iri.to_uri(), iri.as_str());

    let iri = Iri::parse("http://example.com/\u{10300}\u{10301}\u{10302}").unwrap();
    assert_eq!(
        iri.to_uri(),
        "http://example.com/%F0%90%8C%80%F0%90%8C%81%F0%90%8C%82"
    );
}

#[test]
fn uri_to_iri() {
    let uri = Uri::parse("http://www.example.org/r%E9sum%E9.html").unwrap();
    assert_eq!(
        Iri::from(uri).normalize(),
        "http://www.example.org/r%E9sum%E9.html"
    );

    let uri = Uri::parse("http://www.example.org/D%C3%BCrst").unwrap();
    assert_eq!(Iri::from(uri).normalize(), "http://www.example.org/Dürst");

    let uri = Uri::parse("http://www.example.org/D%FCrst").unwrap();
    assert_eq!(Iri::from(uri).normalize(), "http://www.example.org/D%FCrst");

    let uri = Uri::parse("http://xn--99zt52a.example.org/%e2%80%ae").unwrap();
    // TODO: Determine if we should implement the MUST in Section 4.1 of RFC 3987.
    // assert_eq!(
    //     uri.as_iri().normalize(),
    //     "http://xn--99zt52a.example.org/%E2%80%AE"
    // );
    assert_eq!(
        Iri::from(uri).normalize(),
        "http://xn--99zt52a.example.org/\u{202e}"
    );
}

#[test]
fn convert_error() {
    let uri_ref = UriRef::parse("rel/ref").unwrap();
    assert_eq!(
        Uri::try_from(uri_ref).unwrap_err().to_string(),
        "scheme not present"
    );

    let uri_ref = UriRef::parse("").unwrap();
    assert_eq!(
        Uri::try_from(uri_ref).unwrap_err().to_string(),
        "scheme not present"
    );

    let iri = Iri::parse("http://你好.example.com/").unwrap();
    assert_eq!(
        Uri::try_from(iri).unwrap_err().to_string(),
        "unexpected character at index 7"
    );

    let iri_ref = IriRef::parse("réf/rel").unwrap();
    assert_eq!(
        Uri::try_from(iri_ref).unwrap_err().to_string(),
        "scheme not present"
    );
    assert_eq!(
        UriRef::try_from(iri_ref).unwrap_err().to_string(),
        "unexpected character at index 1"
    );
    assert_eq!(
        Iri::try_from(iri_ref).unwrap_err().to_string(),
        "scheme not present"
    );
}
