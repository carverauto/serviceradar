use std::ops::Range;

/// Key-Value container that uses DNS `TXT` RDATA as representation
///
/// The binary representation can be used as RDATA for `DNS-SD TXT
/// Records` (see [RFC 6763, section 6]).
///
/// Each entry results in one string in the `TXT` represenation; `TXT`
/// RDATA contains many (but at least one) possibly empty strings, each
/// up to 255 bytes.
///
/// Key and value are separated by the first `=` in an entry, and the
/// key must consist of printable ASCII characters (0x20...0x7E) apart
/// from `=`.  Keys should be 9 characters or fewer.
///
/// Values can be any binary string (but the total length of an entry
/// cannot exceed 255 bytes).
///
/// An entry also can have no value at all (which is different from
/// having an empty value) if there is no `=` separator in the entry.
///
/// [RFC 6763, section 6]: https://tools.ietf.org/html/rfc6763#section-6
///     "RFC 6763, 6. Data Syntax for DNS-SD TXT Records"
#[derive(Clone)]
pub struct TxtRecord(Vec<u8>);

impl TxtRecord {
	/// Constructs a new, empty `TxtRecord`.
	pub fn new() -> Self {
		Self(Vec::new())
	}

	/// Parse binary blob as TXT RDATA
	///
	/// Same as [`parse`] but takes ownership of buffer.
	///
	/// [`parse`]: #method.parse
	pub fn parse_vec(data: Vec<u8>) -> Option<Self> {
		if data.len() == 1 && data[0] == 0 {
			let mut data = data;
			data.clear();
			return Some(Self(data));
		}
		let mut pos = 0;
		while pos < data.len() {
			let len = data[pos] as usize;
			let new_pos = pos + 1 + len;
			if new_pos > data.len() {
				return None;
			}
			pos = new_pos;
		}
		Some(Self(data))
	}

	/// Parse some binary blob as TXT RDATA
	///
	/// A single empty string (encoded as `0x00`) gets decoded as "empty" `TxtRecord` (i.e. the
	/// reverse th `rdata()`); an empty slice is treated the same, although it wouldn't be valid
	/// RDATA.
	///
	/// This only fails when the length of a chunk exceeds the remaining data.
	pub fn parse(data: &[u8]) -> Option<Self> {
		Self::parse_vec(data.into())
	}

	/// Constructs a new, empty `TxtRecord` with the specified capacity.
	///
	/// The inserting operations will still reallocate if necessary.
	pub fn with_capacity(capacity: usize) -> Self {
		Self(Vec::with_capacity(capacity))
	}

	/// Reserves capacity for at least `additional` more bytes to be
	/// used by inserting operations.
	///
	/// Each entry requires 1 byte for the total length, the length
	/// of the key for the key; if there is a value 1 byte for the
	/// separator `=` and the length of the value for the value.
	pub fn reserve(&mut self, additional: usize) {
		self.0.reserve(additional);
	}

	/// Returns `true` if the `TxtRecord` contains no elements (both in
	/// bytes and key-value entries).
	pub fn is_empty(&self) -> bool {
		self.0.is_empty()
	}

	/// Clears the `TxtRecord`, removing all entries.
	pub fn clear(&mut self) {
		self.0.clear();
	}

	/// if not empty this returns valid TXT RDATA, otherwise just an
	/// empty slice.
	pub fn data(&self) -> &[u8] {
		&self.0
	}

	/// always returns valid TXT RDATA; when the container is empty it
	/// will return a TXT record with a single empty string (i.e.
	/// `&[0x00]`).
	pub fn rdata(&self) -> &[u8] {
		if self.0.is_empty() {
			&[0x00] // empty RDATA not allowed, use single empty chunk instead
		} else {
			&self.0
		}
	}

	fn _position_keys(&self) -> PositionKeyIter<'_> {
		PositionKeyIter {
			pos: 0,
			data: &self.0,
		}
	}

	/// Iterate over all `(key, value)` pairs.
	pub fn iter(&self) -> TxtRecordIter<'_> {
		TxtRecordIter {
			pos: 0,
			data: &self.0,
		}
	}

	/// Get value for entry with given key
	///
	/// Returns `None` if there is no such entry, `Some(None)` if the
	/// entry exists but has no value, and `Some(Some(value))` if the
	/// entry exists and has a value.
	#[allow(clippy::option_option)]
	pub fn get(&self, key: &[u8]) -> Option<Option<&[u8]>> {
		self.iter().find(|&(k, _)| key == k).map(|(_, value)| value)
	}

	/// Remove entry with given key (if it exists)
	pub fn remove(&mut self, key: &[u8]) {
		if let Some((loc, _)) = self._position_keys().find(|&(_, k)| key == k) {
			self.0.drain(loc);
		}
	}

	/// Insert or update the entry with `key` to have the given value or on value
	pub fn set(&mut self, key: &[u8], value: Option<&[u8]>) -> Result<(), TxtRecordError> {
		for &k in key {
			if k == b'=' || !(0x20..=0x7e).contains(&k) {
				return Err(TxtRecordError::InvalidKey);
			}
		}
		let entry_len = key.len() + value.map(|v| v.len() + 1).unwrap_or(0);
		if entry_len > 255 {
			return Err(TxtRecordError::EntryTooLong);
		}
		self.remove(key);

		self.0.push(entry_len as u8);
		self.0.extend_from_slice(key);
		if let Some(value) = value {
			self.0.push(b'=');
			self.0.extend_from_slice(value);
		}

		Ok(())
	}

	/// Insert or update the entry with `key` to have no value
	pub fn set_no_value(&mut self, key: &[u8]) -> Result<(), TxtRecordError> {
		self.set(key, None)
	}

	/// Insert or update the entry with `key` to have the given value
	pub fn set_value(&mut self, key: &[u8], value: &[u8]) -> Result<(), TxtRecordError> {
		self.set(key, Some(value))
	}
}

impl Default for TxtRecord {
	fn default() -> Self {
		Self::new()
	}
}

impl<'a> IntoIterator for &'a TxtRecord {
	type IntoIter = TxtRecordIter<'a>;
	type Item = (&'a [u8], Option<&'a [u8]>);

	fn into_iter(self) -> Self::IntoIter {
		self.iter()
	}
}

/// Error returned when inserting new entries failed
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum TxtRecordError {
	/// Key contained invalid characters
	InvalidKey,
	/// Total entry would be longer than 255 bytes
	EntryTooLong,
}

struct PositionKeyIter<'a> {
	pos: usize,
	data: &'a [u8],
}

impl<'a> Iterator for PositionKeyIter<'a> {
	// (start..end, key)
	type Item = (Range<usize>, &'a [u8]);

	fn next(&mut self) -> Option<Self::Item> {
		if self.data.is_empty() {
			return None;
		}
		let len = self.data[0] as usize;
		let entry_pos = self.pos;
		let entry = &self.data[1..][..len];
		self.data = &self.data[len + 1..];
		self.pos += len + 1;

		Some(match entry.iter().position(|&b| b == b'=') {
			Some(pos) => (entry_pos..self.pos, &entry[..pos]),
			None => (entry_pos..self.pos, entry),
		})
	}
}

/// Iterator for entries in `TxtRecord`
///
/// Items are `(key, value)` pairs.
pub struct TxtRecordIter<'a> {
	pos: usize,
	data: &'a [u8],
}

impl<'a> Iterator for TxtRecordIter<'a> {
	// key, value
	type Item = (&'a [u8], Option<&'a [u8]>);

	fn next(&mut self) -> Option<Self::Item> {
		if self.data.is_empty() {
			return None;
		}
		let len = self.data[0] as usize;
		let entry = &self.data[1..][..len];
		self.data = &self.data[len + 1..];
		self.pos += len + 1;

		Some(match entry.iter().position(|&b| b == b'=') {
			Some(pos) => (&entry[..pos], Some(&entry[pos + 1..])),
			None => (entry, None),
		})
	}
}

#[cfg(test)]
mod tests {
	use super::TxtRecord;

	#[test]
	fn modifications() {
		let mut r = TxtRecord::new();
		assert!(r.is_empty());
		assert_eq!(r.data(), b"");
		assert_eq!(r.rdata(), b"\x00");

		r.set(b"foo", Some(b"bar")).unwrap();
		assert!(!r.is_empty());
		assert_eq!(r.data(), b"\x07foo=bar");
		assert_eq!(r.rdata(), b"\x07foo=bar");

		r.set(b"u", Some(b"vw")).unwrap();
		assert!(!r.is_empty());
		assert_eq!(r.data(), b"\x07foo=bar\x04u=vw");
		assert_eq!(r.rdata(), b"\x07foo=bar\x04u=vw");
		assert_eq!(
			r.iter().collect::<Vec<_>>(),
			vec![
				(b"foo" as &[u8], Some(b"bar" as &[u8])),
				(b"u", Some(b"vw")),
			]
		);

		r.set(b"foo", None).unwrap();
		assert!(!r.is_empty());
		assert_eq!(r.data(), b"\x04u=vw\x03foo");
		assert_eq!(r.rdata(), b"\x04u=vw\x03foo");
		assert_eq!(
			r.iter().collect::<Vec<_>>(),
			vec![(b"u" as &[u8], Some(b"vw" as &[u8])), (b"foo", None),]
		);

		r.set(b"foo", Some(b"bar")).unwrap();
		assert!(!r.is_empty());
		assert_eq!(r.data(), b"\x04u=vw\x07foo=bar");
		assert_eq!(r.rdata(), b"\x04u=vw\x07foo=bar");

		r.remove(b"foo");
		assert!(!r.is_empty());
		assert_eq!(r.data(), b"\x04u=vw");
		assert_eq!(r.rdata(), b"\x04u=vw");
	}
}
