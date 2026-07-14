// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Object management functions

use crate::context::Function;
use crate::error::{Error, Result, Rv, RvError};
use crate::object::{Attribute, AttributeInfo, AttributeType, ObjectHandle};
use crate::session::Session;
use cryptoki_sys::*;
use std::collections::HashMap;
use std::convert::TryInto;
use std::num::NonZeroUsize;

// Search 10 elements at a time
// Safety: the value provided (10) must be non-zero
const MAX_OBJECT_COUNT: NonZeroUsize = unsafe { NonZeroUsize::new_unchecked(10) };

/// Iterator over object handles, in an active session.
///
/// Used to iterate over the object handles returned by underlying calls to `C_FindObjects`.
/// The iterator is created by calling the `iter_objects` and `iter_objects_with_cache_size` methods on a `Session` object.
///
/// # Note
///
/// The iterator `new()` method will call `C_FindObjectsInit`. It means that until the iterator is dropped,
/// creating another iterator will result in an error (typically `RvError::OperationActive` ).
///
/// # Example
///
/// ```no_run
/// use cryptoki::context::CInitializeArgs;
/// use cryptoki::context::Pkcs11;
/// use cryptoki::error::Error;
/// use cryptoki::object::Attribute;
/// use cryptoki::object::AttributeType;
/// use cryptoki::session::UserType;
/// use cryptoki::types::AuthPin;
/// use std::env;
///
/// # fn main() -> testresult::TestResult {
/// # let pkcs11 = Pkcs11::new(
/// #    env::var("TEST_PKCS11_MODULE")
/// #        .unwrap_or_else(|_| "/usr/local/lib/libsofthsm2.so".to_string()),
/// # )?;
/// #
/// # pkcs11.initialize(CInitializeArgs::OsThreads)?;
/// # let slot = pkcs11.get_slots_with_token()?.remove(0);
/// #
/// # let session = pkcs11.open_ro_session(slot).unwrap();
/// # session.login(UserType::User, Some(&AuthPin::new("fedcba".into())))?;
///
/// let token_object = vec![Attribute::Token(true)];
/// let wanted_attr = vec![AttributeType::Label];
///
/// for (idx, obj) in session.iter_objects(&token_object)?.enumerate() {
///     let obj = obj?; // handle potential error condition
///
///     let attributes = session.get_attributes(obj, &wanted_attr)?;
///
///     match attributes.first() {
///         Some(Attribute::Label(l)) => {
///             println!(
///                 "token object #{}: handle {}, label {}",
///                 idx,
///                 obj,
///                 String::from_utf8(l.to_vec())
///                     .unwrap_or_else(|_| "*** not valid utf8 ***".to_string())
///             );
///         }
///         _ => {
///             println!("token object #{}: handle {}, label not found", idx, obj);
///         }
///     }
/// }
/// # Ok(())
/// # }
///
/// ```
#[derive(Debug)]
pub struct ObjectHandleIterator<'a> {
    session: &'a Session,
    object_count: usize,
    index: usize,
    cache: Vec<CK_OBJECT_HANDLE>,
}

impl<'a> ObjectHandleIterator<'a> {
    /// Create a new iterator over object handles.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to iterate over
    /// * `template` - The template to match objects against
    /// * `cache_size` - The number of objects to cache (type is [`NonZeroUsize`])
    ///
    /// # Returns
    ///
    /// This function will return a [`Result<ObjectHandleIterator>`] that can be used to iterate over the objects
    /// matching the template. The cache size corresponds to the size of the array provided to `C_FindObjects()`.
    ///
    /// # Errors
    ///
    /// This function will return an error if the call to `C_FindObjectsInit` fails.
    ///
    /// # Note
    ///
    /// The iterator `new()` method will call `C_FindObjectsInit`. It means that until the iterator is dropped,
    /// creating another iterator will result in an error (typically `RvError::OperationActive` ).
    ///
    fn new(
        session: &'a Session,
        mut template: Vec<CK_ATTRIBUTE>,
        cache_size: NonZeroUsize,
    ) -> Result<Self> {
        unsafe {
            Rv::from(get_pkcs11!(session.client(), C_FindObjectsInit)(
                session.handle(),
                template.as_mut_ptr(),
                template.len().try_into()?,
            ))
            .into_result(Function::FindObjectsInit)?;
        }

        let cache: Vec<CK_OBJECT_HANDLE> = vec![0; cache_size.get()];
        Ok(ObjectHandleIterator {
            session,
            object_count: cache_size.get(),
            index: cache_size.get(),
            cache,
        })
    }
}

// In this implementation, we use object_count to keep track of the number of objects
// returned by the last C_FindObjects call; the index is used to keep track of
// the next object in the cache to be returned. The size of cache is never changed.
// In order to enter the loop for the first time, we set object_count to cache_size
// and index to cache_size. That allows to jump directly to the C_FindObjects call
// and start filling the cache.

impl Iterator for ObjectHandleIterator<'_> {
    type Item = Result<ObjectHandle>;

    fn next(&mut self) -> Option<Self::Item> {
        // since the iterator is initialized with object_count and index both equal and > 0,
        // we are guaranteed to enter the loop at least once
        while self.object_count > 0 {
            // if index<object_count, we have items in the cache to return
            if self.index < self.object_count {
                self.index += 1;
                return Some(Ok(ObjectHandle::new(self.cache[self.index - 1])));
            } else {
                // reset counters and proceed to the next section
                self.index = 0;

                if self.object_count < self.cache.len() {
                    // if self.object_count is less than the cache size,
                    // it means our last call to C_FindObjects returned less than the cache size
                    // At this point, we have exhausted all objects in the cache
                    // and we can safely break the loop and return None
                    self.object_count = 0;
                    break;
                } else {
                    // reset the counter - C_FindObjects will adjust that value.
                    self.object_count = 0;
                }
            }

            let p11rv = match get_pkcs11_func!(self.session.client(), C_FindObjects) {
                Some(f) => unsafe {
                    f(
                        self.session.handle(),
                        self.cache.as_mut_ptr(),
                        self.cache.len() as CK_ULONG,
                        &mut self.object_count as *mut usize as CK_ULONG_PTR,
                    )
                },
                None => {
                    // C_FindObjects() is not implemented,, bark and return an error
                    log::error!("C_FindObjects() is not implemented on this library");
                    return Some(Err(Error::NullFunctionPointer) as Result<ObjectHandle>);
                }
            };

            if let Rv::Error(error) = Rv::from(p11rv) {
                return Some(
                    Err(Error::Pkcs11(error, Function::FindObjects)) as Result<ObjectHandle>
                );
            }
        }
        None
    }
}

impl Drop for ObjectHandleIterator<'_> {
    fn drop(&mut self) {
        if let Some(f) = get_pkcs11_func!(self.session.client(), C_FindObjectsFinal) {
            // swallow the return value, as we can't do anything about it,
            // but log the error
            if let Rv::Error(error) = Rv::from(unsafe { f(self.session.handle()) }) {
                log::error!("C_FindObjectsFinal() failed with error: {:?}", error);
            }
        } else {
            // bark but pass if C_FindObjectsFinal() is not implemented
            log::error!("C_FindObjectsFinal() is not implemented on this library");
        }
    }
}

impl Session {
    /// Iterate over session objects matching a template.
    ///
    /// # Arguments
    ///
    /// * `template` - The template to match objects against
    ///
    /// # Returns
    ///
    /// This function will return a [`Result<ObjectHandleIterator>`] that can be used to iterate over the objects
    /// matching the template. Note that the cache size is managed internally and set to a default value (10)
    ///
    /// # See also
    ///
    /// * [`ObjectHandleIterator`] for more information on how to use the iterator
    /// * [`Session::iter_objects_with_cache_size`] for a way to specify the cache size
    #[inline(always)]
    pub fn iter_objects(&self, template: &[Attribute]) -> Result<ObjectHandleIterator> {
        self.iter_objects_with_cache_size(template, MAX_OBJECT_COUNT)
    }

    /// Iterate over session objects matching a template, with cache size
    ///
    /// # Arguments
    ///
    /// * `template` - The template to match objects against
    /// * `cache_size` - The number of objects to cache (type is [`NonZeroUsize`])
    ///
    /// # Returns
    ///
    /// This function will return a [`Result<ObjectHandleIterator>`] that can be used to iterate over the objects
    /// matching the template. The cache size corresponds to the size of the array provided to `C_FindObjects()`.
    ///
    /// # See also
    ///
    /// * [`ObjectHandleIterator`] for more information on how to use the iterator
    /// * [`Session::iter_objects`] for a simpler way to iterate over objects
    pub fn iter_objects_with_cache_size(
        &self,
        template: &[Attribute],
        cache_size: NonZeroUsize,
    ) -> Result<ObjectHandleIterator> {
        let template: Vec<CK_ATTRIBUTE> = template.iter().map(Into::into).collect();
        ObjectHandleIterator::new(self, template, cache_size)
    }

    /// Search for session objects matching a template
    ///
    /// # Arguments
    ///
    /// * `template` - A reference to [Attribute] of search parameters that will be used
    ///   to find objects.
    ///
    /// # Returns
    ///
    /// Upon success, a vector of [`ObjectHandle`] wrapped in a Result.
    /// Upon failure, the first error encountered.
    ///
    /// # Note
    ///
    /// It is a convenience method that will call [`Session::iter_objects`] and collect the results.
    ///
    /// # See also
    ///
    /// * [`Session::iter_objects`] for a way to specify the cache size
    ///
    /// # Example
    ///
    /// ```rust
    /// # fn main() -> testresult::TestResult {
    /// # use cryptoki::session::Session;
    /// # use cryptoki::context::Pkcs11;
    /// # use cryptoki::object::{Attribute, AttributeType, CertificateType, ObjectClass, ObjectHandle};
    /// #
    /// # let mut client = Pkcs11::new(
    /// #    std::env::var("TEST_PKCS11_MODULE")
    /// #       .unwrap_or_else(|_| "/usr/local/lib/softhsm/libsofthsm2.so".to_string()),
    /// # )?;
    /// # client.initialize(cryptoki::context::CInitializeArgs::OsThreads)?;
    /// #
    /// # // Use the first slot
    /// # let slot = client.get_all_slots()?[0];
    /// # let session = client.open_ro_session(slot)?;
    /// #
    /// // Get handles to all of the x509 certificates on the card
    /// let search = vec![Attribute::Class(ObjectClass::CERTIFICATE), Attribute::CertificateType(CertificateType::X_509)];
    /// for handle in session.find_objects(&search)? {
    ///     // each cert: get the "value" which will be the raw certificate data
    ///     for value in session.get_attributes(handle, &[AttributeType::Value])? {
    ///        if let Attribute::Value(value) = value {
    ///            println!("Certificate value: {value:?}");
    ///        }
    ///     }
    /// }
    /// # Ok(()) }
    /// ```
    ///
    #[inline(always)]
    pub fn find_objects(&self, template: &[Attribute]) -> Result<Vec<ObjectHandle>> {
        self.iter_objects(template)?.collect()
    }

    /// Create a new object
    pub fn create_object(&self, template: &[Attribute]) -> Result<ObjectHandle> {
        let mut template: Vec<CK_ATTRIBUTE> = template.iter().map(|attr| attr.into()).collect();
        let mut object_handle = 0;

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_CreateObject)(
                self.handle(),
                template.as_mut_ptr(),
                template.len().try_into()?,
                &mut object_handle as CK_OBJECT_HANDLE_PTR,
            ))
            .into_result(Function::CreateObject)?;
        }

        Ok(ObjectHandle::new(object_handle))
    }

    /// Destroy an object
    pub fn destroy_object(&self, object: ObjectHandle) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DestroyObject)(
                self.handle(),
                object.handle(),
            ))
            .into_result(Function::DestroyObject)
        }
    }

    /// Copy an object
    ///
    /// A template can be provided to change some attributes of the new object, when allowed.
    ///
    /// # Arguments
    ///
    /// * `object` - The [ObjectHandle] used to reference the object to copy
    /// * `template` - new values for any attributes of the object that can ordinarily be modified
    ///   check out [PKCS#11 documentation](https://docs.oasis-open.org/pkcs11/pkcs11-spec/v3.1/cs01/pkcs11-spec-v3.1-cs01.html#_Toc111203284) for details
    ///
    /// # Returns
    ///
    /// This function will return a new [ObjectHandle] that references the newly created object.
    ///
    pub fn copy_object(
        &self,
        object: ObjectHandle,
        template: &[Attribute],
    ) -> Result<ObjectHandle> {
        let mut template: Vec<CK_ATTRIBUTE> = template.iter().map(|attr| attr.into()).collect();
        let mut object_handle = 0;

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_CopyObject)(
                self.handle(),
                object.handle(),
                template.as_mut_ptr(),
                template.len().try_into()?,
                &mut object_handle as CK_OBJECT_HANDLE_PTR,
            ))
            .into_result(Function::CopyObject)?;
        }

        Ok(ObjectHandle::new(object_handle))
    }

    /// Get the attribute info of an object: if the attribute is present and its size.
    ///
    /// # Arguments
    ///
    /// * `object` - The [ObjectHandle] used to reference the object
    /// * `attributes` - The list of attributes to get the information of
    ///
    /// # Returns
    ///
    /// This function will return a Vector of [AttributeInfo] enums that will either contain
    /// the size of the requested attribute, [AttributeInfo::TypeInvalid] if the attribute is not a
    /// valid type for the object, or [AttributeInfo::Sensitive] if the requested attribute is
    /// sensitive and will not be returned to the user.
    ///
    /// The list of returned attributes is 1-to-1 matched with the provided vector of attribute
    /// types.  If you wish, you may create a hash table simply by:
    ///
    /// ```no_run
    /// use cryptoki::context::Pkcs11;
    /// use cryptoki::context::CInitializeArgs;
    /// use cryptoki::object::AttributeType;
    /// use cryptoki::session::UserType;
    /// use cryptoki::types::AuthPin;
    /// use std::collections::HashMap;
    /// use std::env;
    ///
    /// let mut pkcs11 = Pkcs11::new(
    ///         env::var("TEST_PKCS11_MODULE")
    ///             .unwrap_or_else(|_| "/usr/local/lib/softhsm/libsofthsm2.so".to_string()),
    ///     )
    ///     .unwrap();
    ///
    /// pkcs11.initialize(CInitializeArgs::OsThreads).unwrap();
    /// let slot = pkcs11.get_slots_with_token().unwrap().remove(0);
    ///
    /// let session = pkcs11.open_ro_session(slot).unwrap();
    /// session.login(UserType::User, Some(&AuthPin::new("fedcba".into())));
    ///
    /// let empty_attrib= vec![];
    /// if let Some(object) = session.find_objects(&empty_attrib).unwrap().first() {
    ///     let attribute_types = vec![
    ///         AttributeType::Token,
    ///         AttributeType::Private,
    ///         AttributeType::Modulus,
    ///         AttributeType::KeyType,
    ///         AttributeType::Verify,];
    ///
    ///     let attribute_info = session.get_attribute_info(*object, &attribute_types).unwrap();
    ///
    ///     let hash = attribute_types
    ///         .iter()
    ///         .zip(attribute_info.iter())
    ///         .collect::<HashMap<_, _>>();
    /// }
    /// ```
    ///
    /// Alternatively, you can call [Session::get_attribute_info_map], found below.
    pub fn get_attribute_info(
        &self,
        object: ObjectHandle,
        attributes: &[AttributeType],
    ) -> Result<Vec<AttributeInfo>> {
        let mut results = Vec::new();

        for attrib in attributes.iter() {
            let mut template: Vec<CK_ATTRIBUTE> = vec![CK_ATTRIBUTE {
                type_: (*attrib).into(),
                pValue: std::ptr::null_mut(),
                ulValueLen: 0,
            }];

            match unsafe {
                Rv::from(get_pkcs11!(self.client(), C_GetAttributeValue)(
                    self.handle(),
                    object.handle(),
                    template.as_mut_ptr(),
                    template.len().try_into()?,
                ))
            } {
                Rv::Ok => {
                    if template[0].ulValueLen == CK_UNAVAILABLE_INFORMATION {
                        results.push(AttributeInfo::Unavailable)
                    } else {
                        results.push(AttributeInfo::Available(template[0].ulValueLen.try_into()?))
                    }
                }
                Rv::Error(RvError::AttributeSensitive) => results.push(AttributeInfo::Sensitive),
                Rv::Error(RvError::AttributeTypeInvalid) => {
                    results.push(AttributeInfo::TypeInvalid)
                }
                rv => rv.into_result(Function::GetAttributeValue)?,
            }
        }
        Ok(results)
    }

    /// Get the attribute info of an object: if the attribute is present and its size.
    ///
    /// # Arguments
    ///
    /// * `object` - The [ObjectHandle] used to reference the object
    /// * `attributes` - The list of attributes to get the information of
    ///
    /// # Returns
    ///
    /// This function will return a HashMap of [AttributeType] and [AttributeInfo] enums that will
    /// either contain the size of the requested attribute, [AttributeInfo::TypeInvalid] if the
    /// attribute is not a valid type for the object, or [AttributeInfo::Sensitive] if the requested
    /// attribute is sensitive and will not be returned to the user.
    pub fn get_attribute_info_map(
        &self,
        object: ObjectHandle,
        attributes: &[AttributeType],
    ) -> Result<HashMap<AttributeType, AttributeInfo>> {
        let attrib_info = self.get_attribute_info(object, attributes)?;

        Ok(attributes
            .iter()
            .cloned()
            .zip(attrib_info.iter().cloned())
            .collect::<HashMap<_, _>>())
    }

    /// Get the attributes values of an object.
    /// Ignore the unavailable one. One has to call the get_attribute_info method to check which
    /// ones are unavailable.
    pub fn get_attributes(
        &self,
        object: ObjectHandle,
        attributes: &[AttributeType],
    ) -> Result<Vec<Attribute>> {
        let attrs_info = self.get_attribute_info(object, attributes)?;

        // Allocating a chunk of memory where to put the attributes value.
        let attrs_memory: Vec<(AttributeType, Vec<u8>)> = attrs_info
            .iter()
            .zip(attributes.iter())
            .filter_map(|(attr_info, attr_type)| {
                if let AttributeInfo::Available(size) = attr_info {
                    Some((*attr_type, vec![0; *size]))
                } else {
                    None
                }
            })
            .collect();

        let mut template: Vec<CK_ATTRIBUTE> = attrs_memory
            .iter()
            .map(|(attr_type, memory)| {
                Ok(CK_ATTRIBUTE {
                    type_: (*attr_type).into(),
                    pValue: memory.as_ptr() as *mut std::ffi::c_void,
                    ulValueLen: memory.len().try_into()?,
                })
            })
            .collect::<Result<Vec<CK_ATTRIBUTE>>>()?;

        // This should only return OK as all attributes asked should be
        // available. Concurrency problem?
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_GetAttributeValue)(
                self.handle(),
                object.handle(),
                template.as_mut_ptr(),
                template.len().try_into()?,
            ))
            .into_result(Function::GetAttributeValue)?;
        }

        // Convert from CK_ATTRIBUTE to Attribute
        template.into_iter().map(|attr| attr.try_into()).collect()
    }

    /// Sets the attributes of an object
    pub fn update_attributes(&self, object: ObjectHandle, template: &[Attribute]) -> Result<()> {
        let mut template: Vec<CK_ATTRIBUTE> = template.iter().map(|attr| attr.into()).collect();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SetAttributeValue)(
                self.handle(),
                object.handle(),
                template.as_mut_ptr(),
                template.len().try_into()?,
            ))
            .into_result(Function::SetAttributeValue)?;
        }

        Ok(())
    }
}
