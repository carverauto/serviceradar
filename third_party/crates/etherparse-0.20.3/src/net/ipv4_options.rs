use core::borrow::{Borrow, BorrowMut};

/// Options present in an [`crate::Ipv4Header`].
///
/// IPv4 header options can only have a length that
/// is a multiple of 4 bytes (meaning 4, 8, 12, ...) and
/// a maximum length of 40 bytes (40 bytes the maximum length is
/// limited by maximum value of the "intra header length" field
/// in the IPv4 header).
///
/// # Examples
///
/// ```
/// use etherparse::Ipv4Options;
///
/// {
///     // static sized arrays of size 4,8,... 40 can directly be converted
///     let options: Ipv4Options = [1,2,3,4].into();
///     assert_eq!(&options[..], &[1,2,3,4]);
/// }
///
/// {
///     // slices can also be "try_from" converted
///     let some_data = vec![1,2,3,4,5,6,7,8];
///     let options: Ipv4Options = (&some_data[..]).try_into().unwrap();
///     assert_eq!(options.as_slice(), &[1,2,3,4,5,6,7,8]);
/// }
/// {
///     // only slices with a length that is multiple of 4 and a maximum value of 40
///     // can be converted, otherwise you will get an error
///     use etherparse::err::ipv4::BadOptionsLen;
///
///     let result = Ipv4Options::try_from(&[1,2,3][..]);
///     assert_eq!(result, Err(BadOptionsLen { bad_len: 3 }));
/// }
/// ```
#[derive(Clone)]
pub struct Ipv4Options {
    pub(crate) len: u8,
    pub(crate) buf: [u8; 40],
}

impl Ipv4Options {
    /// Maximum length of the IPv4 options in bytes.
    pub const MAX_LEN: u8 = 40;

    /// Setup an empty options array.
    #[inline]
    pub fn new() -> Ipv4Options {
        Ipv4Options {
            len: 0,
            buf: [0; 40],
        }
    }

    /// Returns the slice containing the data of the options.
    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        unsafe { core::slice::from_raw_parts(self.buf.as_ptr(), self.len.into()) }
    }

    /// Returns a mutable slice containing the data of the options.
    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        unsafe { core::slice::from_raw_parts_mut(self.buf.as_mut_ptr(), self.len.into()) }
    }

    /// Returns the length of the options in bytes.
    #[inline]
    pub fn len(&self) -> usize {
        usize::from(self.len)
    }

    /// Returns the length of the options in bytes.
    #[inline]
    pub fn len_u8(&self) -> u8 {
        self.len
    }

    /// Returns if the length of the options is zero.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

impl TryFrom<&[u8]> for Ipv4Options {
    type Error = crate::err::ipv4::BadOptionsLen;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        if value.len() <= 40 && value.len() % 4 == 0 {
            let mut result = Ipv4Options {
                len: value.len() as u8,
                buf: [0; 40],
            };
            unsafe {
                // SAFETY: Safe as value.len() <= 40 and the result buffer size is 40.
                core::ptr::copy_nonoverlapping(
                    value.as_ptr(),
                    result.buf.as_mut_ptr(),
                    value.len(),
                );
            }
            Ok(result)
        } else {
            Err(Self::Error {
                bad_len: value.len(),
            })
        }
    }
}

impl Default for Ipv4Options {
    #[inline]
    fn default() -> Self {
        Self {
            len: 0,
            buf: [0; 40],
        }
    }
}

impl core::fmt::Debug for Ipv4Options {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.as_slice().fmt(f)
    }
}

impl PartialEq for Ipv4Options {
    fn eq(&self, other: &Self) -> bool {
        self.as_slice() == other.as_slice()
    }
}
impl Eq for Ipv4Options {}

impl core::hash::Hash for Ipv4Options {
    fn hash<H: core::hash::Hasher>(&self, state: &mut H) {
        self.as_slice().hash(state);
    }
}

impl core::cmp::PartialOrd for Ipv4Options {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl core::cmp::Ord for Ipv4Options {
    fn cmp(&self, other: &Self) -> core::cmp::Ordering {
        self.as_slice().cmp(other.as_slice())
    }
}

impl From<[u8; 0]> for Ipv4Options {
    #[inline]
    fn from(_: [u8; 0]) -> Self {
        Ipv4Options {
            len: 0,
            buf: [0; 40],
        }
    }
}

macro_rules! from_static_array {
    ($x:expr) => {
        impl From<[u8; $x]> for Ipv4Options {
            #[inline]
            fn from(values: [u8; $x]) -> Self {
                let mut result = Ipv4Options {
                    len: $x,
                    buf: [0; 40],
                };
                let r = result.buf.as_mut_ptr() as *mut [u8; $x];
                unsafe {
                    *r = values;
                }
                result
            }
        }
    };
}

from_static_array!(4);
from_static_array!(8);
from_static_array!(12);
from_static_array!(16);
from_static_array!(20);
from_static_array!(24);
from_static_array!(28);
from_static_array!(32);
from_static_array!(36);

impl From<[u8; 40]> for Ipv4Options {
    fn from(values: [u8; 40]) -> Self {
        Ipv4Options {
            len: 40,
            buf: values,
        }
    }
}

impl AsRef<Ipv4Options> for Ipv4Options {
    fn as_ref(&self) -> &Ipv4Options {
        self
    }
}

impl AsRef<[u8]> for Ipv4Options {
    fn as_ref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl AsMut<Ipv4Options> for Ipv4Options {
    fn as_mut(&mut self) -> &mut Ipv4Options {
        self
    }
}

impl AsMut<[u8]> for Ipv4Options {
    fn as_mut(&mut self) -> &mut [u8] {
        self.as_mut_slice()
    }
}

impl Borrow<[u8]> for Ipv4Options {
    fn borrow(&self) -> &[u8] {
        self.as_slice()
    }
}

impl BorrowMut<[u8]> for Ipv4Options {
    fn borrow_mut(&mut self) -> &mut [u8] {
        self.as_mut_slice()
    }
}

impl core::ops::Deref for Ipv4Options {
    type Target = [u8];

    #[inline]
    fn deref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl core::ops::DerefMut for Ipv4Options {
    #[inline]
    fn deref_mut(&mut self) -> &mut [u8] {
        self.as_mut_slice()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_gens::*;
    use proptest::prelude::*;
    use std::format;

    #[test]
    fn new() {
        let actual = Ipv4Options::new();
        assert_eq!(actual.len, 0);
        assert_eq!(actual.buf, [0; 40]);
    }

    #[test]
    fn is_empty() {
        {
            let actual = Ipv4Options::new();
            assert!(actual.is_empty());
        }
        {
            let actual: Ipv4Options = [1, 2, 3, 4].into();
            assert_eq!(false, actual.is_empty());
        }
    }

    #[test]
    fn try_from() {
        const DATA: [u8; 48] = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
            25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            47, 48,
        ];

        // ok cases
        for len_div_4 in 0usize..=10 {
            let mut actual = Ipv4Options::try_from(&DATA[..len_div_4 * 4]).unwrap();
            assert_eq!(actual.as_slice(), &DATA[..len_div_4 * 4]);
            assert_eq!(actual.as_mut_slice(), &DATA[..len_div_4 * 4]);
            assert_eq!(actual.len_u8(), (len_div_4 * 4) as u8);
            assert_eq!(actual.len(), len_div_4 * 4);
        }

        // error cases
        use crate::err::ipv4::BadOptionsLen;
        for len in 0usize..48 {
            if (len % 4 != 0) || len > 40 {
                assert_eq!(
                    Err(BadOptionsLen { bad_len: len }),
                    Ipv4Options::try_from(&DATA[..len])
                )
            }
        }
    }

    #[test]
    fn default() {
        let actual: Ipv4Options = Default::default();
        assert_eq!(actual.len, 0);
        assert_eq!(actual.buf, [0; 40]);
    }

    proptest! {
        #[test]
        fn clone_dbg(options in ipv4_options_any()) {
            assert_eq!(
                format!("{:?}", options),
                format!("{:?}", options.clone().as_slice())
            );
        }
    }

    proptest! {
        #[test]
        fn eq_partial_eq(
            a in ipv4_options_any(),
            b in ipv4_options_any()
        ) {
            assert_eq!(a.eq(&b), a.as_slice().eq(b.as_slice()));
            assert_eq!(a == b, a.as_slice() == b.as_slice());
        }
    }

    proptest! {
        #[test]
        fn hash(
            options in ipv4_options_any()
        ) {
            use std::collections::hash_map::DefaultHasher;
            use core::hash::{Hash, Hasher};
            let a = {
                let mut hasher = DefaultHasher::new();
                options.hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                options.hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn ord_partial_ord(
            a in ipv4_options_any(),
            b in ipv4_options_any()
        ) {
            assert_eq!(a.cmp(&b), a.as_slice().cmp(&b.as_slice()));
            assert_eq!(a.partial_cmp(&b), a.as_slice().partial_cmp(&b.as_slice()));
        }
    }

    #[test]
    fn from_0_byte_array() {
        let options: Ipv4Options = [].into();
        assert_eq!(&options[..], &[]);
    }

    macro_rules! from_static_array_test {
        ($func_name:ident, $x:expr) => {
            #[test]
            fn $func_name() {
                {
                    let options: Ipv4Options = [$x; $x].into();
                    assert_eq!(&options[..], &[$x; $x]);
                }
                assert_eq!(&Ipv4Options::from([$x; $x])[..], &[$x; $x]);
            }
        };
    }

    from_static_array_test!(from_arr_4, 4);
    from_static_array_test!(from_arr_8, 8);
    from_static_array_test!(from_arr_12, 12);
    from_static_array_test!(from_arr_16, 16);
    from_static_array_test!(from_arr_20, 20);
    from_static_array_test!(from_arr_24, 24);
    from_static_array_test!(from_arr_28, 28);
    from_static_array_test!(from_arr_32, 32);
    from_static_array_test!(from_arr_36, 36);
    from_static_array_test!(from_arr_40, 40);

    proptest! {
        #[test]
        fn as_ref(options in ipv4_options_any()) {
            // as object reference
            {
                let r: &Ipv4Options = options.as_ref();
                assert_eq!(r, &options);
            }
            // as slice reference
            {
                let r: &[u8] = options.as_ref();
                assert_eq!(r, options.as_slice());
            }
        }
    }

    proptest! {
        #[test]
        fn as_mut(options in ipv4_options_any()) {
            // as object reference
            {
                let mut o = options.clone();
                let r: &mut Ipv4Options = o.as_mut();
                if r.len() > 0 {
                    r[0] = 123;
                    assert_eq!(123, o.as_slice()[0]);
                }
            }
            // as slice reference
            {
                let mut o = options.clone();
                let r: &mut [u8] = o.as_mut();
                if r.len() > 0 {
                    r[0] = 123;
                    assert_eq!(123, o.as_slice()[0]);
                }
            }
        }
    }

    proptest! {
        #[test]
        fn borrow(options in ipv4_options_any()) {
            // as object reference
            {
                let r: &Ipv4Options = options.borrow();
                assert_eq!(r, &options);
            }
            // as slice reference
            {
                let r: &[u8] = options.borrow();
                assert_eq!(r, options.as_slice());
            }
        }
    }

    proptest! {
        #[test]
        fn borrow_mut(options in ipv4_options_any()) {
            // as object reference
            {
                let mut o = options.clone();
                let r: &mut Ipv4Options = o.borrow_mut();
                if r.len() > 0 {
                    r[0] = 123;
                    assert_eq!(123, o.as_slice()[0]);
                }
            }
            // as slice reference
            {
                let mut o = options.clone();
                let r: &mut [u8] = o.borrow_mut();
                if r.len() > 0 {
                    r[0] = 123;
                    assert_eq!(123, o.as_slice()[0]);
                }
            }
        }
    }

    #[test]
    fn deref() {
        let options: Ipv4Options = [1, 2, 3, 4].into();
        let s: &[u8] = &options;
        assert_eq!(s, &[1, 2, 3, 4]);
        assert_eq!(&options[..], &[1, 2, 3, 4]);
    }

    #[test]
    fn deref_mut() {
        let mut options: Ipv4Options = [1, 2, 3, 4].into();
        let s: &mut [u8] = &mut options;
        assert_eq!(s, &[1, 2, 3, 4]);
    }
}
