use alloc::{string::String, vec::Vec};
use core::{
    fmt::{self, Display, Formatter},
    num::NonZeroU8,
    str::FromStr,
};

use crate::{Error, Result};

/// A spoken language identifier
///
/// Returned from various methods on [`LanguagePreferences`]
///
/// Use [`ToString::to_string()`] to convert to string of two letter lowercase
/// language code followed an forward slash and uppercase country code (example:
/// `en/US`).
///
/// The [`Default`] implementation can be used for fallbacks, and is set to
/// `en/US` since it's a common choice for lingua franca.  It is not guaranteed
/// to stay the same across whoami versions.
///
/// Language codes are defined in an unspecified superset of
/// [ISO 639](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes),
/// Country codes are defined in an unspecified superset of
/// [ISO 3166](https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2).
///
/// You can compare languages with strings (where the separator can be any of
/// `-`, `_`, or `/`).
///
/// [`ToString::to_string()`]: std::string::ToString::to_string
#[derive(Copy, Clone, Eq, PartialEq, Debug)]
pub struct Language {
    /// The language code for this language
    ///
    /// Uses <https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes>
    lang: [NonZeroU8; 2],
    /// The optional country code for this language dialect
    ///
    /// Uses <https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2>
    country: Option<[NonZeroU8; 2]>,
}

impl Default for Language {
    fn default() -> Self {
        Self::from_str("en/US")
            .expect("this is an internal bug (failed to parse en/US)")
    }
}

impl FromStr for Language {
    type Err = Error;

    /// Reads an `language{/_-}COUNTRY.Encoding` formatted string into a
    /// `Language` where language is a two letter language code and country is a
    /// two letter country code.  The encoding is ignored.
    fn from_str(s: &str) -> Result<Self> {
        // Strip the encoding off the end if it exists
        let lang = s.split_terminator('.').next().unwrap_or_default();

        if lang.is_empty() {
            return Err(Error::empty_record());
        }

        // Split apart lang and country
        let mut parts = lang.split(SEPARATORS);
        let lang = parts
            .next()
            .ok_or_else(|| Error::with_invalid_data("No lang"))?
            .as_bytes();
        let country = parts.next().unwrap_or("\0\0").as_bytes();

        // Verify that the lengths are valid
        if parts.next().is_some() {
            return Err(Error::with_invalid_data("Invalid locale"));
        } else if lang.len() != 2 {
            return Err(Error::with_invalid_data("Invalid length lang code"));
        } else if country.len() != 2 {
            return Err(Error::with_invalid_data(
                "Invalid length country code",
            ));
        }

        // Verify the contents are valid
        let Some(lang) = NonZeroU8::new(lang[0]).zip(NonZeroU8::new(lang[1]))
        else {
            return Err(Error::with_invalid_data("Lang code contains NUL"));
        };
        let lang = [lang.0, lang.1];

        if (country[0] == 0 || country[1] == 0)
            && (country[0] != 0 || country[1] != 0)
        {
            return Err(Error::with_invalid_data("Country code contains NUL"));
        }

        let country = NonZeroU8::new(country[0])
            .zip(NonZeroU8::new(country[1]))
            .map(|country| [country.0, country.1]);

        if !(lang[0].get().is_ascii_lowercase()
            && lang[1].get().is_ascii_lowercase())
        {
            return Err(Error::with_invalid_data(
                "Lang code not ascii lowercase",
            ));
        }

        if let Some(ref country) = country {
            if !(country[0].get().is_ascii_uppercase()
                && country[1].get().is_ascii_uppercase())
            {
                return Err(Error::with_invalid_data(
                    "Country code not ascii uppercase",
                ));
            }
        }

        Ok(Self { lang, country })
    }
}

impl Display for Language {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(&String::from_utf8_lossy(&[
            self.lang[0].get(),
            self.lang[1].get(),
        ]))?;

        let Some(country) = self.country.as_ref() else {
            return Ok(());
        };

        f.write_str("/")?;
        f.write_str(&String::from_utf8_lossy(&[
            country[0].get(),
            country[1].get(),
        ]))
    }
}

impl PartialEq<Language> for str {
    fn eq(&self, lang: &Language) -> bool {
        lang_str_eq(lang, self)
    }
}

impl PartialEq<Language> for &str {
    fn eq(&self, lang: &Language) -> bool {
        lang_str_eq(lang, self)
    }
}

impl PartialEq<Language> for String {
    fn eq(&self, lang: &Language) -> bool {
        lang_str_eq(lang, self)
    }
}

impl PartialEq<String> for Language {
    fn eq(&self, string: &String) -> bool {
        lang_str_eq(self, string)
    }
}

impl PartialEq<str> for Language {
    fn eq(&self, string: &str) -> bool {
        lang_str_eq(self, string)
    }
}

impl PartialEq<&str> for Language {
    fn eq(&self, string: &&str) -> bool {
        lang_str_eq(self, string)
    }
}

/// [`Language`] preferences for a user
///
/// Returned from [`lang_prefs()`](crate::lang_prefs)
///
/// Fields are sorted in order of the user's preference.
///
/// POSIX locale values and GNU nonstandard categories are defined in
/// <https://man7.org/linux/man-pages/man7/locale.7.html>. Windows locale values
/// are defined in <https://learn.microsoft.com/en-us/cpp/c-runtime-library/locale-categories>.
#[derive(Debug, Clone, Default)]
pub struct LanguagePreferences {
    /// Determines general user language preference, should be used in
    /// situations which are not encompassed by other [`LanguagePreferences`].
    pub(crate) fallbacks: Vec<Language>,

    /// Determines collation rules used for sorting and regular expressions,
    /// including character equivalence classes and multicharacter collating
    /// elements.
    pub(crate) collation: Option<Language>,

    /// Determines the interpretation of byte sequences as characters (e.g.,
    /// single versus multibyte characters), character classifications (e.g.,
    /// alphabetic or digit), and the behavior of character classes.
    pub(crate) char_classes: Option<Language>,

    /// Determines the formatting used for monetary-related numeric values,
    /// i.e, the way numbers are usually printed with details such as
    /// decimal point versus decimal comma.
    pub(crate) monetary: Option<Language>,

    /// Determines the language in which messages are
    /// displayed and what an affirmative or negative answer looks
    /// like.
    pub(crate) messages: Option<Language>,

    /// Determines the formatting rules used for nonmonetary numeric values.
    /// For example, the thousands separator and the radix character.
    pub(crate) numeric: Option<Language>,

    /// Determines format and contents of date and time information.
    pub(crate) time: Option<Language>,
}

impl Display for LanguagePreferences {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        let langs: [(&str, Vec<Language>); 6] = [
            ("Collation", self.collation_langs().collect()),
            ("CharClasses", self.char_class_langs().collect()),
            ("Monetary", self.monetary_langs().collect()),
            ("Messages", self.message_langs().collect()),
            ("Numeric", self.numeric_langs().collect()),
            ("Time", self.time_langs().collect()),
        ];
        for (i, (name, langs)) in langs.iter().enumerate() {
            if i != 0 {
                f.write_str(",")?;
            }
            write!(f, "{name}=")?;
            for (j, lang) in langs.iter().enumerate() {
                if j != 0 {
                    f.write_str(":")?;
                }
                write!(f, "{lang}")?;
            }
        }

        Ok(())
    }
}

impl LanguagePreferences {
    fn chain_fallbacks<'a>(
        &'a self,
        l: &Option<Language>,
    ) -> impl Iterator<Item = Language> + 'a {
        let lang_without_country = if let Some(ref lang) = l {
            lang.country.is_some().then_some(Language {
                lang: lang.lang,
                country: None,
            })
        } else {
            None
        };

        (*l).into_iter()
            .chain(lang_without_country)
            .chain(self.fallbacks.iter().cloned())
    }

    /// Returns the collation langs of this [`LanguagePreferences`] in order of
    /// the user's preference
    ///
    /// Collation langs are used for sorting and regular expressions,
    /// including character equivalence classes and multicharacter collating
    /// elements.
    pub fn collation_langs(&self) -> impl Iterator<Item = Language> + '_ {
        self.chain_fallbacks(&self.collation)
    }

    /// Returns the char class langs of this [`LanguagePreferences`] in order of
    /// the user's preference
    ///
    /// Char class langs determine the interpretation of byte sequences as
    /// characters (e.g., single versus multibyte characters), character
    /// classifications (e.g., alphabetic or digit), and the behavior of
    /// character classes.
    pub fn char_class_langs(&self) -> impl Iterator<Item = Language> + '_ {
        self.chain_fallbacks(&self.char_classes)
    }

    /// Returns the monetary langs of this [`LanguagePreferences`] in order of
    /// the user's preference
    ///
    /// Monetary langs determine the formatting used for monetary-related
    /// numeric values, i.e, the way numbers are usually printed with details
    /// such as decimal point versus decimal comma.
    ///
    /// For nonmonetary numeric values, see
    /// [`LanguagePreferences::numeric_langs`]
    pub fn monetary_langs(&self) -> impl Iterator<Item = Language> + '_ {
        self.chain_fallbacks(&self.monetary)
    }

    /// Returns the messages langs of this [`LanguagePreferences`] in order of
    /// the user's preference
    ///
    /// Message determines the language in which messages are
    /// displayed and what an affirmative or negative answer looks
    /// like.
    pub fn message_langs(&self) -> impl Iterator<Item = Language> + '_ {
        self.chain_fallbacks(&self.messages)
    }

    /// Returns the numeric langs of this [`LanguagePreferences`] in order of
    /// the user's preference
    ///
    /// Numeric langs determine the formatting rules used for nonmonetary
    /// numeric values. For example, the thousands separator and the radix
    /// character.
    ///
    /// For monetary formatting, see [`LanguagePreferences::monetary_langs`].
    pub fn numeric_langs(&self) -> impl Iterator<Item = Language> + '_ {
        self.chain_fallbacks(&self.numeric)
    }

    /// Returns the time langs of this [`LanguagePreferences`] in order of the
    /// user's preference
    ///
    /// Time langs determine format and contents of date and time information.
    pub fn time_langs(&self) -> impl Iterator<Item = Language> + '_ {
        self.chain_fallbacks(&self.time)
    }

    pub(crate) fn add_stripped_fallbacks(mut self) -> Self {
        let mut no_country_langs = Vec::new();

        for lang in self.fallbacks.iter() {
            if lang.country.is_some() {
                no_country_langs.push(Language {
                    lang: lang.lang,
                    country: None,
                });
            } else {
                let Some(i) = no_country_langs.iter().position(|x| x == lang)
                else {
                    continue;
                };

                no_country_langs.remove(i);
            }
        }

        self.fallbacks.extend(no_country_langs);
        self
    }
}

fn lang_str_eq(language: &Language, string: &str) -> bool {
    let mut iter = string.split(SEPARATORS);
    let string_lang = iter.next().map(|s| s.as_bytes());
    let string_country = iter.next().map(|s| s.as_bytes());
    let end = iter.next();
    let lang = [language.lang[0].get(), language.lang[1].get()];
    let Some(country) = language.country.as_ref() else {
        return end.is_none()
            && string_lang == Some(&lang)
            && string_country.is_none();
    };
    let country = [country[0].get(), country[1].get()];

    end.is_none()
        && string_lang == Some(&lang)
        && string_country == Some(&country)
}

const SEPARATORS: &[char] = &['_', '-', '/'];
