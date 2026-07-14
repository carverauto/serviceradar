use {
    lazy_regex::{
        regex_if,
    },
    std::num::ParseIntError,
};

#[test]
fn test_regex_if() {
    fn extract_grey_level(s: &str) -> Option<u16> {
        regex_if!(
            r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#,
            s,
            level.parse().unwrap(),
        )
    }
    assert_eq!(extract_grey_level("gray(15)"), Some(15));
    assert_eq!(extract_grey_level("grey(22)"), Some(22));
    assert_eq!(extract_grey_level("grey(268)"), None);
    assert_eq!(extract_grey_level("red"), None);
}

#[test]
fn test_regex_if_with_error_handling() {
    fn extract_grey_level(s: &str) -> Result<Option<u8>, ParseIntError> {
        let v = regex_if!(r#"^gr(a|e)y\((?<level>\d{1,3})\)$"#, s, level.parse()?);
        Ok(v)
    }
    assert_eq!(extract_grey_level("gray(15)"), Ok(Some(15)));
    assert!(extract_grey_level("grey(268)").is_err());
    assert_eq!(extract_grey_level("red"), Ok(None));
}

#[test]
#[cfg(not(feature = "lite"))]
fn test_bytes_regex_if() {
    fn extract_grey_level(s: &[u8]) -> Option<u16> {
        lazy_regex::bytes_regex_if!(
            r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#,
            s,
            std::str::from_utf8(level).unwrap().parse().unwrap()
        )
    }
    assert_eq!(extract_grey_level(b"gray(15)"), Some(15));
    assert_eq!(extract_grey_level(b"grey(22)"), Some(22));
    assert_eq!(extract_grey_level(b"grey(268)"), None);
    assert_eq!(extract_grey_level(b"red"), None);
}

