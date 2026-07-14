/// Wraps the `core::hint::likely` intrinsic if the `nightly` feature is enabled.
#[inline(always)]
pub(crate) const fn likely(x: bool) -> bool {
    #[cfg(feature = "nightly")] {
        core::hint::likely(x)
    }

    #[cfg(not(feature = "nightly"))] {
        if !x {
            cold_path();
        }

        x
    }
}

/// Wraps the `core::hint::unlikely` intrinsic if the `nightly` feature is enabled.
#[inline(always)]
pub(crate) const fn unlikely(x: bool) -> bool {
    #[cfg(feature = "nightly")] {
        core::hint::unlikely(x)
    }

    #[cfg(not(feature = "nightly"))] {
        if x {
            cold_path();
        }

        x
    }
}

#[allow(dead_code)]
#[cold]
#[inline(always)]
const fn cold_path() {}

/// Provides a stable `assume` function that uses `core::hint::assert_unchecked` when the stable
/// rust compiler supports it.
///
/// This is particularly relevant when LLVM isn't able to specialise the >16 input functions. This
/// often happens with the default release profile, which uses a large number of codegen units and
/// LTO off.
#[cfg_attr(not(docsrs), rustversion::since(1.81))]
#[inline(always)]
pub(crate) const unsafe fn assume(cond: bool) {
    debug_assert!(cond);
    core::hint::assert_unchecked(cond);
}

/// Provides a stable `assume` function that uses `core::hint::assert_unchecked` when the stable
/// rust compiler supports it.
#[cfg_attr(not(docsrs), rustversion::before(1.81))]
#[cfg_attr(docsrs, cfg(not(docsrs)))]
#[inline(always)]
pub(crate) const unsafe fn assume(cond: bool) {
    debug_assert!(cond);
}
