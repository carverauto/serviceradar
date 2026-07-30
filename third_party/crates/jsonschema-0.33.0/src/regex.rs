pub(crate) trait RegexEngine: Sized + Send + Sync {
    type Error: RegexError;
    fn is_match(&self, text: &str) -> Result<bool, Self::Error>;

    fn pattern(&self) -> &str;
}

impl RegexEngine for fancy_regex::Regex {
    type Error = fancy_regex::Error;

    fn is_match(&self, text: &str) -> Result<bool, Self::Error> {
        fancy_regex::Regex::is_match(self, text)
    }

    fn pattern(&self) -> &str {
        self.as_str()
    }
}

impl RegexEngine for regex::Regex {
    type Error = regex::Error;

    fn is_match(&self, text: &str) -> Result<bool, Self::Error> {
        Ok(regex::Regex::is_match(self, text))
    }

    fn pattern(&self) -> &str {
        self.as_str()
    }
}

pub(crate) trait RegexError {
    fn into_backtrack_error(self) -> Option<fancy_regex::Error>;
}

impl RegexError for fancy_regex::Error {
    fn into_backtrack_error(self) -> Option<fancy_regex::Error> {
        Some(self)
    }
}

impl RegexError for regex::Error {
    fn into_backtrack_error(self) -> Option<fancy_regex::Error> {
        None
    }
}

#[allow(clippy::result_large_err)]
pub(crate) fn build_fancy_regex(
    pattern: &str,
    backtrack_limit: Option<usize>,
    size_limit: Option<usize>,
    dfa_size_limit: Option<usize>,
) -> Result<fancy_regex::Regex, fancy_regex::Error> {
    let mut builder = fancy_regex::RegexBuilder::new(pattern);
    if let Some(limit) = backtrack_limit {
        builder.backtrack_limit(limit);
    }
    if let Some(limit) = size_limit {
        builder.delegate_size_limit(limit);
    }
    if let Some(limit) = dfa_size_limit {
        builder.delegate_dfa_size_limit(limit);
    }
    builder.build()
}

pub(crate) fn build_regex(
    pattern: &str,
    size_limit: Option<usize>,
    dfa_size_limit: Option<usize>,
) -> Result<regex::Regex, regex::Error> {
    let mut builder = regex::RegexBuilder::new(pattern);
    if let Some(limit) = size_limit {
        builder.size_limit(limit);
    }
    if let Some(limit) = dfa_size_limit {
        builder.dfa_size_limit(limit);
    }
    builder.build()
}
