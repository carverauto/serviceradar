use {
    lazy_regex::*,
};

#[test]
fn test_regex_remove() {
    let input = "154681string63731";

    // no match: borrowed and unchanged
    let output = regex_remove!("[A-Z]+", input);
    assert!(matches!(output, std::borrow::Cow::Borrowed("154681string63731")));

    // removing in the middle (a new string is created)
    let output = regex_remove!("[a-z]+", input);
    assert_eq!(output, "15468163731");

    // removing at ends, no new string is created
    let output = regex_remove!(r"^\d+", input);
    let output = regex_remove!(r"\d+$", &output);
    assert_eq!(output, "string");
    assert!(matches!(output, std::borrow::Cow::Borrowed("string")));
}

#[test]
#[cfg(not(feature = "lite"))]
fn test_bytes_regex_remove() {
    let input = b"154681string63731";

    // removing at ends, no new Vec is created
    let output = bytes_regex_remove!("^\\d+", input);
    let output = bytes_regex_remove!("\\d+$", &output);
    assert_eq!(&output[..], b"string");
    assert!(matches!(output, std::borrow::Cow::Borrowed(b"string")));
}

#[test]
fn test_regex_remove_all() {
    let input = "154681string63731";

    // no match: borrowed and unchanged
    let output = regex_remove_all!("[A-Z]+", input);
    assert!(matches!(output, std::borrow::Cow::Borrowed("154681string63731")));

    // removing in the middle (a new string is created)
    let output = regex_remove_all!("[a-z]+", input);
    assert_eq!(output, "15468163731");

    // removing one hole in the middle, in several matches (a new string is created)
    let output = regex_remove_all!("[a-z]{2}", input);
    assert_eq!(output, "15468163731");

    // removing on ends (one match each side), no new string is created
    let output = regex_remove_all!(r"\d+", input);
    assert_eq!(output, "string");
    assert!(matches!(output, std::borrow::Cow::Borrowed("string")));

    // removing on start, no new string is created
    let output = regex_remove_all!(r"^\d+", input);
    assert_eq!(output, "string63731");
    assert!(matches!(output, std::borrow::Cow::Borrowed("string63731")));

    // removing on end, no new string is created
    let output = regex_remove_all!(r"\d+$", input);
    assert_eq!(output, "154681string");
    assert!(matches!(output, std::borrow::Cow::Borrowed("154681string")));

    // removing on ends (several matches each side), no new string is created
    let output = regex_remove_all!(r"\d", input);
    assert_eq!(output, "string");
    assert!(matches!(output, std::borrow::Cow::Borrowed("string")));

    // a few hard cases with various holes
    assert_eq!(
        regex_remove_all!(r"\d", "a1b2c3d4e5"),
        "abcde"
    );
    assert_eq!(
        regex_remove_all!(r"[a-z]", "a1b2c3d4e5"),
        "12345"
    );
    assert_eq!(
        regex_remove_all!(r"\d", "a11b22c33333d44e55"),
        "abcde"
    );
    assert_eq!(
        regex_remove_all!(r"\s+", "    ab  c    d  e    "),
        "abcde"
    );
}

#[test]
#[cfg(not(feature = "lite"))]
fn test_bytes_regex_remove_all() {
    let input = b"154681string63731";

    // removing on ends (several matches each side), no new vec is created
    let output = bytes_regex_remove_all!(r"\d", input);
    assert_eq!(&output[..], b"string");
    assert!(matches!(output, std::borrow::Cow::Borrowed(b"string")));

    // removing several matches
    assert_eq!(
        *bytes_regex_remove_all!(r"\s+", b"    ab  c    d  e    "),
        *b"abcde"
    );
}
