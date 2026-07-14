#![doc(html_logo_url = "https://www.rust-lang.org/logos/rust-logo-128x128-blk-v2.png",
       html_favicon_url = "https://www.rust-lang.org/favicon.ico",
       html_root_url = "https://wisagan.github.io/simple-error/simple_error/")]
#![deny(missing_docs)]
//! A simple error type backed by a string.
//!
//! This crate provides a `SimpleError` type, which implements `std::error::Error`. The underlying
//! is a `String` as the error message.
//!
//! It should be used when all you care about is an error string.
//!
//! It should not be used when you want to programmatically handle different kinds of an error.

use std::fmt;

/// A type that represents a simple error.
///
/// This type uses a `String` to store the error string, and it implements `std::error::Error`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SimpleError {
    err: String,
}

impl SimpleError {
    /// Creates a new simple error.
    ///
    /// This function can take any type that implements `Into<String>`.
    ///
    /// # Examples
    ///
    /// ```
    /// use self::simple_error::SimpleError;
    ///
    /// // errors can be created from `str`
    /// let err = SimpleError::new("an error from str");
    ///
    /// // errors can also be created from `String`
    /// let err = SimpleError::new(String::from("an error from String"));
    /// ```
    #[inline]
    pub fn new<T: Into<String>>(t: T) -> SimpleError {
        SimpleError{ err: t.into() }
    }

    /// Creates a new simple error from another error.
    ///
    /// This function can take any type that implements `std::error::Error`.
    /// The error string will be the `Display` of the `std::error::Error`.
    ///
    /// # Examples
    ///
    /// ```
    /// use self::simple_error::SimpleError;
    /// use std::io;
    ///
    /// // errors can be created from `io::Error`
    /// let err = SimpleError::from(io::Error::new(io::ErrorKind::Other, "oh no"));
    /// assert_eq!("oh no", format!("{}", err));
    /// ```
    #[inline]
    pub fn from<T: std::error::Error>(t: T) -> SimpleError {
        SimpleError{ err: format!("{}", t) }
    }

    /// Creates a new simple error from a string with another error.
    ///
    /// This function takes a string as error and a type that implements `std::error::Error` as
    /// reason.
    /// The error string will be the `Display` of the `std::error::Error` prefixed with the string
    /// and ", ".
    ///
    /// # Examples
    ///
    /// ```
    /// use self::simple_error::SimpleError;
    ///
    /// let err = SimpleError::with("cannot turn on tv", SimpleError::new("remote not found"));
    /// assert_eq!("cannot turn on tv, remote not found", format!("{}", err));
    /// ```
    #[inline]
    pub fn with<T: std::error::Error>(s: &str, t: T) -> SimpleError {
        SimpleError{ err: format!("{}, {}", s, t) }
    }

    /// Extracts a string slice describing the error.
    ///
    /// # Examples
    ///
    /// ```
    /// use self::simple_error::SimpleError;
    ///
    /// let s = SimpleError::new("critical error");
    /// assert_eq!("critical error", s.as_str());
    /// ```
    #[inline]
    pub fn as_str(&self) -> &str {
        &self.err
    }
}

// TODO: implement From<T> where T: std::error::Error when specialization lands, and remove
// inherent from function.

impl<'a> From<&'a str> for SimpleError {
    #[inline]
    fn from(s: &str) -> SimpleError {
        SimpleError{ err: s.into() }
    }
}

impl fmt::Display for SimpleError {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.err.fmt(f)
    }
}

impl std::error::Error for SimpleError {
    #[inline]
    fn description(&self) -> &str {
        &self.err
    }
}

/// Result type in which the error is a simple error
pub type SimpleResult<T> = Result<T, SimpleError>;

/// Helper macro for unwrapping `Result` values while returning early with a
/// newly constructed `SimpleError` if the value of the expression is `Err`.
/// Can only be used in functions that return `Result<_, SimpleError>`.
///
///
/// # Examples
///
/// ```
/// # #[macro_use] extern crate simple_error;
/// # fn main() {
/// use self::simple_error::SimpleError;
/// use std::error::Error;
///
/// fn try_block(result: Result<(), SimpleError>, s: &str) -> Result<(), SimpleError> {
///     Ok(try_with!(result, s))
/// }
///
/// // Above is equivalent to below.
///
/// fn try_block_equivalent(result: Result<(), SimpleError>, s: &str) -> Result<(), SimpleError> {
///     match result {
///         Ok(v) => Ok(v),
///         Err(e) => {
///             return Err(SimpleError::with(s, e));
///         },
///     }
/// }
///
/// // Use a format string
///
/// fn try_block_format(result: Result<(), SimpleError>, s: &str) -> Result<(), SimpleError> {
///     Ok(try_with!(result, "with {}", s))
/// }
///
/// // Use a format string to a boxed error
///
/// fn try_block_format_to_box_error(result: Result<(), SimpleError>, s: &str) -> Result<(), Box<Error>> {
///     Ok(try_with!(result, "with {}", s))
/// }
/// # }
/// ```
#[macro_export]
macro_rules! try_with {
    ($expr: expr, $str: expr) => (match $expr {
        Ok(val) => val,
        Err(err) => {
            return Err(::std::convert::From::from($crate::SimpleError::with($str.as_ref(), err)));
        },
    });
    ($expr: expr, $fmt:expr, $($arg:tt)+) => (match $expr {
        Ok(val) => val,
        Err(err) => {
            return Err(::std::convert::From::from($crate::SimpleError::with(&format!($fmt, $($arg)+), err)));
        },
    });
}

/// Helper macro for unwrapping `Option` values while returning early with a
/// newly constructed `SimpleError` if the value of the expression is `None`.
/// Can only be used in functions that return `Result<_, SimpleError>`.
///
///
/// # Examples
///
/// ```
/// # #[macro_use] extern crate simple_error;
/// # fn main() {
/// use self::simple_error::SimpleError;
/// use std::error::Error;
///
/// fn require_block(maybe: Option<()>, s: &str) -> Result<(), SimpleError> {
///     Ok(require_with!(maybe, s))
/// }
///
/// // Above is equivalent to below.
///
/// fn require_block_equivalent(maybe: Option<()>, s: &str) -> Result<(), SimpleError> {
///     match maybe {
///         Some(v) => Ok(v),
///         None => {
///             return Err(SimpleError::new(s));
///         },
///     }
/// }
///
/// // Use a format string
///
/// fn require_block_format(maybe: Option<()>, s: &str) -> Result<(), SimpleError> {
///     Ok(require_with!(maybe, "with {}", s))
/// }
///
/// // Use a format string to a boxed error
///
/// fn require_block_format_to_box_error(maybe: Option<()>, s: &str) -> Result<(), Box<Error>> {
///     Ok(require_with!(maybe, "with {}", s))
/// }
/// # }
/// ```
#[macro_export]
macro_rules! require_with {
    ($expr: expr, $str: expr) => (match $expr {
        Some(val) => val,
        None => {
            return Err(::std::convert::From::from($crate::SimpleError::new(::std::convert::AsRef::<str>::as_ref($str))));
        },
    });
    ($expr: expr, $fmt:expr, $($arg:tt)+) => (match $expr {
        Some(val) => val,
        None => {
            return Err(::std::convert::From::from($crate::SimpleError::new(format!($fmt, $($arg)+))));
        },
    });
}

/// Helper macro for returning a `SimpleError` constructed from either a `Into<SimpleError>`, a
/// string slice, or a formatted string.
///
/// # Examples
///
/// ```
/// # #[macro_use] extern crate simple_error;
/// # fn main() {
/// use self::simple_error::SimpleError;
/// use std::error::Error;
/// // Use with a `Into<SimpleError>`
///
/// struct ErrorSeed;
///
/// impl From<ErrorSeed> for SimpleError {
///     fn from(_: ErrorSeed) -> SimpleError {
///         SimpleError::new(".")
///     }
/// }
///
/// fn bail_block_into(es: ErrorSeed) -> Result<(), SimpleError> {
///     bail!(es);
/// }
///
/// // Use with a string slice
/// fn bail_block_str(s: &str) -> Result<(), SimpleError> {
///     bail!(s);
/// }
///
/// // Use with a formatted string
/// fn bail_block_format(s: &str) -> Result<(), SimpleError> {
///     bail!("reason: {}", s);
/// }
///
/// // Use with a formatted string to a boxed error
/// fn bail_block_format_to_box_error(s: &str) -> Result<(), Box<Error>> {
///     bail!("reason: {}", s);
/// }
/// # }
/// ```
#[macro_export]
macro_rules! bail {
    ($e:expr) => {
        return Err(::std::convert::From::from($e));
    };
    ($fmt:expr, $($arg:tt)+) => {
        return Err(::std::convert::From::from($crate::SimpleError::new(format!($fmt, $($arg)+))));
    };
}

/// Construct an ad-hoc `SimpleError` from a string.
///
/// It can take either just a string, or a format string with arguments.
///
/// # Example
///
/// ```
/// # #[macro_use] extern crate simple_error;
/// # fn main() {
/// use self::simple_error::SimpleResult;
///
/// fn add_reason(r: Result<(), ()>) -> SimpleResult<()> {
///     // Use with a string slice
///     r.map_err(|_| simple_error!("no reason"))
/// }
///
/// fn add_reason_with_str(r: Result<(), ()>, s: &str) -> SimpleResult<()> {
///     // Use with a formatted string
///     r.map_err(|_| simple_error!("reason: {}", s))
/// }
/// # }
/// ```
#[macro_export]
macro_rules! simple_error {
    ($e:expr) => {
        $crate::SimpleError::new($e)
    };
    ($fmt:expr, $($arg:tt)+) => {
        $crate::SimpleError::new(format!($fmt, $($arg)+))
    };
}

/// Map a result type error to simple error with format
///
/// It can take either just a string, or a format string with arguments.
///
/// # Example
///
/// ```
/// # #[macro_use] extern crate simple_error;
/// # fn main() {
/// use self::simple_error::SimpleResult;
///
/// fn map_err_with_reason(r: Result<(), std::io::Error>) -> SimpleResult<()> {
///     // Use with a string slice
///     map_err_with!(r, "no reason")
/// }
///
/// fn map_err_with_reason_with_str(r: Result<(), std::io::Error>, s: &str) -> SimpleResult<()> {
///     // Use with a formatted string
///     map_err_with!(r, "no reason: {}", s)
/// }
/// # }
/// ```
#[macro_export]
macro_rules! map_err_with {
    ($r: expr, $str: expr) => {
        $r.map_err(|e| $crate::SimpleError::with($str.as_ref(), e))
    };
    ($r: expr, $fmt:expr, $($arg:tt)+) => {
        $r.map_err(|e| $crate::SimpleError::with(&format!($fmt, $($arg)+), e))
    };
}


#[cfg(test)]
mod tests {
    use super::SimpleError;
    use std::error::Error;
    use std::io;

    pub struct ErrorSeed;

    impl From<ErrorSeed> for SimpleError {
        fn from(_: ErrorSeed) -> SimpleError {
            SimpleError::new(".")
        }
    }

    #[test]
    fn new_from_string() {
        let err = SimpleError::new(String::from("an error from String"));
        assert_eq!("an error from String", format!("{}", err));
        assert_eq!("an error from String", err.description());
    }

    #[test]
    fn new_from_str() {
        let err = SimpleError::new("an error from str");
        assert_eq!("an error from str", format!("{}", err));
    }

    #[test]
    fn from_io_error() {
        let err = SimpleError::from(io::Error::new(io::ErrorKind::Other, "oh no"));
        assert_eq!("oh no", format!("{}", err));
    }

    fn try_block(result: Result<(), SimpleError>, s: &str) -> Result<(), SimpleError> {
        Ok(try_with!(result, s))
    }

    fn try_block_format(result: Result<(), SimpleError>, s: &str) -> Result<(), SimpleError> {
        Ok(try_with!(result, "with {}", s))
    }

    #[test]
    fn macro_try_with() {
        assert_eq!(Ok(()), try_block(Ok(()), ""));
        assert_eq!(Err(SimpleError::new("try block error, error foo")), try_block(Err(SimpleError::new("error foo")), "try block error"));
        assert_eq!(Err(SimpleError::new("with try block error, error foo")), try_block_format(Err(SimpleError::new("error foo")), "try block error"));
    }

    fn require_block(option: Option<()>, s: &str) -> Result<(), SimpleError> {
        Ok(require_with!(option, s))
    }

    fn require_block_str_as_ref(option: Option<()>, s: &String) -> Result<(), SimpleError> {
        Ok(require_with!(option, s))
    }

    fn require_block_format(maybe: Option<()>, s: &str) -> Result<(), SimpleError> {
        Ok(require_with!(maybe, "with {}", s))
    }

    #[test]
    fn macro_require_with() {
        assert_eq!(Ok(()), require_block(Some(()), ""));
        assert_eq!(Err(SimpleError::new("require block error")), require_block(None, "require block error"));
        assert_eq!(Err(SimpleError::new("require block error")), require_block_str_as_ref(None, &"require block error".to_owned()));
        assert_eq!(Err(SimpleError::new("with require block error")), require_block_format(None, "require block error"));
    }

    fn bail_block_into(es: ErrorSeed) -> Result<(), SimpleError> {
        bail!(es);
    }

    fn bail_block_str(s: &str) -> Result<(), SimpleError> {
        bail!(s);
    }

    fn bail_block_format(s: &str) -> Result<(), SimpleError> {
        bail!("reason: {}", s);
    }

    fn bail_block_format_to_box_error(s: &str) -> Result<(), Box<Error>> {
        bail!("reason: {}", s);
    }

    #[test]
    fn macro_bail() {
        assert_eq!(Err(SimpleError::new(".")), bail_block_into(ErrorSeed));
        assert_eq!(Err(SimpleError::new("no reason")), bail_block_str("no reason"));
        assert_eq!(Err(SimpleError::new("reason: plane crashed")), bail_block_format("plane crashed"));
        assert!(bail_block_format_to_box_error("plane crashed").is_err());
    }
}
