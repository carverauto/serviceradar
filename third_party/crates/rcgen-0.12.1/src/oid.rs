/// pkcs-9-at-extensionRequest in [RFC 2985](https://www.rfc-editor.org/rfc/rfc2985#appendix-A)
pub const OID_PKCS_9_AT_EXTENSION_REQUEST: &[u64] = &[1, 2, 840, 113549, 1, 9, 14];

/// id-at-countryName in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_COUNTRY_NAME: &[u64] = &[2, 5, 4, 6];
/// id-at-localityName in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_LOCALITY_NAME: &[u64] = &[2, 5, 4, 7];
/// id-at-stateOrProvinceName in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_STATE_OR_PROVINCE_NAME: &[u64] = &[2, 5, 4, 8];
/// id-at-organizationName in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_ORG_NAME: &[u64] = &[2, 5, 4, 10];
/// id-at-organizationalUnitName in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_ORG_UNIT_NAME: &[u64] = &[2, 5, 4, 11];
/// id-at-commonName in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_COMMON_NAME: &[u64] = &[2, 5, 4, 3];

/// id-ecPublicKey in [RFC 5480](https://datatracker.ietf.org/doc/html/rfc5480#appendix-A)
pub const OID_EC_PUBLIC_KEY: &[u64] = &[1, 2, 840, 10045, 2, 1];
/// secp256r1 in [RFC 5480](https://datatracker.ietf.org/doc/html/rfc5480#appendix-A)
pub const OID_EC_SECP_256_R1: &[u64] = &[1, 2, 840, 10045, 3, 1, 7];
/// secp384r1 in [RFC 5480](https://datatracker.ietf.org/doc/html/rfc5480#appendix-A)
pub const OID_EC_SECP_384_R1: &[u64] = &[1, 3, 132, 0, 34];

/// rsaEncryption in [RFC 4055](https://www.rfc-editor.org/rfc/rfc4055#section-6)
pub const OID_RSA_ENCRYPTION: &[u64] = &[1, 2, 840, 113549, 1, 1, 1];

/// id-RSASSA-PSS in [RFC 4055](https://www.rfc-editor.org/rfc/rfc4055#section-6)
pub const OID_RSASSA_PSS: &[u64] = &[1, 2, 840, 113549, 1, 1, 10];

/// id-ce-keyUsage in [RFC 5280](https://tools.ietf.org/html/rfc5280#appendix-A.2)
pub const OID_KEY_USAGE: &[u64] = &[2, 5, 29, 15];

/// id-ce-subjectAltName in [RFC 5280](https://tools.ietf.org/html/rfc5280#appendix-A.2)
pub const OID_SUBJECT_ALT_NAME: &[u64] = &[2, 5, 29, 17];

/// id-ce-basicConstraints in [RFC 5280](https://tools.ietf.org/html/rfc5280#appendix-A.2)
pub const OID_BASIC_CONSTRAINTS: &[u64] = &[2, 5, 29, 19];

/// id-ce-subjectKeyIdentifier in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_SUBJECT_KEY_IDENTIFIER: &[u64] = &[2, 5, 29, 14];

/// id-ce-authorityKeyIdentifier in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_AUTHORITY_KEY_IDENTIFIER: &[u64] = &[2, 5, 29, 35];

/// id-ce-extKeyUsage in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_EXT_KEY_USAGE: &[u64] = &[2, 5, 29, 37];

/// id-ce-nameConstraints in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_NAME_CONSTRAINTS: &[u64] = &[2, 5, 29, 30];

/// id-ce-cRLDistributionPoints in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_CRL_DISTRIBUTION_POINTS: &[u64] = &[2, 5, 29, 31];

/// id-pe-acmeIdentifier in
/// [IANA SMI Numbers registry](https://www.iana.org/assignments/smi-numbers/smi-numbers.xhtml#smi-numbers-1.3.6.1.5.5.7.1)
pub const OID_PE_ACME: &[u64] = &[1, 3, 6, 1, 5, 5, 7, 1, 31];

/// id-ce-cRLNumber in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_CRL_NUMBER: &[u64] = &[2, 5, 29, 20];

/// id-ce-cRLReasons in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_CRL_REASONS: &[u64] = &[2, 5, 29, 21];

/// id-ce-invalidityDate in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_CRL_INVALIDITY_DATE: &[u64] = &[2, 5, 29, 24];

/// id-ce-issuingDistributionPoint in [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280#appendix-A)
pub const OID_CRL_ISSUING_DISTRIBUTION_POINT: &[u64] = &[2, 5, 29, 28];
