//! OIDs from RFC 3394 and RFC 5649
use const_oid::{AssociatedOid, ObjectIdentifier};

impl AssociatedOid for super::KwAes128 {
    const OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.5");
}

impl AssociatedOid for super::KwAes192 {
    const OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.25");
}

impl AssociatedOid for super::KwAes256 {
    const OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.45");
}

impl AssociatedOid for super::KwpAes128 {
    const OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.8");
}

impl AssociatedOid for super::KwpAes192 {
    const OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.28");
}

impl AssociatedOid for super::KwpAes256 {
    const OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.48");
}
