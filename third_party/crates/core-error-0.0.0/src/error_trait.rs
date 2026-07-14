use core::fmt::{Debug, Display};

/// `Error` is a trait representing the basic expectations for error values,
/// i.e., values of type `E` in [`Result<T, E>`]. Errors must describe
/// themselves through the [`Display`] and [`Debug`] traits, and may provide
/// cause chain information:
///
/// The [`source`] method is generally used when errors cross "abstraction
/// boundaries". If one module must report an error that is caused by an error
/// from a lower-level module, it can allow access to that error via the
/// [`source`] method. This makes it possible for the high-level module to
/// provide its own errors while also revealing some of the implementation for
/// debugging via [`source`] chains.
///
/// [`Result<T, E>`]: ../result/enum.Result.html
/// [`Display`]: ../fmt/trait.Display.html
/// [`Debug`]: ../fmt/trait.Debug.html
/// [`source`]: trait.Error.html#method.source
pub trait Error: Debug + Display {
    fn description(&self) -> &str {
        "description() is deprecated; use Display"
    }
    fn cause(&self) -> Option<&Error> {
        self.source()
    }
    fn source(&self) -> Option<&(Error + 'static)> {
        None
    }
}

macro_rules! impl_error {
    ($( #[$version:meta] $ty:path),*) => {
        $(
            #[$version]
            impl Error for $ty { }
        )*
    };
}

// All errors supported by our minimum suported Rust version can be supported by
// default.
impl_error! {
    #[cfg(rustc_1_0_0)]   ::core::str::ParseBoolError,
    #[cfg(rustc_1_0_0)]   ::core::str::Utf8Error,
    #[cfg(rustc_1_0_0)]   ::core::num::ParseIntError,
    #[cfg(rustc_1_0_0)]   ::core::num::ParseFloatError,
    #[cfg(rustc_1_11_0)]  ::core::fmt::Error,
    #[cfg(rustc_1_13_0)]  ::core::cell::BorrowMutError,
    #[cfg(rustc_1_13_0)]  ::core::cell::BorrowError,
    #[cfg(rustc_1_20_0)]  ::core::char::ParseCharError,
    // Added in 1.27.0 in libcore. Added in 1.9.0 in libstd.
    // Rust is full of lies.
    #[cfg(rustc_1_27_0)]  ::core::char::DecodeUtf16Error,
    #[cfg(rustc_1_34_0)]  ::core::num::TryFromIntError,
    #[cfg(rustc_1_34_0)]  ::core::array::TryFromSliceError,
    #[cfg(rustc_1_34_0)]  ::core::char::CharTryFromError
}