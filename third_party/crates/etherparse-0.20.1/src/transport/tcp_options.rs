use crate::{tcp_option, TcpHeader, TcpOptionElement, TcpOptionWriteError, TcpOptionsIterator};

/// Options present in a TCP header.
///
/// # Examples (reading)
///
/// The underlying bytes can be accessed via the [`TcpOptions::as_slice`] method:
///
/// ```
/// use etherparse::{
///     TcpOptions,
///     tcp_option::{KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, KIND_END}
/// };
///
/// let tcp_options = TcpOptions::from([
///     KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, 2, KIND_END
/// ]);
///
/// // `as_slice` allows access to the raw encoded data
/// let slice = tcp_options.as_slice();
///
/// assert_eq!(
///     slice,
///     [KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, 2, KIND_END]
/// );
/// ```
///
/// It also possible to iterate over the decoded [`TcpOptionElement`]s
/// by calling [`TcpOptions::elements_iter`]:
///
/// ```
/// use etherparse::{
///     TcpOptions,
///     TcpOptionElement::WindowScale,
///     tcp_option::{KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, KIND_END}
/// };
///
/// let tcp_options = TcpOptions::from([
///     KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, 2, KIND_END
/// ]);
///
/// // `elements_iter` allows iteration over the decoded elements
/// // and decoding errors
/// let mut iter = tcp_options.elements_iter();
///
/// assert_eq!(
///     iter.collect::<Vec<_>>(),
///     vec![Ok(WindowScale(2))]
/// );
/// ```
///
/// # Examples (constructing)
///
/// Arrays of type `[u8;4]`, `[u8;8]`, `[u8;12]`, `[u8;16]`, `[u8;20]`,
/// `[u8;24]`, `[u8;28]`, `[u8;32]`, `[u8;36]`, `[u8;40]` can directly be
/// converted with the `from` or `into` methods to [`TcpOptions`]:
///
/// ```
/// use etherparse::TcpOptions;
///
/// // static sized arrays of size 4,8,... 40 can directly be converted
/// // via `from` or `into`
/// let options: TcpOptions = [1,2,3,4].into();
///
/// assert_eq!(&options[..], &[1,2,3,4]);
/// ```
///
/// Slices can be converted with `try_from` or `try_into` into [`TcpOptions`].
/// If the len of 40 bytes is exceeded an error is returned and if the
/// len is not a multiple of 4 the len is automatically increased to the next
/// multiple of 4 value and the data filled up with zeroes (equivalent to the
/// TCP END option):
///
/// ```
/// use etherparse::TcpOptions;
/// {
///     let data = [1u8,2,3,4,5,6,7,8];
///
///     // slices can be converted into TcpOptions via `try_from` or `try_into`
///     let options: TcpOptions = (&data[..]).try_into().unwrap();
///
///     assert_eq!(options.as_slice(), &data);
/// }
/// {
///     let data = [1u8];
///
///     // len is automatically increased to a multiple of 4 (filled
///     // with 0, also known as the END TCP option).
///     let options = TcpOptions::try_from(&data[..]).unwrap();
///
///     assert_eq!(options.as_slice(), &[1, 0, 0, 0]);
/// }
/// {
///     use etherparse::TcpOptionWriteError::NotEnoughSpace;
///
///     let data = [0u8;41]; // 41 bytes
///
///     // slices with a len bigger then 40 cause an error
///     let result = TcpOptions::try_from(&data[..]);
///     assert_eq!(result, Err(NotEnoughSpace(41)));
/// }
/// ```
///
/// Slices containing [`TcpOptionElement`]s can also be converted via
/// `try_from` or `try_into` as long as the encoded elements are within
/// 40 bytes:
///
/// ```
/// use etherparse::{
///     TcpOptions,
///     tcp_option::{KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, KIND_NOOP, KIND_END},
///     TcpOptionElement::{Noop, WindowScale}
/// };
///
/// let elements = [WindowScale(123), Noop, Noop];
///
/// // try_from encodes the options into the "on the wire" format
/// let options = TcpOptions::try_from(&elements[..]).unwrap();
///
/// assert_eq!(
///     options.as_slice(),
///     &[
///         KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, 123, KIND_NOOP,
///         KIND_NOOP, KIND_END, KIND_END, KIND_END
///     ]
/// );
/// ```
#[derive(Clone)]
pub struct TcpOptions {
    /// Number of bytes in the buffer.
    pub(crate) len: u8,

    /// Buffer containing the options of the header
    /// (note that the `len` field defines the actual length). Use
    /// the options() method if you want to get a slice that has
    /// the actual length of the options.
    pub(crate) buf: [u8; 40],
}

impl TcpOptions {
    /// Maximum number of bytes that can be part of an TCP options.
    pub const MAX_LEN: usize = 40;

    /// Constructs a new empty TcpOptions.
    #[inline]
    pub fn new() -> TcpOptions {
        TcpOptions {
            len: 0,
            buf: [0; 40],
        }
    }

    /// Tries to convert an `u8` slice into [`TcpOptions`].
    ///
    /// # Examples
    ///
    /// Slices with a length that is a multiple of 4 and a length not
    /// bigger than 40 can be converted one-to-one:
    ///
    /// ```
    /// use etherparse::TcpOptions;
    ///
    /// let data = [1u8,2,3,4,5,6,7,8];
    /// let options = TcpOptions::try_from_slice(&data[..]).unwrap();
    /// assert_eq!(options.as_slice(), &data);
    /// ```
    ///
    /// If the length is not a multiple of 4 it is automatically filled
    /// up with `0` (value of TCP option END) to the next multiple of 4:
    ///
    /// ```
    /// use etherparse::TcpOptions;
    /// {
    ///     let data = [1u8];
    ///     let options = TcpOptions::try_from(&data[..]).unwrap();
    ///     // 3 bytes of zero added so the len is a multiple of 4
    ///     assert_eq!(options.as_slice(), &[1, 0, 0, 0]);
    /// }
    /// ```
    ///
    /// In case more than 40 bytes are passed as input an error is returned:
    ///
    /// ```
    /// use etherparse::{
    ///     TcpOptions,
    ///     TcpOptionWriteError::NotEnoughSpace
    /// };
    ///
    /// let data = [0u8;41]; // 41 bytes
    ///
    /// // slices with a len bigger then 40 cause an error
    /// let result = TcpOptions::try_from(&data[..]);
    /// assert_eq!(result, Err(NotEnoughSpace(41)));
    /// ```
    pub fn try_from_slice(slice: &[u8]) -> Result<TcpOptions, TcpOptionWriteError> {
        // check length
        if Self::MAX_LEN < slice.len() {
            Err(TcpOptionWriteError::NotEnoughSpace(slice.len()))
        } else {
            let len = slice.len() as u8;

            // reset all to zero to ensure padding
            Ok(TcpOptions {
                len: ((len >> 2) << 2)
                    + if 0 != len & 0b11 {
                        // NOTE: If the slice length is not a multiple of
                        // 4 the length is automatically increased to be
                        // a multiple of 4 and the data is filled up with
                        // zeroes.
                        4
                    } else {
                        0
                    },
                buf: {
                    let mut buf = [0; 40];
                    buf[..slice.len()].copy_from_slice(slice);
                    buf
                },
            })
        }
    }

    /// Tries to convert [`crate::TcpOptionElement`] into serialized
    /// form as [`TcpOptions`].
    ///
    /// # Example
    ///
    /// ```
    /// use etherparse::{
    ///     TcpOptions,
    ///     tcp_option::{KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, KIND_NOOP, KIND_END},
    ///     TcpOptionElement::{Noop, WindowScale}
    /// };
    ///
    /// let elements = [WindowScale(123), Noop, Noop];
    ///
    /// // try_from encodes the options into the "on the wire" format
    /// let options = TcpOptions::try_from_elements(&elements[..]).unwrap();
    ///
    /// assert_eq!(
    ///     options.as_slice(),
    ///     &[
    ///         KIND_WINDOW_SCALE, LEN_WINDOW_SCALE, 123, KIND_NOOP,
    ///         // padding in form of "KIND_END" (0) is automatically added
    ///         // so the resulting options length is a multiple of 4
    ///         KIND_NOOP, KIND_END, KIND_END, KIND_END
    ///     ]
    /// );
    /// ```
    pub fn try_from_elements(
        elements: &[TcpOptionElement],
    ) -> Result<TcpOptions, TcpOptionWriteError> {
        // calculate the required size of the options
        use crate::TcpOptionElement::*;
        let required_len = elements.iter().fold(0, |acc, ref x| {
            acc + match x {
                Noop => 1,
                MaximumSegmentSize(_) => 4,
                WindowScale(_) => 3,
                SelectiveAcknowledgementPermitted => 2,
                SelectiveAcknowledgement(_, rest) => rest.iter().fold(10, |acc2, ref y| match y {
                    None => acc2,
                    Some(_) => acc2 + 8,
                }),
                Timestamp(_, _) => 10,
            }
        });

        if Self::MAX_LEN < required_len {
            Err(TcpOptionWriteError::NotEnoughSpace(required_len))
        } else {
            // reset the options to null
            let mut buf = [0u8; TcpOptions::MAX_LEN];
            let mut len: usize = 0;

            // write the options to the buffer
            use tcp_option::*;
            for element in elements {
                match element {
                    Noop => {
                        buf[len] = KIND_NOOP;
                        len += 1;
                    }
                    MaximumSegmentSize(value) => {
                        // determine insertion area
                        let t = &mut buf[len..len + 4];

                        // insert data
                        let value = value.to_be_bytes();
                        t[0] = KIND_MAXIMUM_SEGMENT_SIZE;
                        t[1] = 4;
                        t[2] = value[0];
                        t[3] = value[1];

                        len += 4;
                    }
                    WindowScale(value) => {
                        // determine insertion area
                        let t = &mut buf[len..len + 3];

                        // write data
                        t[0] = KIND_WINDOW_SCALE;
                        t[1] = 3;
                        t[2] = *value;

                        len += 3;
                    }
                    SelectiveAcknowledgementPermitted => {
                        // determine insertion area
                        let insert = &mut buf[len..len + 2];

                        // write data
                        insert[0] = KIND_SELECTIVE_ACK_PERMITTED;
                        insert[1] = 2;

                        len += 2;
                    }
                    SelectiveAcknowledgement(first, rest) => {
                        //write guaranteed data
                        {
                            let t = &mut buf[len..len + 10];
                            len += 10;

                            t[0] = KIND_SELECTIVE_ACK;
                            //write the length
                            t[1] = rest.iter().fold(10, |acc, ref y| match y {
                                None => acc,
                                Some(_) => acc + 8,
                            });
                            // write first
                            t[2..6].copy_from_slice(&first.0.to_be_bytes());
                            t[6..10].copy_from_slice(&first.1.to_be_bytes());
                        }
                        //write the rest
                        for v in rest {
                            match v {
                                None => {}
                                Some((a, b)) => {
                                    // determine insertion area
                                    let t = &mut buf[len..len + 8];

                                    // insert
                                    t[0..4].copy_from_slice(&a.to_be_bytes());
                                    t[4..8].copy_from_slice(&b.to_be_bytes());

                                    len += 8;
                                }
                            }
                        }
                    }
                    Timestamp(a, b) => {
                        let t = &mut buf[len..len + 10];

                        t[0] = KIND_TIMESTAMP;
                        t[1] = 10;
                        t[2..6].copy_from_slice(&a.to_be_bytes());
                        t[6..10].copy_from_slice(&b.to_be_bytes());

                        len += 10;
                    }
                }
            }
            // set the new data offset
            if (len > 0) && (0 != len & 0b11) {
                len = (len & (!0b11)) + 4;
            }
            // done
            Ok(TcpOptions {
                len: len as u8,
                buf,
            })
        }
    }

    /// The number of 32 bit words in the TCP Header & TCP header options.
    ///
    /// This indicates where the data begins relative to the start of an
    /// TCP header in multiples of 4 bytes. This number is
    /// present in the `data_offset` field of the header and defines
    /// the length of the tcp options present.
    ///
    /// # Example
    ///
    /// ```
    /// use etherparse::TcpOptions;
    ///
    /// {
    ///     let options = TcpOptions::try_from_slice(&[]).unwrap();
    ///     // in case there are no options the minimum size of the tcp
    ///     // is returned.
    ///     assert_eq!(5, options.data_offset());
    /// }
    /// {
    ///     let options = TcpOptions::try_from_slice(&[1,2,3,4,5,6,7,8]).unwrap();
    ///     // otherwise the base TCP header size plus the number of 4 byte
    ///     // words in the options is returned
    ///     assert_eq!(5 + 2, options.data_offset());
    /// }
    /// ```
    #[inline]
    pub fn data_offset(&self) -> u8 {
        TcpHeader::MIN_DATA_OFFSET + (self.len >> 2)
    }

    /// Number of bytes in the buffer as an unsigned 8 bit integer.
    #[inline]
    pub fn len_u8(&self) -> u8 {
        self.len
    }

    /// Number of bytes in the buffer.
    #[inline]
    pub fn len(&self) -> usize {
        self.len as usize
    }

    /// Returns true if the options contain no elements.
    #[inline]
    pub fn is_empty(&self) -> bool {
        0 == self.len
    }

    /// Slice containing the options.
    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        debug_assert!(self.len <= 40);
        // SAFETY: Safe as all constructing methods verify len to be less then 40.
        unsafe { core::slice::from_raw_parts(self.buf.as_ptr(), self.len()) }
    }

    /// Mutable slice containing the options.
    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        debug_assert!(self.len <= 40);
        // SAFETY: Safe as all constructing methods verify len to be less then 40.
        unsafe { core::slice::from_raw_parts_mut(self.buf.as_mut_ptr(), self.len()) }
    }

    /// Returns an iterator that allows to iterate through the
    /// decoded option elements.
    ///
    /// # Example
    ///
    /// ```
    /// use etherparse::{
    ///     TcpOptions,
    ///     TcpOptionElement::{Noop, WindowScale}
    /// };
    ///
    /// let options = TcpOptions::try_from(&[WindowScale(123), Noop, Noop][..]).unwrap();
    ///
    /// let mut v = Vec::with_capacity(3);
    /// for re in options.elements_iter() {
    ///     v.push(re);
    /// }
    /// assert_eq!(v, vec![Ok(WindowScale(123)), Ok(Noop), Ok(Noop)]);
    /// ```
    #[inline]
    pub fn elements_iter(&self) -> TcpOptionsIterator<'_> {
        TcpOptionsIterator {
            options: self.as_slice(),
        }
    }
}

impl Default for TcpOptions {
    #[inline]
    fn default() -> Self {
        Self {
            len: 0,
            buf: [0; 40],
        }
    }
}

impl core::cmp::Eq for TcpOptions {}
impl PartialEq for TcpOptions {
    fn eq(&self, other: &Self) -> bool {
        self.as_slice() == other.as_slice()
    }
}

impl<'a> TryFrom<&'a [u8]> for TcpOptions {
    type Error = TcpOptionWriteError;

    #[inline]
    fn try_from(value: &'a [u8]) -> Result<Self, Self::Error> {
        TcpOptions::try_from_slice(value)
    }
}

impl<'a> TryFrom<&'a [TcpOptionElement]> for TcpOptions {
    type Error = TcpOptionWriteError;

    #[inline]
    fn try_from(value: &'a [TcpOptionElement]) -> Result<Self, Self::Error> {
        TcpOptions::try_from_elements(value)
    }
}

impl core::fmt::Debug for TcpOptions {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.elements_iter().fmt(f)
    }
}

impl core::hash::Hash for TcpOptions {
    fn hash<H: core::hash::Hasher>(&self, state: &mut H) {
        self.as_slice().hash(state);
    }
}

impl core::cmp::PartialOrd for TcpOptions {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl core::cmp::Ord for TcpOptions {
    fn cmp(&self, other: &Self) -> core::cmp::Ordering {
        self.as_slice().cmp(other.as_slice())
    }
}

impl core::ops::Deref for TcpOptions {
    type Target = [u8];

    #[inline]
    fn deref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl AsRef<TcpOptions> for TcpOptions {
    #[inline]
    fn as_ref(&self) -> &TcpOptions {
        self
    }
}

impl AsMut<TcpOptions> for TcpOptions {
    #[inline]
    fn as_mut(&mut self) -> &mut TcpOptions {
        self
    }
}

impl AsRef<[u8]> for TcpOptions {
    #[inline]
    fn as_ref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl AsMut<[u8]> for TcpOptions {
    #[inline]
    fn as_mut(&mut self) -> &mut [u8] {
        self.as_mut_slice()
    }
}

macro_rules! from_static_array {
    ($x:expr) => {
        impl From<[u8; $x]> for TcpOptions {
            #[inline]
            fn from(values: [u8; $x]) -> Self {
                let mut result = TcpOptions {
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

impl From<[u8; 40]> for TcpOptions {
    fn from(values: [u8; 40]) -> Self {
        TcpOptions {
            len: 40,
            buf: values,
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::tcp_options_any;
    use core::ops::Deref;
    use proptest::prelude::*;
    use std::format;

    #[test]
    fn new() {
        assert_eq!(
            TcpOptions::new(),
            TcpOptions {
                len: 0,
                buf: [0; 40]
            }
        );
    }

    #[test]
    fn try_from_slice() {
        let actual = TcpOptions::try_from_slice(&[1, 2, 3, 4][..]);
        assert_eq!(actual, Ok(TcpOptions::from([1, 2, 3, 4])));
    }

    #[test]
    fn try_from_elements() {
        use crate::tcp_option::KIND_NOOP;
        use crate::TcpOptionElement::Noop;
        let actual = TcpOptions::try_from_elements(&[Noop, Noop, Noop, Noop][..]);
        assert_eq!(
            actual,
            Ok(TcpOptions::from([
                KIND_NOOP, KIND_NOOP, KIND_NOOP, KIND_NOOP
            ]))
        );
    }

    proptest! {
        #[test]
        fn data_offset(
            options in tcp_options_any()
        ) {
            assert_eq!(
                (5 + ((options.len as u64) / 4)) as u8,
                options.data_offset()
            );
        }
    }
    proptest! {
        #[test]
        fn len(
            options in tcp_options_any()
        ) {
            assert_eq!(options.len(), usize::from(options.len));
        }
    }

    proptest! {
        #[test]
        fn len_u8(
            options in tcp_options_any()
        ) {
            assert_eq!(options.len_u8(), options.len);
        }
    }

    proptest! {
        #[test]
        fn is_empty(
            options in tcp_options_any()
        ) {
            assert_eq!(options.is_empty(), 0 == options.len);
        }
    }

    #[test]
    fn as_slice() {
        let options = TcpOptions::from([1, 2, 3, 4]);
        assert_eq!(options.as_slice(), &[1, 2, 3, 4][..]);
    }

    #[test]
    fn as_mut_slice() {
        let mut options = TcpOptions::from([1, 2, 3, 4]);
        let r = options.as_mut_slice();
        r[0] = 5;
        assert_eq!(options.as_slice(), &[5, 2, 3, 4][..]);
    }

    #[test]
    fn options_iterator() {
        let options = TcpOptions::from([1, 2, 3, 4]);
        assert_eq!(
            options.elements_iter(),
            TcpOptionsIterator {
                options: &[1, 2, 3, 4][..]
            }
        );
    }

    #[test]
    fn default() {
        let actual: TcpOptions = Default::default();
        assert_eq!(0, actual.len);
        assert_eq!([0u8; 40], actual.buf);
    }

    #[test]
    fn try_from() {
        // from slice
        {
            let actual = TcpOptions::try_from(&[1, 2, 3, 4][..]);
            assert_eq!(actual, Ok(TcpOptions::from([1, 2, 3, 4])));
        }
        // from elements
        {
            use crate::tcp_option::KIND_NOOP;
            use crate::TcpOptionElement::Noop;
            let actual = TcpOptions::try_from(&[Noop, Noop, Noop, Noop][..]);
            assert_eq!(
                actual,
                Ok(TcpOptions::from([
                    KIND_NOOP, KIND_NOOP, KIND_NOOP, KIND_NOOP
                ]))
            );
        }
    }

    #[test]
    fn debug_fmt() {
        use crate::tcp_option::KIND_NOOP;
        let data = [KIND_NOOP, KIND_NOOP, KIND_NOOP, KIND_NOOP];
        let options = TcpOptions::from(data.clone());
        assert_eq!(
            format!("{:?}", TcpOptionsIterator { options: &data[..] }),
            format!("{:?}", options)
        );
    }

    #[test]
    fn clone_eq_hash_ord() {
        let a = TcpOptions::from([1u8, 2, 3, 4]);
        assert_eq!(a, a.clone());
        assert_ne!(a, TcpOptions::from([5u8, 6, 7, 8]));
        {
            use core::hash::{Hash, Hasher};
            use std::collections::hash_map::DefaultHasher;
            let a_hash = {
                let mut hasher = DefaultHasher::new();
                a.hash(&mut hasher);
                hasher.finish()
            };
            let b_hash = {
                let mut hasher = DefaultHasher::new();
                a.hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a_hash, b_hash);
        }
        {
            use core::cmp::Ordering;
            assert_eq!(a.cmp(&a), Ordering::Equal);
        }
    }

    #[test]
    pub fn partial_cmp() {
        use core::cmp::Ordering;
        let a = TcpOptions::from([1u8, 2, 3, 4]);
        assert_eq!(a.partial_cmp(&a), Some(Ordering::Equal));
    }

    #[test]
    fn deref() {
        let a = TcpOptions::from([1u8, 2, 3, 4]);
        assert_eq!(a.deref(), &[1u8, 2, 3, 4][..]);
    }

    #[test]
    fn as_ref() {
        // TcpOptions ref
        {
            let a = TcpOptions::from([1u8, 2, 3, 4]);
            let b: &TcpOptions = a.as_ref();
            assert_eq!(b, &TcpOptions::from([1u8, 2, 3, 4]));
        }
        // slice ref
        {
            let a = TcpOptions::from([1u8, 2, 3, 4]);
            let b: &[u8] = a.as_ref();
            assert_eq!(b, &[1u8, 2, 3, 4]);
        }
    }

    #[test]
    fn as_mut() {
        // TcpOptions ref
        {
            let mut a = TcpOptions::from([1u8, 2, 3, 4]);
            let b: &mut TcpOptions = a.as_mut();
            *b = TcpOptions::from([5u8, 6, 7, 8]);
            assert_eq!(a, TcpOptions::from([5u8, 6, 7, 8]));
        }
        // slice ref
        {
            let mut a = TcpOptions::from([1u8, 2, 3, 4]);
            let b: &mut [u8] = a.as_mut();
            assert_eq!(b, &[1u8, 2, 3, 4]);
            b[0] = 5;
            assert_eq!(a, TcpOptions::from([5u8, 2, 3, 4]));
        }
    }

    #[test]
    fn from() {
        assert_eq!(TcpOptions::from([1u8, 2, 3, 4]).as_slice(), &[1u8, 2, 3, 4]);
        assert_eq!(
            TcpOptions::from([1u8, 2, 3, 4, 5, 6, 7, 8]).as_slice(),
            &[1u8, 2, 3, 4, 5, 6, 7, 8]
        );
        assert_eq!(
            TcpOptions::from([1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]).as_slice(),
            &[1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        );
        assert_eq!(
            TcpOptions::from([1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]).as_slice(),
            &[1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        );
        assert_eq!(
            TcpOptions::from([
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20
            ])
            .as_slice(),
            &[1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
        );
        assert_eq!(
            TcpOptions::from([
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24
            ])
            .as_slice(),
            &[
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24
            ]
        );
        assert_eq!(
            TcpOptions::from([
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28
            ])
            .as_slice(),
            &[
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28
            ]
        );
        assert_eq!(
            TcpOptions::from([
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28, 29, 30, 31, 32
            ])
            .as_slice(),
            &[
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28, 29, 30, 31, 32
            ]
        );
        assert_eq!(
            TcpOptions::from([
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36
            ])
            .as_slice(),
            &[
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36
            ]
        );
        assert_eq!(
            TcpOptions::from([
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40
            ])
            .as_slice(),
            &[
                1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40
            ]
        );
    }
}
