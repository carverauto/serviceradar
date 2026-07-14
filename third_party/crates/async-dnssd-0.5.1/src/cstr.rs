use std::{
	borrow::Cow,
	ffi,
	io,
	os::raw::c_char,
	ptr::null,
};

pub unsafe fn from_cstr(s: *const c_char) -> io::Result<&'static str> {
	ffi::CStr::from_ptr(s)
		.to_str()
		.map_err(|e| io::Error::new(io::ErrorKind::Other, e))
}

#[derive(Clone, Debug)]
pub struct CStr<'a>(Cow<'a, ffi::CStr>);

impl<'a> CStr<'a> {
	pub fn from<T>(s: &'a T) -> Result<Self, ffi::NulError>
	where
		Self: CStrFrom<'a, T>,
	{
		CStrFrom::cstr_from(s)
	}

	pub fn as_ptr(&self) -> *const c_char {
		self.0.as_ptr()
	}
}

#[derive(Clone, Debug)]
pub struct NullableCStr<'a>(Option<Cow<'a, ffi::CStr>>);

impl<'a> NullableCStr<'a> {
	pub fn from<T>(s: &'a T) -> Result<Self, ffi::NulError>
	where
		Self: CStrFrom<'a, T>,
	{
		CStrFrom::cstr_from(s)
	}

	pub fn as_ptr(&self) -> *const c_char {
		match self.0 {
			Some(ref s) => s.as_ptr(),
			None => null(),
		}
	}
}

pub trait CStrFrom<'a, T>: Sized {
	fn cstr_from(_: &'a T) -> Result<Self, ffi::NulError>;
}

impl<'a, T: AsRef<str>> CStrFrom<'a, T> for CStr<'a> {
	fn cstr_from(s: &'a T) -> Result<Self, ffi::NulError> {
		Ok(Self(Cow::Owned(ffi::CString::new(s.as_ref())?)))
	}
}

impl<'a, T: AsRef<str>> CStrFrom<'a, Option<T>> for NullableCStr<'a> {
	fn cstr_from(s: &'a Option<T>) -> Result<Self, ffi::NulError> {
		match *s {
			Some(ref s) => Ok(Self(Some(Cow::Owned(ffi::CString::new(s.as_ref())?)))),
			None => Ok(Self(None)),
		}
	}
}
