use {
    lazy_regex::*,
    std::num::ParseIntError,
};

#[test]
fn test_regex_switch() {
    #[derive(Debug, PartialEq, Eq)]
    enum Color {
        Grey(u8),
        Pink,
        Rgb(u8, u8, u8),
    }
    fn read(s: &str) -> Option<Color> {
        regex_switch!(s,
            r"^gr(a|e)y\((?<level>\d{1,2})\)$"i => {
                Color::Grey(level.parse().unwrap())
            }
            "^pink"i => Color::Pink,
            r"^rgb\((?<r>\d+),\s*(?<g>\d+),\s*(?<b>\d+),?\)$"i => Color::Rgb (
                r.parse().unwrap(),
                g.parse().unwrap(),
                b.parse().unwrap(),
            ),
        )
    }
    assert_eq!(read("gray(15)"), Some(Color::Grey(15)));
    assert_eq!(read("pInk"), Some(Color::Pink));
    assert_eq!(read("pinkie"), Some(Color::Pink));
    assert_eq!(read("red"), None);
    assert_eq!(read("rgb(1,2,3)"), Some(Color::Rgb(1, 2, 3)));
}

#[test]
fn test_regex_switch_with_error_handling() -> Result<(), ParseIntError> {
    #[derive(Debug, PartialEq)]
    enum Color {
        Grey(u8),
        Pink,
        Rgb(u8, u8, u8),
    }
    let input = "RGB(1, 2, 3)";
    let color = regex_switch!(input,
        r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#i => {
            Color::Grey(level.parse()?)
        }
        "^pink"i => Color::Pink,
        r#"^rgb\((?<r>\d+),\s*(?<g>\d+),\s*(?<b>\d+),?\)$"#i => Color::Rgb (
            r.parse()?,
            g.parse()?,
            b.parse()?,
        ),
    );
    assert_eq!(color, Some(Color::Rgb(1, 2, 3)));
    Ok(())
}

#[test]
#[cfg(not(feature = "lite"))]
fn test_bytes_regex_switch() {
    #[derive(Debug, PartialEq, Eq)]
    enum Color {
        Grey(u8),
        Pink,
        Rgb(u8, u8, u8),
    }
    fn read(s: &[u8]) -> Option<Color> {
        lazy_regex::bytes_regex_switch!(s,
            r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#i => {
                Color::Grey(std::str::from_utf8(level).unwrap().parse().unwrap())
            }
            "^pink"i => Color::Pink,
            r#"^rgb\((?<r>\d+),\s*(?<g>\d+),\s*(?<b>\d+),?\)$"#i => Color::Rgb (
                std::str::from_utf8(r).unwrap().parse().unwrap(),
                std::str::from_utf8(g).unwrap().parse().unwrap(),
                std::str::from_utf8(b).unwrap().parse().unwrap(),
            ),
        )
    }
    assert_eq!(read(b"gray(15)"), Some(Color::Grey(15)));
    assert_eq!(read(b"pInk"), Some(Color::Pink));
    assert_eq!(read(b"pinkie"), Some(Color::Pink));
    assert_eq!(read(b"red"), None);
    assert_eq!(read(b"rgb(1,2,3)"), Some(Color::Rgb(1, 2, 3)));
}
