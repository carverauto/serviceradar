
/// check replacement with a mut closure
/// See https://github.com/Canop/lazy-regex/issues/27
#[test]
fn replace_with_mut_closure() {
    let input = "5+183/32";
    let mut last_digits: Vec<u8> = Vec::new();
    let output = lazy_regex::regex_replace_all!(
        r"\d*(\d)",
        input,
        |number, last_digit: &str| {
            last_digits.push(last_digit.parse().unwrap());
            format!("[{number}]")
        }
    );
    assert_eq!(output, "[5]+[183]/[32]");
    assert_eq!(last_digits, [5, 3, 2]);
}
