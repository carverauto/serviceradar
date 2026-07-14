use der_parser::ber::*;

#[test]
fn issue76_example1() {
    // This is a 4 bytes (2 characters) UTF-16-BE string. The first two bytes are the tag and size.
    let bytes = [0x80, 0x04, 0x00, 0x4c, 0x00, 0x65];
    let (i, header) = ber_read_element_header(&bytes).expect("parsing failed");
    let (rem, _content) =
        parse_ber_content(Tag::BmpString)(i, &header, MAX_RECURSION).expect("parsing failed");
    assert!(rem.is_empty());
}

#[test]
fn issue76_example2() {
    // This is a 6 bytes (3 characters) UTF-16-BE string. The first two bytes are the tag and size.
    let bytes = [0x80, 0x06, 0x79, 0x3E, 0x30, 0xBA, 0x30, 0xFC];
    let (i, header) = ber_read_element_header(&bytes).expect("parsing failed");
    let (rem, _content) =
        parse_ber_content(Tag::BmpString)(i, &header, MAX_RECURSION).expect("parsing failed");
    assert!(rem.is_empty());
}
