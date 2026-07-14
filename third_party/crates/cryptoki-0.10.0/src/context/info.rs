// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! PKCS11 library information

use crate::error::{Error, Result};
use crate::string_from_blank_padded;
use crate::types::Version;
use cryptoki_sys::*;
use std::convert::TryFrom;

#[derive(Debug, Clone)]
/// General information about the Cryptoki (PKCS#11 library)
pub struct Info {
    cryptoki_version: Version,
    manufacturer_id: String,
    // flags
    library_description: String,
    library_version: Version,
}

impl Info {
    /// Returns the version of Cryptoki interface for compatibility with future
    /// revisions
    pub fn cryptoki_version(&self) -> Version {
        self.cryptoki_version
    }

    /// ID of the Cryptoki library manufacturer
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 32 bytes (*not* chars) as UTF-8
    pub fn manufacturer_id(&self) -> &str {
        &self.manufacturer_id
    }

    /// Description of the library
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 32 bytes (*not* chars) as UTF-8
    pub fn library_description(&self) -> &str {
        &self.library_description
    }

    /// Cryptoki library version number
    pub fn library_version(&self) -> Version {
        self.library_version
    }
}

#[doc(hidden)]
impl TryFrom<CK_INFO> for Info {
    type Error = Error;
    fn try_from(val: CK_INFO) -> Result<Self> {
        if val.flags != 0 {
            return Err(Error::InvalidValue);
        }
        Ok(Self {
            cryptoki_version: val.cryptokiVersion.into(),
            manufacturer_id: string_from_blank_padded(&val.manufacturerID),
            library_description: string_from_blank_padded(&val.libraryDescription),
            library_version: val.libraryVersion.into(),
        })
    }
}
