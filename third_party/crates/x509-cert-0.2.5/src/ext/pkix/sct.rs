//! Signed Certificate Timestamp list extension as defined in the
//! [Certificate Transparency RFC 6962].
//!
//! [Certificate Transparency RFC 6962]: https://datatracker.ietf.org/doc/html/rfc6962

#![cfg(feature = "sct")]

use alloc::{format, vec::Vec};
use const_oid::{AssociatedOid, ObjectIdentifier};
use der::asn1::OctetString;
use tls_codec::{
    DeserializeBytes, SerializeBytes, TlsByteVecU16, TlsDeserializeBytes, TlsSerializeBytes,
    TlsSize,
};

/// A signed certificate timestamp list (SCT list) as defined in [RFC 6962 Section 3.3].
///
/// ```text
/// SignedCertificateTimestampList ::= OCTET STRING
/// ```
///
/// [RFC 6962 Section 3.3]: https://datatracker.ietf.org/doc/html/rfc6962#section-3.3
#[derive(Debug, PartialEq)]
pub struct SignedCertificateTimestampList(OctetString);

//TODO: Remove this and use const-oid's rfc6962::CT_PRECERT_SCTS once a const-oid version
// containing it is published
const CT_PRECERT_SCTS: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.4.1.11129.2.4.2");

impl AssociatedOid for SignedCertificateTimestampList {
    const OID: ObjectIdentifier = CT_PRECERT_SCTS;
}

impl_newtype!(SignedCertificateTimestampList, OctetString);
impl_extension!(SignedCertificateTimestampList, critical = false);

/// Errors that are thrown by this module.
#[derive(PartialEq, Debug)]
pub enum Error {
    /// [Errors][der::Error] from the `der` crate.
    Der(der::Error),
    /// [Errors][tls_codec::Error] from the `tls_codec` crate.
    Tls(tls_codec::Error),
}

impl From<der::Error> for Error {
    fn from(value: der::Error) -> Self {
        Error::Der(value)
    }
}

impl From<tls_codec::Error> for Error {
    fn from(value: tls_codec::Error) -> Self {
        Error::Tls(value)
    }
}

impl SignedCertificateTimestampList {
    /// Creates a new [`SignedCertificateTimestampList`] from a slice of [`SerializedSct`]s.
    pub fn new(serialized_scts: &[SerializedSct]) -> Result<Self, Error> {
        let mut result: Vec<u8> = Vec::new();
        for timestamp in serialized_scts {
            let buffer = timestamp.tls_serialize()?;
            result.extend(buffer);
        }
        let tls_vec = TlsByteVecU16::new(result);
        let buffer = tls_vec.tls_serialize()?;
        Ok(SignedCertificateTimestampList(OctetString::new(buffer)?))
    }

    /// Parses the encoded [SerializedSct]s and returns a [Vec] containing them.
    ///
    /// Returns an [error][Error] if a [SerializedSct] can't be
    /// deserialized or if there are trailing bytes after all [SerializedSct]s
    /// are deserialized.
    pub fn parse_timestamps(&self) -> Result<Vec<SerializedSct>, Error> {
        let (tls_vec, rest) = TlsByteVecU16::tls_deserialize_bytes(self.0.as_bytes())?;
        if !rest.is_empty() {
            return Err(tls_codec::Error::TrailingData)?;
        }
        let mut bytes = tls_vec.as_slice();
        let mut result = Vec::new();
        while !bytes.is_empty() {
            let (serialized_sct, rest) = SerializedSct::tls_deserialize_bytes(bytes)?;
            result.push(serialized_sct);
            bytes = rest;
        }
        Ok(result)
    }
}

/// A byte string that contains a serialized [SignedCertificateTimestamp] as
/// defined in [RFC 6962 section 3.3].
///
/// [RFC 6962 section 3.3]: https://datatracker.ietf.org/doc/html/rfc6962#section-3.3
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
pub struct SerializedSct {
    data: TlsByteVecU16,
}

impl SerializedSct {
    /// Creates a new [SerializedSct] from a [SignedCertificateTimestamp].
    ///
    /// Returns [tls_codec Error][tls_codec::Error] if the given [SignedCertificateTimestamp]
    /// can't be serialized.
    pub fn new(timestamp: SignedCertificateTimestamp) -> Result<Self, tls_codec::Error> {
        let buffer = timestamp.tls_serialize()?;
        Ok(SerializedSct {
            data: TlsByteVecU16::from_slice(&buffer),
        })
    }

    /// Parses a [SignedCertificateTimestamp] from a this [SerializedSct].
    ///
    /// Returns an [error][Error] if a [SignedCertificateTimestamp] can't be
    /// deserialized or if there are trailing bytes after a
    /// [SignedCertificateTimestamp] has been deserialized.
    pub fn parse_timestamp(&self) -> Result<SignedCertificateTimestamp, Error> {
        let (sct, rest) = SignedCertificateTimestamp::tls_deserialize_bytes(self.data.as_slice())?;
        if !rest.is_empty() {
            return Err(tls_codec::Error::TrailingData)?;
        }
        Ok(sct)
    }
}

/// A signed certificate timestamp (SCT) as defined in [RFC 6962 section 3.2].
///
/// [RFC 6962 section 3.2]: https://datatracker.ietf.org/doc/html/rfc6962#section-3.2
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
pub struct SignedCertificateTimestamp {
    /// The version of the protocol to which the SCT conforms.
    /// Currently, it is always v1.
    pub version: Version,
    /// The SHA-256 hash of the log's public key, calculated over
    /// the DER encoding of the key represented as [SubjectPublicKeyInfo][spki::SubjectPublicKeyInfo].
    pub log_id: LogId,
    /// the current NTP Time measured since the `UNIX_EPOCH`
    /// (January 1, 1970, 00:00), ignoring leap seconds, in milliseconds.
    pub timestamp: u64,
    /// The future extensions to protocol version v1.
    /// Currently, no extensions are specified.
    pub extensions: TlsByteVecU16,
    /// A digital signature over many fields including
    /// version, timestamp, extensions and others. See [RFC 6962 section 3.2]
    /// for a complete list.
    ///
    /// [RFC 6962 section 3.2]:https://datatracker.ietf.org/doc/html/rfc6962#section-3.2
    pub signature: DigitallySigned,
}

impl SignedCertificateTimestamp {
    /// Creates a [DateTime][der::DateTime] from the timestamp field since the `UNIX_EPOCH`.
    ///
    /// Returns an error if timestamp is outside the supported date range.
    pub fn timestamp(&self) -> Result<der::DateTime, der::Error> {
        der::DateTime::from_unix_duration(core::time::Duration::from_millis(self.timestamp))
    }
}

/// The version of the protocol to which the SCT conforms
/// as defined in [RFC 6962 section 3.2]. Currently, it is always v1.
///
/// [RFC 6962 section 3.2]: https://datatracker.ietf.org/doc/html/rfc6962#section-3.2
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
#[repr(u8)]
pub enum Version {
    /// Version 1.
    V1 = 0,
}

/// The SHA-256 hash of the log's public key, calculated over
/// the DER encoding of the key represented as [SubjectPublicKeyInfo][spki::SubjectPublicKeyInfo]
/// as defined in [RFC 6962 section 3.2].
///
/// [RFC 6962 section 3.2]: https://datatracker.ietf.org/doc/html/rfc6962#section-3.2
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
pub struct LogId {
    /// Hash of the log's public key.
    pub key_id: [u8; 32],
}

/// Digital signature as defined in [RFC 5246 section 4.7].
///
/// [RFC 5246 section 4.7]: https://datatracker.ietf.org/doc/html/rfc5246#section-4.7
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
pub struct DigitallySigned {
    /// [SignatureAndHashAlgorithm] as defined in [RFC 5246 section 7.4.1.4.1].
    ///
    /// [RFC 5246 section 7.4.1.4.1]: https://datatracker.ietf.org/doc/html/rfc5246#section-7.4.1.4.1
    pub algorithm: SignatureAndHashAlgorithm,
    /// Digital signature over some contents using the [SignatureAndHashAlgorithm].
    pub signature: TlsByteVecU16,
}

/// A combination of signature and hashing algorithms as defined in [RFC 5246 section 7.4.1.4.1].
///
/// [RFC 5246 section 7.4.1.4.1]: https://datatracker.ietf.org/doc/html/rfc5246#section-7.4.1.4.1
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
pub struct SignatureAndHashAlgorithm {
    /// The hashing algorithm.
    pub hash: HashAlgorithm,
    /// The signature algorithm.
    pub signature: SignatureAlgorithm,
}

/// Signature algorithm as defined in [RFC 5246 section 7.4.1.4.1].
///
/// [RFC 5246 section 7.4.1.4.1]: https://datatracker.ietf.org/doc/html/rfc5246#section-7.4.1.4.1
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
#[repr(u8)]
pub enum SignatureAlgorithm {
    /// Anonymous signature algorithm.
    Anonymous = 0,
    /// RSA signature algorithm.
    Rsa = 1,
    /// DSA signature algorithm.
    Dsa = 2,
    /// ECDSA signature algorithm.
    Ecdsa = 3,
    /// ED25519 signature algorithm.
    Ed25519 = 7,
    /// ED448 signature algorithm.
    Ed448 = 8,
}

/// Hashing algorithm as defined in [RFC 5246 section 7.4.1.4.1].
///
/// [RFC 5246 section 7.4.1.4.1]: https://datatracker.ietf.org/doc/html/rfc5246#section-7.4.1.4.1
#[derive(PartialEq, Debug, TlsDeserializeBytes, TlsSerializeBytes, TlsSize)]
#[repr(u8)]
pub enum HashAlgorithm {
    /// No algorithm.
    None = 0,
    /// MD5 algorithm.
    Md5 = 1,
    /// SHA1 algorithm.
    Sha1 = 2,
    /// SHA224 algorithm.
    Sha224 = 3,
    /// SHA256 algorithm.
    Sha256 = 4,
    /// SHA384 algorithm.
    Sha384 = 5,
    /// SHA512 algorithm.
    Sha512 = 6,
    /// Intrinsic algorithm.
    Intrinsic = 8,
}

#[cfg(test)]
mod tests {
    use der::{asn1::OctetString, Decode, Encode};
    use tls_codec::{DeserializeBytes, SerializeBytes, TlsByteVecU16};

    use crate::ext::pkix::sct::LogId;

    use super::{
        DigitallySigned, HashAlgorithm, SerializedSct, SignatureAlgorithm,
        SignatureAndHashAlgorithm, SignedCertificateTimestamp, SignedCertificateTimestampList,
        Version,
    };

    fn run_deserialization_test<'a, T: DeserializeBytes + PartialEq + core::fmt::Debug>(
        bytes: &'a [u8],
        expected_result: Result<(T, &[u8]), tls_codec::Error>,
    ) -> Result<(T, &'a [u8]), tls_codec::Error> {
        let actual_result = T::tls_deserialize_bytes(bytes);
        assert_eq!(actual_result, expected_result);
        actual_result
    }

    fn run_serialization_test<T: SerializeBytes>(value: T, expected_bytes: &[u8]) {
        let result = value.tls_serialize().expect("failed to serialize value");
        assert_eq!(expected_bytes, &result);
    }

    #[test]
    fn test_hash_algorithm_deserialization() {
        let bytes = [0, 1, 2, 3, 4, 5, 6, 8];

        let result = run_deserialization_test(
            &bytes,
            Ok((HashAlgorithm::None, [1, 2, 3, 4, 5, 6, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Md5, [2, 3, 4, 5, 6, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Sha1, [3, 4, 5, 6, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Sha224, [4, 5, 6, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Sha256, [5, 6, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Sha384, [6, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Sha512, [8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((HashAlgorithm::Intrinsic, [].as_slice())),
        );
        let _ = run_deserialization_test::<HashAlgorithm>(
            result.expect("run_deserialization_test failed").1,
            Err(tls_codec::Error::EndOfStream),
        );
        let _ =
            run_deserialization_test::<HashAlgorithm>(&[7], Err(tls_codec::Error::UnknownValue(7)));
        let _ =
            run_deserialization_test::<HashAlgorithm>(&[9], Err(tls_codec::Error::UnknownValue(9)));
    }

    #[test]
    fn test_hash_algorithm_serialization() {
        run_serialization_test(HashAlgorithm::None, &[0]);
        run_serialization_test(HashAlgorithm::Md5, &[1]);
        run_serialization_test(HashAlgorithm::Sha1, &[2]);
        run_serialization_test(HashAlgorithm::Sha224, &[3]);
        run_serialization_test(HashAlgorithm::Sha256, &[4]);
        run_serialization_test(HashAlgorithm::Sha384, &[5]);
        run_serialization_test(HashAlgorithm::Sha512, &[6]);
        run_serialization_test(HashAlgorithm::Intrinsic, &[8]);
    }

    #[test]
    fn test_signature_algorithm_deserialization() {
        let bytes = [0, 1, 2, 3, 7, 8];

        let result = run_deserialization_test(
            &bytes,
            Ok((SignatureAlgorithm::Anonymous, [1, 2, 3, 7, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((SignatureAlgorithm::Rsa, [2, 3, 7, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((SignatureAlgorithm::Dsa, [3, 7, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((SignatureAlgorithm::Ecdsa, [7, 8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((SignatureAlgorithm::Ed25519, [8].as_slice())),
        );
        let result = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((SignatureAlgorithm::Ed448, [].as_slice())),
        );
        let _ = run_deserialization_test::<SignatureAlgorithm>(
            result.expect("run_deserialization_test failed").1,
            Err(tls_codec::Error::EndOfStream),
        );
        let _ = run_deserialization_test::<SignatureAlgorithm>(
            &[4],
            Err(tls_codec::Error::UnknownValue(4)),
        );
        let _ = run_deserialization_test::<SignatureAlgorithm>(
            &[5],
            Err(tls_codec::Error::UnknownValue(5)),
        );
        let _ = run_deserialization_test::<SignatureAlgorithm>(
            &[6],
            Err(tls_codec::Error::UnknownValue(6)),
        );
        let _ = run_deserialization_test::<SignatureAlgorithm>(
            &[9],
            Err(tls_codec::Error::UnknownValue(9)),
        );
    }

    #[test]
    fn test_signature_algorithm_serialization() {
        run_serialization_test(SignatureAlgorithm::Anonymous, &[0]);
        run_serialization_test(SignatureAlgorithm::Rsa, &[1]);
        run_serialization_test(SignatureAlgorithm::Dsa, &[2]);
        run_serialization_test(SignatureAlgorithm::Ecdsa, &[3]);
        run_serialization_test(SignatureAlgorithm::Ed25519, &[7]);
        run_serialization_test(SignatureAlgorithm::Ed448, &[8]);
    }

    #[test]
    fn test_signature_and_hash_algorithm_deserialization() {
        let bytes = [4, 3, 2, 1];

        let result = run_deserialization_test(
            &bytes,
            Ok((
                SignatureAndHashAlgorithm {
                    hash: HashAlgorithm::Sha256,
                    signature: SignatureAlgorithm::Ecdsa,
                },
                [2, 1].as_slice(),
            )),
        );

        let _ = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((
                SignatureAndHashAlgorithm {
                    hash: HashAlgorithm::Sha1,
                    signature: SignatureAlgorithm::Rsa,
                },
                [].as_slice(),
            )),
        );
    }

    #[test]
    fn test_signature_and_hash_algorithm_serialization() {
        run_serialization_test(
            SignatureAndHashAlgorithm {
                hash: HashAlgorithm::Sha1,
                signature: SignatureAlgorithm::Rsa,
            },
            &[2, 1],
        );
        run_serialization_test(
            SignatureAndHashAlgorithm {
                hash: HashAlgorithm::Sha256,
                signature: SignatureAlgorithm::Ecdsa,
            },
            &[4, 3],
        );
    }

    #[test]
    fn test_digitally_signed_deserialization() {
        let bytes = [4, 3, 0, 3, 2, 1, 0, 2, 1, 0, 1, 9];

        let result = run_deserialization_test(
            &bytes,
            Ok((
                DigitallySigned {
                    algorithm: SignatureAndHashAlgorithm {
                        hash: HashAlgorithm::Sha256,
                        signature: SignatureAlgorithm::Ecdsa,
                    },
                    signature: TlsByteVecU16::from_slice(&[2, 1, 0]),
                },
                [2, 1, 0, 1, 9].as_slice(),
            )),
        );

        let _ = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((
                DigitallySigned {
                    algorithm: SignatureAndHashAlgorithm {
                        hash: HashAlgorithm::Sha1,
                        signature: SignatureAlgorithm::Rsa,
                    },
                    signature: TlsByteVecU16::from_slice(&[9]),
                },
                [].as_slice(),
            )),
        );
    }

    #[test]
    fn test_digitally_signed_serialization() {
        run_serialization_test(
            DigitallySigned {
                algorithm: SignatureAndHashAlgorithm {
                    hash: HashAlgorithm::Sha256,
                    signature: SignatureAlgorithm::Ecdsa,
                },
                signature: TlsByteVecU16::from_slice(&[0, 1, 2]),
            },
            &[4, 3, 0, 3, 0, 1, 2],
        );
        run_serialization_test(
            DigitallySigned {
                algorithm: SignatureAndHashAlgorithm {
                    hash: HashAlgorithm::Sha1,
                    signature: SignatureAlgorithm::Rsa,
                },
                signature: TlsByteVecU16::from_slice(&[0, 1, 2]),
            },
            &[2, 1, 0, 3, 0, 1, 2],
        );
    }

    #[test]
    fn test_version_deserialization() {
        let bytes = [0, 0];

        let result = run_deserialization_test(&bytes, Ok((Version::V1, [0].as_slice())));

        let _ = run_deserialization_test(
            result.expect("run_deserialization_test failed").1,
            Ok((Version::V1, [].as_slice())),
        );
        let _ = run_deserialization_test::<Version>(&[1], Err(tls_codec::Error::UnknownValue(1)));
    }

    #[test]
    fn test_version_serialization() {
        run_serialization_test(Version::V1, &[0]);
    }

    #[test]
    fn test_log_id_deserialization() {
        let bytes = [42; 36];

        let _ =
            run_deserialization_test(&bytes, Ok((LogId { key_id: [42; 32] }, [42; 4].as_slice())));
    }

    #[test]
    fn test_log_id_serialization() {
        run_serialization_test(LogId { key_id: [3; 32] }, &[3; 32]);
    }

    const TLS_SCT_EXAMPLE: [u8; 119] = [
        0, 122, 50, 140, 84, 216, 183, 45, 182, 32, 234, 56, 224, 82, 30, 233, 132, 22, 112, 50,
        19, 133, 77, 59, 210, 43, 193, 58, 87, 163, 82, 235, 82, 0, 0, 1, 135, 224, 74, 186, 106,
        0, 0, 4, 3, 0, 72, 48, 70, 2, 33, 0, 170, 82, 81, 162, 157, 234, 14, 189, 167, 13, 247,
        211, 97, 112, 248, 172, 149, 125, 58, 18, 238, 60, 150, 157, 124, 245, 188, 138, 102, 212,
        244, 187, 2, 33, 0, 209, 79, 31, 63, 208, 79, 240, 233, 193, 187, 28, 33, 190, 95, 130, 66,
        183, 222, 187, 42, 22, 83, 0, 119, 226, 246, 19, 197, 47, 237, 198, 149,
    ];

    #[test]
    fn test_sct_deserialization() {
        let _ = run_deserialization_test(
            &TLS_SCT_EXAMPLE,
            Ok((
                SignedCertificateTimestamp {
                    version: Version::V1,
                    log_id: LogId {
                        key_id: TLS_SCT_EXAMPLE[1..33]
                            .try_into()
                            .expect("failed to convert to u8 array"),
                    },
                    timestamp: u64::from_be_bytes(
                        TLS_SCT_EXAMPLE[33..41]
                            .try_into()
                            .expect("failed to convert to u8 array"),
                    ),
                    extensions: TlsByteVecU16::from_slice(&[]),
                    signature: DigitallySigned {
                        algorithm: SignatureAndHashAlgorithm {
                            hash: HashAlgorithm::Sha256,
                            signature: SignatureAlgorithm::Ecdsa,
                        },
                        signature: TlsByteVecU16::from_slice(&TLS_SCT_EXAMPLE[47..]),
                    },
                },
                &[],
            )),
        );
    }

    #[test]
    fn test_sct_serialization() {
        run_serialization_test(
            SignedCertificateTimestamp {
                version: Version::V1,
                log_id: LogId {
                    key_id: TLS_SCT_EXAMPLE[1..33]
                        .try_into()
                        .expect("failed to convert to u8 array"),
                },
                timestamp: u64::from_be_bytes(
                    TLS_SCT_EXAMPLE[33..41]
                        .try_into()
                        .expect("failed to convert to u8 array"),
                ),
                extensions: TlsByteVecU16::from_slice(&[]),
                signature: DigitallySigned {
                    algorithm: SignatureAndHashAlgorithm {
                        hash: HashAlgorithm::Sha256,
                        signature: SignatureAlgorithm::Ecdsa,
                    },
                    signature: TlsByteVecU16::from_slice(&TLS_SCT_EXAMPLE[47..]),
                },
            },
            &TLS_SCT_EXAMPLE,
        );
    }

    const SCT_EXAMPLE: [u8; 245] = [
        4, 129, 242, 0, 240, 0, 119, 0, 122, 50, 140, 84, 216, 183, 45, 182, 32, 234, 56, 224, 82,
        30, 233, 132, 22, 112, 50, 19, 133, 77, 59, 210, 43, 193, 58, 87, 163, 82, 235, 82, 0, 0,
        1, 135, 224, 74, 186, 106, 0, 0, 4, 3, 0, 72, 48, 70, 2, 33, 0, 170, 82, 81, 162, 157, 234,
        14, 189, 167, 13, 247, 211, 97, 112, 248, 172, 149, 125, 58, 18, 238, 60, 150, 157, 124,
        245, 188, 138, 102, 212, 244, 187, 2, 33, 0, 209, 79, 31, 63, 208, 79, 240, 233, 193, 187,
        28, 33, 190, 95, 130, 66, 183, 222, 187, 42, 22, 83, 0, 119, 226, 246, 19, 197, 47, 237,
        198, 149, 0, 117, 0, 173, 247, 190, 250, 124, 255, 16, 200, 139, 157, 61, 156, 30, 62, 24,
        106, 180, 103, 41, 93, 207, 177, 12, 36, 202, 133, 134, 52, 235, 220, 130, 138, 0, 0, 1,
        135, 224, 74, 186, 164, 0, 0, 4, 3, 0, 70, 48, 68, 2, 32, 29, 110, 144, 37, 157, 227, 170,
        70, 67, 16, 68, 195, 212, 168, 246, 37, 94, 69, 210, 136, 42, 113, 217, 230, 34, 152, 253,
        116, 13, 174, 232, 191, 2, 32, 16, 25, 200, 223, 59, 176, 40, 145, 76, 85, 242, 133, 130,
        212, 61, 216, 83, 238, 115, 130, 82, 240, 196, 162, 249, 54, 199, 120, 175, 72, 223, 14,
    ];

    #[test]
    fn test_sct_list_deserialization() {
        fn run_test(
            bytes: &[u8],
            expected_result: Result<SignedCertificateTimestampList, der::Error>,
        ) -> Result<SignedCertificateTimestampList, der::Error> {
            let actual_result = SignedCertificateTimestampList::from_der(bytes);
            assert_eq!(actual_result, expected_result);
            actual_result
        }

        let result = run_test(
            &SCT_EXAMPLE,
            Ok(SignedCertificateTimestampList(
                OctetString::new(&SCT_EXAMPLE[3..]).expect("failed to convert to u8 array"),
            )),
        );
        let scts = result
            .expect("run_test failed")
            .parse_timestamps()
            .expect("parse_timestamps failed");
        assert_eq!(
            scts[0].parse_timestamp(),
            Ok(SignedCertificateTimestamp {
                version: Version::V1,
                log_id: LogId {
                    key_id: SCT_EXAMPLE[8..40]
                        .try_into()
                        .expect("failed to convert to u8 array"),
                },
                timestamp: u64::from_be_bytes(
                    SCT_EXAMPLE[40..48]
                        .try_into()
                        .expect("failed to convert to u8 array")
                ),
                extensions: TlsByteVecU16::from_slice(&[]),
                signature: DigitallySigned {
                    algorithm: SignatureAndHashAlgorithm {
                        hash: HashAlgorithm::Sha256,
                        signature: SignatureAlgorithm::Ecdsa,
                    },
                    signature: TlsByteVecU16::from_slice(&SCT_EXAMPLE[54..126]),
                },
            })
        );
        assert_eq!(
            scts[1].parse_timestamp(),
            Ok(SignedCertificateTimestamp {
                version: Version::V1,
                log_id: LogId {
                    key_id: SCT_EXAMPLE[129..161]
                        .try_into()
                        .expect("failed to convert to u8 array"),
                },
                timestamp: u64::from_be_bytes(
                    SCT_EXAMPLE[161..169]
                        .try_into()
                        .expect("failed to convert to u8 array")
                ),
                extensions: TlsByteVecU16::from_slice(&[]),
                signature: DigitallySigned {
                    algorithm: SignatureAndHashAlgorithm {
                        hash: HashAlgorithm::Sha256,
                        signature: SignatureAlgorithm::Ecdsa,
                    },
                    signature: TlsByteVecU16::from_slice(&SCT_EXAMPLE[175..]),
                },
            })
        );
    }

    #[test]
    fn test_sct_list_serialization() {
        let serialized_sct1 = SerializedSct::new(SignedCertificateTimestamp {
            version: Version::V1,
            log_id: LogId {
                key_id: SCT_EXAMPLE[8..40]
                    .try_into()
                    .expect("failed to convert to u8 array"),
            },
            timestamp: u64::from_be_bytes(
                SCT_EXAMPLE[40..48]
                    .try_into()
                    .expect("failed to convert to u8 array"),
            ),
            extensions: TlsByteVecU16::from_slice(&[]),
            signature: DigitallySigned {
                algorithm: SignatureAndHashAlgorithm {
                    hash: HashAlgorithm::Sha256,
                    signature: SignatureAlgorithm::Ecdsa,
                },
                signature: TlsByteVecU16::from_slice(&SCT_EXAMPLE[54..126]),
            },
        })
        .expect("failed to create SerializedSct");
        let serialized_sct2 = SerializedSct::new(SignedCertificateTimestamp {
            version: Version::V1,
            log_id: LogId {
                key_id: SCT_EXAMPLE[129..161]
                    .try_into()
                    .expect("failed to convert to u8 array"),
            },
            timestamp: u64::from_be_bytes(
                SCT_EXAMPLE[161..169]
                    .try_into()
                    .expect("failed to convert to u8 array"),
            ),
            extensions: TlsByteVecU16::from_slice(&[]),
            signature: DigitallySigned {
                algorithm: SignatureAndHashAlgorithm {
                    hash: HashAlgorithm::Sha256,
                    signature: SignatureAlgorithm::Ecdsa,
                },
                signature: TlsByteVecU16::from_slice(&SCT_EXAMPLE[175..]),
            },
        })
        .expect("failed to create SerializedSct");
        let list = SignedCertificateTimestampList::new(&[serialized_sct1, serialized_sct2])
            .expect("failed to create SignedCertificateTimestampList");
        let der = list.to_der().expect("failed to convert to der");
        assert_eq!(der.as_slice(), SCT_EXAMPLE.as_slice());
    }
}
