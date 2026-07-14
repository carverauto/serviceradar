use asn1_rs::Oid;

/// X509v3 Inhibit Any-policy
#[deprecated(since = "0.8.1", note = "please use OID_X509_EXT_INHIBIT_ANY_POLICY instead")]
pub const OID_X509_EXT_INHIBITANT_ANY_POLICY: Oid = crate::OID_X509_EXT_INHIBIT_ANY_POLICY;
