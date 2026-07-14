use {
    proc_macro::TokenStream,
    proc_macro2::TokenStream as TokenStream2,
    quote::quote,
    syn::LitStr,
};

/// The lazy static regex building code, which is produced and
/// inserted by all lazy-regex macros
pub(crate) struct RegexCode {
    pub build: TokenStream2,
    pub regex: RegexInstance,
}

pub(crate) enum RegexInstance {
    Regex(regex::Regex),
    Bytes(regex::bytes::Regex),
}

impl RegexCode {
    pub fn from_token_stream(token_stream: TokenStream, is_bytes: bool) -> Result<Self, syn::Error> {
        Self::from_lit_str(syn::parse::<syn::LitStr>(token_stream)?, is_bytes)
    }
    pub fn from_lit_str(lit_str: LitStr, mut is_bytes: bool) -> Result<Self, syn::Error> {
        let pattern = lit_str.value();
        let mut case_insensitive = false;
        let mut multi_line = false;
        let mut dot_matches_new_line = false;
        let mut ignore_whitespace = false;
        let mut swap_greed = false;
        for (i, ch) in lit_str.suffix().chars().enumerate() {
            match ch {
                'i' => case_insensitive = true,
                'm' => multi_line = true,
                's' => dot_matches_new_line = true,
                'x' => ignore_whitespace = true,
                'U' => swap_greed = true,
                'B' => is_bytes = true, // non-standard!
                _ => {
                    let lit = lit_str.token();
                    let pos = lit.to_string().len() - i;
                    // subspan only works on nighlty
                    return Err(syn::Error::new(
                        lit.subspan(pos - 1..pos).unwrap_or_else(|| lit.span()),
                        format!("unrecognized regex flag {ch:?}"),
                    ));
                }
            }
        }

        let regex = if is_bytes {
            regex::bytes::Regex::new(&pattern).map(RegexInstance::Bytes)
        } else {
            regex::Regex::new(&pattern).map(RegexInstance::Regex)
        };
        let regex = regex.map_err(|e| syn::Error::new(lit_str.span(), e.to_string()))?;

        let builder_token = if is_bytes {
            quote!(BytesRegexBuilder)
        } else {
            quote!(RegexBuilder)
        };
        let build = quote! {
            lazy_regex::Lazy::new(|| {
                //println!("compiling regex {:?}", #pattern);
                lazy_regex:: #builder_token ::new(#pattern)
                    .case_insensitive(#case_insensitive)
                    .multi_line(#multi_line)
                    .dot_matches_new_line(#dot_matches_new_line)
                    .ignore_whitespace(#ignore_whitespace)
                    .swap_greed(#swap_greed)
                    .build()
                    .unwrap()
            })
        };
        Ok(Self { build, regex })
    }
}

impl RegexCode {
    pub fn statick(&self) -> TokenStream2 {
        let build = &self.build;
        let regex_token = match self.regex {
            RegexInstance::Regex(..) => quote!(Regex),
            RegexInstance::Bytes(..) => quote!(BytesRegex),
        };
        quote! {
            static RE: lazy_regex::Lazy<lazy_regex:: #regex_token > = #build;
        }
    }

    pub fn lazy_static(&self) -> TokenStream2 {
        let statick = self.statick();
        quote! {{
            #statick;
            &RE
        }}
    }

    pub fn captures_len(&self) -> usize {
        match &self.regex {
            RegexInstance::Regex(regex) => regex.captures_len(),
            RegexInstance::Bytes(regex) => regex.captures_len(),
        }
    }
    pub fn named_groups(&self) -> Vec<(usize, &str)> {
        match &self.regex {
            RegexInstance::Regex(regex) => regex
                .capture_names()
                .enumerate()
                .filter_map(|(i, n)| Some((i, n?)))
                .collect(),
            RegexInstance::Bytes(regex) => regex
                .capture_names()
                .enumerate()
                .filter_map(|(i, n)| Some((i, n?)))
                .collect(),
        }
    }
}
