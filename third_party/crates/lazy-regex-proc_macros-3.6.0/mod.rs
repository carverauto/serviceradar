mod args;
mod regex_code;

use {
    crate::{args::*, regex_code::*},
    proc_macro::TokenStream,
    quote::quote,
    syn::{parse_macro_input, Expr},
};

//  The following `process*` functions are convenience funcs
//  to reduce boilerplate in macro implementations below.
fn process<T, F>(input: TokenStream, as_bytes: bool, f: F) -> TokenStream
where
    T: Into<TokenStream>,
    F: Fn(RegexCode) -> T,
{
    match RegexCode::from_token_stream(input, as_bytes) {
        Ok(r) => f(r).into(),
        Err(e) => e.to_compile_error().into(),
    }
}

fn process_with_value<T, F>(input: TokenStream, as_bytes: bool, f: F) -> TokenStream
where
    T: Into<TokenStream>,
    F: Fn(RegexCode, Expr) -> T,
{
    let parsed = parse_macro_input!(input as RexValArgs);
    match RegexCode::from_lit_str(parsed.regex_str, as_bytes) {
        Ok(r) => f(r, parsed.value).into(),
        Err(e) => e.to_compile_error().into(),
    }
}

/// Return a lazy static Regex checked at compilation time and
/// built at first use.
///
/// Flags can be specified as suffix:
/// ```
/// let case_insensitive_regex = regex!("^ab+$"i);
/// ```
///
/// The macro returns a reference to a `regex::Regex`
/// or a `regex::bytes::Regex` instance,
/// differentiated by the `B` flag:
/// ```
/// let verbose = regex!(r#"_([\d\.]+)"#)
///     .replace("This is lazy-regex_2.2", " (version $1)");
/// assert_eq!(verbose, "This is lazy-regex (version 2.2)");
/// ```
#[proc_macro]
pub fn regex(input: TokenStream) -> TokenStream {
    process(input, false, |regex_code| regex_code.lazy_static())
}

/// Return a lazy static `regex::bytes::Regex` checked at compilation time and
/// built at first use.
///
/// Flags can be specified as suffix:
/// ```
/// let case_insensitive_regex = bytes_regex!("^ab+$"i);
/// assert!(case_insensitive_regex.is_match(b"abB"));
/// ```
#[proc_macro]
pub fn bytes_regex(input: TokenStream) -> TokenStream {
    process(input, true, |regex_code| regex_code.lazy_static())
}

/// Return an instance of `once_cell::sync::Lazy<regex::Regex>` or
/// `once_cell::sync::Lazy<regex::bytes::Regex>` that
/// you can use in a public static declaration.
///
/// Example:
///
/// ```
/// pub static GLOBAL_REX: Lazy<Regex> = lazy_regex!("^ab+$"i);
/// ```
///
/// As for other macros, the regex is checked at compilation time.
#[proc_macro]
pub fn lazy_regex(input: TokenStream) -> TokenStream {
    process(input, false, |regex_code| regex_code.build)
}

/// Return an instance of `once_cell::sync::Lazy<bytes::Regex>` that
/// you can use in a public static declaration.
///
/// Example:
///
/// ```
/// pub static GLOBAL_REX: Lazy<bytes::Regex> = bytes_lazy_regex!("^ab+$"i);
/// ```
///
/// As for other macros, the regex is checked at compilation time.
#[proc_macro]
pub fn bytes_lazy_regex(input: TokenStream) -> TokenStream {
    process(input, true, |regex_code| regex_code.build)
}

/// Test whether an expression matches a lazy static
/// regular expression (the regex is checked at compile
/// time)
///
/// Example:
/// ```
/// let b = regex_is_match!("[ab]+", "car");
/// assert_eq!(b, true);
/// ```
#[proc_macro]
pub fn regex_is_match(input: TokenStream) -> TokenStream {
    process_with_value(input, false, |regex_code, value| {
        let statick = regex_code.statick();
        quote! {{
            #statick;
            RE.is_match(#value)
        }}
    })
}

/// Test whether an expression matches a lazy static
/// `bytes::Regex` regular expression (the regex is checked
/// at compile time)
///
/// Example:
/// ```
/// let b = bytes_regex_is_match!("[ab]+", b"car");
/// assert_eq!(b, true);
/// ```
#[proc_macro]
pub fn bytes_regex_is_match(input: TokenStream) -> TokenStream {
    process_with_value(input, true, |regex_code, value| {
        let statick = regex_code.statick();
        quote! {{
            #statick;
            RE.is_match(#value)
        }}
    })
}

/// Extract the leftmost match of the regex in the
/// second argument, as a `&str`, or a `&[u8]` if the `B` flag is set.
///
/// Example:
/// ```
/// let f_word = regex_find!(r#"\bf\w+\b"#, "The fox jumps.");
/// assert_eq!(f_word, Some("fox"));
/// let f_word = regex_find!(r#"\bf\w+\b"#B, "The forest is silent.");
/// assert_eq!(f_word, Some(b"forest" as &[u8]));
/// ```
#[proc_macro]
pub fn regex_find(input: TokenStream) -> TokenStream {
    process_with_value(input, false, |regex_code, value| {
        let statick = regex_code.statick();
        let as_method = match regex_code.regex {
            RegexInstance::Regex(..) => quote!(as_str),
            RegexInstance::Bytes(..) => quote!(as_bytes),
        };
        quote! {{
            #statick;
            RE.find(#value).map(|mat| mat. #as_method ())
        }}
    })
}

/// Extract the leftmost match of the regex in the
/// second argument as a `&[u8]`
///
/// Example:
/// ```
/// let f_word = bytes_regex_find!(r#"\bf\w+\b"#, b"The fox jumps.");
/// assert_eq!(f_word, Some("fox".as_bytes()));
/// ```
#[proc_macro]
pub fn bytes_regex_find(input: TokenStream) -> TokenStream {
    process_with_value(input, true, |regex_code, value| {
        let statick = regex_code.statick();
        let as_method = match regex_code.regex {
            RegexInstance::Regex(..) => quote!(as_str),
            RegexInstance::Bytes(..) => quote!(as_bytes),
        };
        quote! {{
            #statick;
            RE.find(#value).map(|mat| mat. #as_method ())
        }}
    })
}

/// Extract captured groups as a tuple of &str.
///
/// If there's no match, the macro returns `None`.
///
/// If an optional group has no value, the tuple
/// will contain `""` instead.
///
/// Example:
/// ```
/// let (whole, name, version) = regex_captures!(
///     r#"(\w+)-([0-9.]+)"#, // a literal regex
///     "This is lazy_regex-2.0!", // any expression
/// ).unwrap();
/// assert_eq!(whole, "lazy_regex-2.0");
/// assert_eq!(name, "lazy_regex");
/// assert_eq!(version, "2.0");
/// ```
#[proc_macro]
pub fn regex_captures(input: TokenStream) -> TokenStream {
    process_with_value(input, false, |regex_code, value| {
        let statick = regex_code.statick();
        let n = regex_code.captures_len();
        let groups = (0..n).map(|i| {
            quote! {
                caps.get(#i).map_or("", |c| c.as_str())
            }
        });
        quote! {{
            #statick;
            RE.captures(#value)
                .map(|caps| (
                    #(#groups),*
                ))
        }}
    })
}

/// Extract captured groups as a tuple of &[u8]
///
/// If there's no match, the macro returns `None`.
///
/// If an optional group has no value, the tuple
/// will contain `b""` instead.
///
/// Example:
/// ```
/// let (whole, name, version) = bytes_regex_captures!(
///     r#"(\w+)-([0-9.]+)"#, // a literal regex
///     b"This is lazy_regex-2.0!", // any expression
/// ).unwrap();
/// assert_eq!(whole, b"lazy_regex-2.0");
/// assert_eq!(name, b"lazy_regex");
/// assert_eq!(version, "2.0".as_bytes());
/// ```
#[proc_macro]
pub fn bytes_regex_captures(input: TokenStream) -> TokenStream {
    process_with_value(input, true, |regex_code, value| {
        let statick = regex_code.statick();
        let n = regex_code.captures_len();
        let groups = (0..n).map(|i| {
            quote! {
                caps.get(#i).map_or(&b""[..], |c| c.as_bytes())
            }
        });
        quote! {{
            #statick;
            RE.captures(#value)
                .map(|caps| (
                    #(#groups),*
                ))
        }}
    })
}

/// Returns an iterator that yields successive non-overlapping matches in the given haystack.
/// The iterator yields values of type `regex::Captures`.
///
/// Example (adapted from the regex crate):
/// ```
/// let hay = "'Citizen Kane' (1941), 'The Wizard of Oz' (1939), 'M' (1931).";
/// let mut movies = vec![];
/// let iter = regex_captures_iter!(r"'([^']+)'\s+\(([0-9]{4})\)", hay);
/// for (_, [title, year]) in iter.map(|c| c.extract()) {
///     movies.push((title, year.parse::<i64>().unwrap()));
/// }
/// assert_eq!(movies, vec![
///     ("Citizen Kane", 1941),
///     ("The Wizard of Oz", 1939),
///     ("M", 1931),
/// ]);
/// ```
#[proc_macro]
pub fn regex_captures_iter(input: TokenStream) -> TokenStream {
    process_with_value(input, false, |regex_code, value| {
        let statick = regex_code.statick();
        quote! {{
            #statick;
            RE.captures_iter(#value)
        }}
    })
}

/// Returns an iterator that yields successive non-overlapping matches in the given haystack.
#[proc_macro]
pub fn bytes_regex_captures_iter(input: TokenStream) -> TokenStream {
    process_with_value(input, true, |regex_code, value| {
        let statick = regex_code.statick();
        quote! {{
            #statick;
            RE.captures_iter(#value)
        }}
    })
}

/// common implementation of `regex_replace` and `regex_replace_all`
fn replacen(input: TokenStream, limit: usize) -> TokenStream {
    let parsed = parse_macro_input!(input as ReplaceArgs);
    let ReplaceArgs { regex_str, value, replacer } = parsed;
    let regex_code = match RegexCode::from_lit_str(regex_str, false) {
        Ok(r) => r,
        Err(e) => {
            return e.to_compile_error().into();
        }
    };
    let statick = regex_code.statick();
    let stream = match replacer {
        MaybeFun::Fun(fun) => {
            let n = regex_code.captures_len();
            let groups = (0..n).map(|i| {
                quote! {
                    caps.get(#i).map_or("", |c| c.as_str())
                }
            });
            quote! {{
                #statick;
                RE.replacen(
                    #value,
                    #limit,
                    |caps: &lazy_regex::Captures<'_>| {
                        let mut fun = #fun;
                        fun(
                            #(#groups),*
                        )
                    })
            }}
        }
        MaybeFun::Expr(expr) => {
            quote! {{
                #statick;
                RE.replacen(#value, #limit, #expr)
            }}
        }
    };
    stream.into()
}

/// common implementation of `bytes_regex_replace` and `bytes_regex_replace_all`
fn bytes_replacen(input: TokenStream, limit: usize) -> TokenStream {
    let parsed = parse_macro_input!(input as ReplaceArgs);
    let ReplaceArgs { regex_str, value, replacer } = parsed;
    let regex_code = match RegexCode::from_lit_str(regex_str, true) {
        Ok(r) => r,
        Err(e) => {
            return e.to_compile_error().into();
        }
    };
    let statick = regex_code.statick();
    let stream = match replacer {
        MaybeFun::Fun(fun) => {
            let n = regex_code.captures_len();
            let groups = (0..n).map(|i| {
                quote! {
                    caps.get(#i).map_or(&b""[..], |c| c.as_bytes())
                }
            });
            quote! {{
                #statick;
                RE.replacen(
                    #value,
                    #limit,
                    |caps: &lazy_regex::regex::bytes::Captures<'_>| {
                        let mut fun = #fun;
                        fun(
                            #(#groups),*
                        )
                    })
            }}
        }
        MaybeFun::Expr(expr) => {
            quote! {{
                #statick;
                RE.replacen(#value, #limit, #expr)
            }}
        }
    };
    stream.into()
}

/// Replaces the leftmost match in the second argument
/// using the replacer given as third argument.
///
/// When the replacer is a closure, it is given one or more `&str`,
/// the first one for the whole match and the following ones for
/// the groups.
/// Any optional group with no value is replaced with `""`.
///
/// Example:
/// ```
/// let text = "Fuu fuuu";
/// let text = regex_replace!(
///     "f(u*)"i,
///     text,
///     |_, suffix: &str| format!("F{}", suffix.len()),
/// );
/// assert_eq!(text, "F2 fuuu");
/// ```
#[proc_macro]
pub fn regex_replace(input: TokenStream) -> TokenStream {
    replacen(input, 1)
}

/// Replaces the leftmost match in the second argument
/// using the replacer given as third argument.
///
/// When the replacer is a closure, it is given one or more `&str`,
/// the first one for the whole match and the following ones for
/// the groups.
/// Any optional group with no value is replaced with `b""`.
///
/// Example:
/// ```
/// println!("{:?}", "ck ck".as_bytes());
/// let text = b"Fuu fuuu";
/// let text = bytes_regex_replace!(
///     "f(u*)"i,
///     text,
///     b"ck",
/// );
/// assert_eq!(text, "ck fuuu".as_bytes());
/// ```
#[proc_macro]
pub fn bytes_regex_replace(input: TokenStream) -> TokenStream {
    bytes_replacen(input, 1)
}

/// Replaces all non-overlapping matches in the second argument
/// using the replacer given as third argument.
///
/// When the replacer is a closure, it is given one or more `&str`,
/// the first one for the whole match and the following ones for
/// the groups.
/// Any optional group with no value is replaced with `""`.
///
/// Example:
/// ```
/// let text = "Foo fuu";
/// let text = regex_replace_all!(
///     r#"\bf(?P<suffix>\w+)"#i,
///     text,
///     |_, suffix| format!("F<{}>", suffix),
/// );
/// assert_eq!(text, "F<oo> F<uu>");
/// ```
#[proc_macro]
pub fn regex_replace_all(input: TokenStream) -> TokenStream {
    replacen(input, 0)
}

/// Replaces all non-overlapping matches in the second argument
/// using the replacer given as third argument.
///
/// When the replacer is a closure, it is given one or more `&str`,
/// the first one for the whole match and the following ones for
/// the groups.
/// Any optional group with no value is replaced with `""`.
///
/// Example:
/// ```
/// let text = b"Foo fuu";
/// let text = bytes_regex_replace_all!(
///     r#"\bf(?P<suffix>\w+)"#i,
///     text,
///     b"H",
/// );
/// assert_eq!(text, "H H".as_bytes());
/// ```
#[proc_macro]
pub fn bytes_regex_replace_all(input: TokenStream) -> TokenStream {
    bytes_replacen(input, 0)
}

/// Return an `Option<T>`, with T being the type returned by the block or expression
/// given as third argument.
///
/// If the regex matches, executes the expression and return it as Some.
/// Return None if the regex doesn't match.
///
/// ```
///  let grey = regex_if!(r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#, "grey(22)", {
///      level.parse().unwrap()
///  });
///  assert_eq!(grey, Some(22));
/// ```
#[proc_macro]
pub fn regex_if(input: TokenStream) -> TokenStream {
    let RexIfArgs {
        regex_str,
        value,
        then,
    } = parse_macro_input!(input as RexIfArgs);
    let regex_code = match RegexCode::from_lit_str(regex_str, false) {
        Ok(r) => r,
        Err(e) => {
            return e.to_compile_error().into();
        }
    };
    let statick = regex_code.statick();
    let assigns = regex_code.named_groups().into_iter().map(|(idx, name)| {
        let var_name = syn::Ident::new(name, proc_macro2::Span::call_site());
        quote! {
            let #var_name: &str = caps.get(#idx).map_or("", |c| c.as_str());
        }
    });
    quote! {{
        #statick;
        match RE.captures(#value) {
            Some(caps) => {
                #(#assigns);*
                Some(#then)
            }
            None => None,
        }
    }}.into()
}

#[proc_macro]
pub fn bytes_regex_if(input: TokenStream) -> TokenStream {
    let RexIfArgs {
        regex_str,
        value,
        then,
    } = parse_macro_input!(input as RexIfArgs);
    let regex_code = match RegexCode::from_lit_str(regex_str, true) {
        Ok(r) => r,
        Err(e) => {
            return e.to_compile_error().into();
        }
    };
    let statick = regex_code.statick();
    let assigns = regex_code.named_groups().into_iter().map(|(idx, name)| {
        let var_name = syn::Ident::new(name, proc_macro2::Span::call_site());
        quote! {
            let #var_name: &[u8] = caps.get(#idx).map_or(&b""[..], |c| c.as_bytes());
        }
    });
    quote! {{
        #statick;
        match RE.captures(#value) {
            Some(caps) => {
                #(#assigns);*
                Some(#then)
            }
            None => None,
        }
    }}.into()
}

/// Define a set of lazy static statically compiled regexes, with a block
/// or expression for each one. The first matching expression is computed
/// with the named capture groups declaring `&str` variables available for this
/// computation.
/// If no regex matches, return `None`.
///
/// Example:
/// ```
/// #[derive(Debug, PartialEq)]
/// enum Color {
///     Grey(u8),
///     Pink,
///     Rgb(u8, u8, u8),
/// }
///
/// let input = "rgb(1, 2, 3)";
/// let color = regex_switch!(input,
///     r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#i => {
///         Color::Grey(level.parse()?)
///     }
///     "^pink"i => Color::Pink,
///     r#"^rgb\((?<r>\d+),\s*(?<g>\d+),\s*(?<b>\d+),?\)$"#i => Color::Rgb (
///         r.parse()?,
///         g.parse()?,
///         b.parse()?,
///     ),
/// );
/// assert_eq!(color, Some(Color::Rgb(1, 2, 3)));
///
/// ```
#[proc_macro]
pub fn regex_switch(input: TokenStream) -> TokenStream {
    let RexSwitchArgs {
        value,
        arms,
    } = parse_macro_input!(input as RexSwitchArgs);
    let mut q_arms = Vec::new();
    for RexSwitchArmArgs { regex_str, then } in arms {
        let regex_code = match RegexCode::from_lit_str(regex_str, false) {
            Ok(r) => r,
            Err(e) => {
                return e.to_compile_error().into();
            }
        };
        let statick = regex_code.statick();
        let assigns = regex_code.named_groups().into_iter().map(|(idx, name)| {
            let var_name = syn::Ident::new(name, proc_macro2::Span::call_site());
            quote! {
                let #var_name: &str = caps.get(#idx).map_or("", |c| c.as_str());
            }
        });
        q_arms.push(
            quote! {{
                #statick;
                if let Some(caps) = RE.captures(#value) {
                    #(#assigns);*
                    let output = Some(#then);
                    break 'switch output;
                }
            }}
        );
    }
    quote! {{
        'switch: {
            #(#q_arms)*
            None
        }
    }}.into()
}

/// Define a set of lazy static statically compiled regexes, with a block
/// or expression for each one. The first matching expression is computed
/// with the named capture groups declaring `&str` variables available for this
/// computation.
/// If no regex matches, return `None`.
///
/// Example:
/// ```
/// #[derive(Debug, PartialEq)]
/// enum Color {
///     Grey(u8),
///     Pink,
///     Rgb(u8, u8, u8),
/// }
///
/// let input = "rgb(1, 2, 3)";
/// let color = regex_switch!(input,
///     r#"^gr(a|e)y\((?<level>\d{1,2})\)$"#i => {
///         Color::Grey(level.parse()?)
///     }
///     "^pink"i => Color::Pink,
///     r#"^rgb\((?<r>\d+),\s*(?<g>\d+),\s*(?<b>\d+),?\)$"#i => Color::Rgb (
///         r.parse()?,
///         g.parse()?,
///         b.parse()?,
///     ),
/// );
/// assert_eq!(color, Some(Color::Rgb(1, 2, 3)));
///
/// ```
#[proc_macro]
pub fn bytes_regex_switch(input: TokenStream) -> TokenStream {
    let RexSwitchArgs {
        value,
        arms,
    } = parse_macro_input!(input as RexSwitchArgs);
    let mut q_arms = Vec::new();
    for RexSwitchArmArgs { regex_str, then } in arms {
        let regex_code = match RegexCode::from_lit_str(regex_str, true) {
            Ok(r) => r,
            Err(e) => {
                return e.to_compile_error().into();
            }
        };
        let statick = regex_code.statick();
        let assigns = regex_code.named_groups().into_iter().map(|(idx, name)| {
            let var_name = syn::Ident::new(name, proc_macro2::Span::call_site());
            quote! {
                let #var_name: &[u8] = caps.get(#idx).map_or(&b""[..], |c| c.as_bytes());
            }
        });
        q_arms.push(
            quote! {{
                #statick;
                if let Some(caps) = RE.captures(#value) {
                    #(#assigns);*
                    let output = Some(#then);
                    break 'switch output;
                }
            }}
        );
    }
    quote! {{
        'switch: {
            #(#q_arms)*
            None
        }
    }}.into()
}
