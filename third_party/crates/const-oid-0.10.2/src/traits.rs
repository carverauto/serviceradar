//! Trait definitions.

use crate::ObjectIdentifier;

/// A trait which associates an OID with a type.
pub trait AssociatedOid {
    /// The OID associated with this type.
    const OID: ObjectIdentifier;
}

/// A trait which associates a dynamic, `&self`-dependent OID with a type,
/// which may change depending on the type's value.
///
/// This trait is object safe and auto-impl'd for any types which impl
/// [`AssociatedOid`].
pub trait DynAssociatedOid {
    /// Get the OID associated with this value.
    fn oid(&self) -> ObjectIdentifier;
}

impl<T: AssociatedOid> DynAssociatedOid for T {
    fn oid(&self) -> ObjectIdentifier {
        T::OID
    }
}
