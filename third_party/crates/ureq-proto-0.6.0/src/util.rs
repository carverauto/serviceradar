use std::fmt;
use std::io::{self, Cursor};
use std::ops::{Deref, DerefMut};

pub(crate) fn find_crlf(b: &[u8]) -> Option<usize> {
    let cr = b.iter().position(|c| *c == b'\r')?;
    let maybe_lf = b.get(cr + 1)?;
    if *maybe_lf == b'\n' { Some(cr) } else { None }
}

pub(crate) fn compare_lowercase_ascii(a: &str, lowercased: &str) -> bool {
    if a.len() != lowercased.len() {
        return false;
    }

    for (a, b) in a.chars().zip(lowercased.chars()) {
        if !a.is_ascii() {
            return false;
        }
        let norm = a.to_ascii_lowercase();
        if norm != b {
            return false;
        }
    }

    true
}

pub(crate) struct Writer<'a>(pub Cursor<&'a mut [u8]>);

impl<'a> Writer<'a> {
    pub(crate) fn new(output: &'a mut [u8]) -> Writer<'a> {
        Self(Cursor::new(output))
    }

    pub fn len(&self) -> usize {
        self.0.position() as usize
    }

    pub fn available(&self) -> usize {
        self.0.get_ref().len() - self.len()
    }

    pub(crate) fn try_write(&mut self, block: impl Fn(&mut Self) -> io::Result<()>) -> bool {
        let pos = self.0.position();
        let success = (block)(self).is_ok();
        if !success {
            self.0.set_position(pos);
        }
        success
    }
}

impl<'a> io::Write for Writer<'a> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

const CHARS_PER_ROW: usize = 16;

impl<'a> Drop for Writer<'a> {
    fn drop(&mut self) {
        let len = self.len();
        log_data(&self.0.get_ref()[..len]);
    }
}

pub(crate) fn log_data(data: &[u8]) {
    for row in data.chunks(CHARS_PER_ROW) {
        trace!("{:?}", Row(row))
    }
}

struct Row<'a>(&'a [u8]);

impl<'a> fmt::Debug for Row<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for i in 0..CHARS_PER_ROW {
            if let Some(v) = self.0.get(i) {
                write!(f, "{}", HEX[*v as usize])?
            } else {
                write!(f, "--")?;
            }
            if i % 2 == 1 {
                write!(f, " ")?;
            }
        }
        write!(f, " ")?;
        for i in 0..CHARS_PER_ROW {
            if let Some(v) = self.0.get(i) {
                if v.is_ascii_alphanumeric() || v.is_ascii_punctuation() {
                    write!(f, "{}", *v as char)?;
                } else {
                    write!(f, ".")?;
                }
            } else {
                write!(f, ".")?;
            }
        }
        Ok(())
    }
}

const HEX: [&str; 256] = [
    "00", "01", "02", "03", "04", "05", "06", "07", "08", "09", "0a", "0b", "0c", "0d", "0e", "0f",
    "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "1a", "1b", "1c", "1d", "1e", "1f",
    "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "2a", "2b", "2c", "2d", "2e", "2f",
    "30", "31", "32", "33", "34", "35", "36", "37", "38", "39", "3a", "3b", "3c", "3d", "3e", "3f",
    "40", "41", "42", "43", "44", "45", "46", "47", "48", "49", "4a", "4b", "4c", "4d", "4e", "4f",
    "50", "51", "52", "53", "54", "55", "56", "57", "58", "59", "5a", "5b", "5c", "5d", "5e", "5f",
    "60", "61", "62", "63", "64", "65", "66", "67", "68", "69", "6a", "6b", "6c", "6d", "6e", "6f",
    "70", "71", "72", "73", "74", "75", "76", "77", "78", "79", "7a", "7b", "7c", "7d", "7e", "7f",
    "80", "81", "82", "83", "84", "85", "86", "87", "88", "89", "8a", "8b", "8c", "8d", "8e", "8f",
    "90", "91", "92", "93", "94", "95", "96", "97", "98", "99", "9a", "9b", "9c", "9d", "9e", "9f",
    "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "aa", "ab", "ac", "ad", "ae", "af",
    "b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "b9", "ba", "bb", "bc", "bd", "be", "bf",
    "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "ca", "cb", "cc", "cd", "ce", "cf",
    "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "da", "db", "dc", "dd", "de", "df",
    "e0", "e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8", "e9", "ea", "eb", "ec", "ed", "ee", "ef",
    "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "fa", "fb", "fc", "fd", "fe", "ff",
];

/// Simple impl of an array behaving like a vec.
pub struct ArrayVec<T, const N: usize> {
    len: usize,
    arr: [T; N],
}

impl<T, const N: usize> Deref for ArrayVec<T, N> {
    type Target = [T];

    fn deref(&self) -> &Self::Target {
        &self.arr[..self.len]
    }
}

impl<T, const N: usize> DerefMut for ArrayVec<T, N> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.arr[..self.len]
    }
}

impl<T, const N: usize> ArrayVec<T, N> {
    /// Construct the array.
    ///
    /// The function must produces placeholder elements of the type `T`.
    pub fn from_fn(cb: impl FnMut(usize) -> T) -> Self {
        Self {
            len: 0,
            arr: std::array::from_fn(cb),
        }
    }

    /// Add a value T.
    pub fn push(&mut self, value: T) {
        self.arr[self.len] = value;
        self.len += 1;
    }

    /// Shorten the vec.
    ///
    /// This does not drop the elements that are now unused.
    pub fn truncate(&mut self, len: usize) {
        assert!(len <= self.len);
        self.len = len;
    }
}

impl<T, const N: usize> fmt::Debug for ArrayVec<T, N>
where
    T: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ArrayVec")
            .field("len", &self.len)
            .field("arr", &&self.arr[..self.len])
            .finish()
    }
}

impl<'a, T, const N: usize> IntoIterator for &'a ArrayVec<T, N> {
    type Item = &'a T;
    type IntoIter = core::slice::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self[..self.len].iter()
    }
}
