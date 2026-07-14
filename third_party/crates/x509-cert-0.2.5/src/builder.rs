//! X509 Certificate builder

use alloc::vec;
use core::fmt;
use der::{asn1::BitString, referenced::OwnedToRef, Encode};
use signature::{rand_core::CryptoRngCore, Keypair, RandomizedSigner, Signer};
use spki::{
    DynSignatureAlgorithmIdentifier, EncodePublicKey, SignatureBitStringEncoding,
    SubjectPublicKeyInfoOwned, SubjectPublicKeyInfoRef,
};

use crate::{
    certificate::{Certificate, TbsCertificate, Version},
    ext::{
        pkix::{
            AuthorityKeyIdentifier, BasicConstraints, KeyUsage, KeyUsages, SubjectKeyIdentifier,
        },
        AsExtension, Extension, Extensions,
    },
    name::Name,
    request::{attributes::AsAttribute, CertReq, CertReqInfo, ExtensionReq},
    serial_number::SerialNumber,
    time::Validity,
};

/// Error type
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// ASN.1 DER-related errors.
    Asn1(der::Error),

    /// Public key errors propagated from the [`spki::Error`] type.
    PublicKey(spki::Error),

    /// Signing error propagated for the [`signature::Error`] type.
    Signature(signature::Error),
}

#[cfg(feature = "std")]
impl std::error::Error for Error {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Asn1(err) => write!(f, "ASN.1 error: {}", err),
            Error::PublicKey(err) => write!(f, "public key error: {}", err),
            Error::Signature(err) => write!(f, "signature error: {}", err),
        }
    }
}

impl From<der::Error> for Error {
    fn from(err: der::Error) -> Error {
        Error::Asn1(err)
    }
}

impl From<spki::Error> for Error {
    fn from(err: spki::Error) -> Error {
        Error::PublicKey(err)
    }
}

impl From<signature::Error> for Error {
    fn from(err: signature::Error) -> Error {
        Error::Signature(err)
    }
}

type Result<T> = core::result::Result<T, Error>;

/// The type of certificate to build
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Profile {
    /// Build a root CA certificate
    Root,
    /// Build an intermediate sub CA certificate
    SubCA {
        /// issuer   Name,
        /// represents the name signing the certificate
        issuer: Name,
        /// pathLenConstraint       INTEGER (0..MAX) OPTIONAL
        /// BasicConstraints as defined in [RFC 5280 Section 4.2.1.9].
        path_len_constraint: Option<u8>,
    },
    /// Build an end certificate
    Leaf {
        /// issuer   Name,
        /// represents the name signing the certificate
        issuer: Name,
        /// should the key agreement flag of KeyUsage be enabled
        enable_key_agreement: bool,
        /// should the key encipherment flag of KeyUsage be enabled
        enable_key_encipherment: bool,
        /// should the subject key identifier extension be included
        ///
        /// From [RFC 5280 Section 4.2.1.2]:
        ///  For end entity certificates, subject key identifiers SHOULD be
        ///  derived from the public key.  Two common methods for generating key
        ///  identifiers from the public key are identified above.
        #[cfg(feature = "hazmat")]
        include_subject_key_identifier: bool,
    },
    #[cfg(feature = "hazmat")]
    /// Opt-out of the default extensions
    Manual {
        /// issuer   Name,
        /// represents the name signing the certificate
        /// A `None` will make it a self-signed certificate
        issuer: Option<Name>,
    },
}

impl Profile {
    fn get_issuer(&self, subject: &Name) -> Name {
        match self {
            Profile::Root => subject.clone(),
            Profile::SubCA { issuer, .. } => issuer.clone(),
            Profile::Leaf { issuer, .. } => issuer.clone(),
            #[cfg(feature = "hazmat")]
            Profile::Manual { issuer, .. } => issuer.as_ref().unwrap_or(subject).clone(),
        }
    }

    fn build_extensions(
        &self,
        spk: SubjectPublicKeyInfoRef<'_>,
        issuer_spk: SubjectPublicKeyInfoRef<'_>,
        tbs: &TbsCertificate,
    ) -> Result<vec::Vec<Extension>> {
        #[cfg(feature = "hazmat")]
        // User opted out of default extensions set.
        if let Profile::Manual { .. } = self {
            return Ok(vec::Vec::default());
        }

        let mut extensions: vec::Vec<Extension> = vec::Vec::new();

        match self {
            #[cfg(feature = "hazmat")]
            Profile::Leaf {
                include_subject_key_identifier: false,
                ..
            } => {}
            _ => extensions.push(
                SubjectKeyIdentifier::try_from(spk)?.to_extension(&tbs.subject, &extensions)?,
            ),
        }

        // Build Authority Key Identifier
        match self {
            Profile::Root => {}
            _ => {
                extensions.push(
                    AuthorityKeyIdentifier::try_from(issuer_spk.clone())?
                        .to_extension(&tbs.subject, &extensions)?,
                );
            }
        }

        // Build Basic Contraints extensions
        extensions.push(match self {
            Profile::Root => BasicConstraints {
                ca: true,
                path_len_constraint: None,
            }
            .to_extension(&tbs.subject, &extensions)?,
            Profile::SubCA {
                path_len_constraint,
                ..
            } => BasicConstraints {
                ca: true,
                path_len_constraint: *path_len_constraint,
            }
            .to_extension(&tbs.subject, &extensions)?,
            Profile::Leaf { .. } => BasicConstraints {
                ca: false,
                path_len_constraint: None,
            }
            .to_extension(&tbs.subject, &extensions)?,
            #[cfg(feature = "hazmat")]
            Profile::Manual { .. } => unreachable!(),
        });

        // Build Key Usage extension
        match self {
            Profile::Root | Profile::SubCA { .. } => {
                extensions.push(
                    KeyUsage(KeyUsages::KeyCertSign | KeyUsages::CRLSign)
                        .to_extension(&tbs.subject, &extensions)?,
                );
            }
            Profile::Leaf {
                enable_key_agreement,
                enable_key_encipherment,
                ..
            } => {
                let mut key_usage = KeyUsages::DigitalSignature | KeyUsages::NonRepudiation;
                if *enable_key_encipherment {
                    key_usage |= KeyUsages::KeyEncipherment;
                }
                if *enable_key_agreement {
                    key_usage |= KeyUsages::KeyAgreement;
                }

                extensions.push(KeyUsage(key_usage).to_extension(&tbs.subject, &extensions)?);
            }
            #[cfg(feature = "hazmat")]
            Profile::Manual { .. } => unreachable!(),
        }

        Ok(extensions)
    }
}

/// X509 Certificate builder
///
/// ```
/// use der::Decode;
/// use x509_cert::spki::SubjectPublicKeyInfoOwned;
/// use x509_cert::builder::{CertificateBuilder, Profile};
/// use x509_cert::name::Name;
/// use x509_cert::serial_number::SerialNumber;
/// use x509_cert::time::Validity;
/// use std::str::FromStr;
///
/// # const RSA_2048_DER: &[u8] = include_bytes!("../tests/examples/rsa2048-pub.der");
/// # const RSA_2048_PRIV_DER: &[u8] = include_bytes!("../tests/examples/rsa2048-priv.der");
/// # use rsa::{pkcs1v15::SigningKey, pkcs1::DecodeRsaPrivateKey};
/// # use sha2::Sha256;
/// # use std::time::Duration;
/// # use der::referenced::RefToOwned;
/// # fn rsa_signer() -> SigningKey<Sha256> {
/// #     let private_key = rsa::RsaPrivateKey::from_pkcs1_der(RSA_2048_PRIV_DER).unwrap();
/// #     let signing_key = SigningKey::<Sha256>::new_with_prefix(private_key);
/// #     signing_key
/// # }
///
/// let serial_number = SerialNumber::from(42u32);
/// let validity = Validity::from_now(Duration::new(5, 0)).unwrap();
/// let profile = Profile::Root;
/// let subject = Name::from_str("CN=World domination corporation,O=World domination Inc,C=US").unwrap();
///
/// let pub_key = SubjectPublicKeyInfoOwned::try_from(RSA_2048_DER).expect("get rsa pub key");
///
/// let mut signer = rsa_signer();
/// let mut builder = CertificateBuilder::new(
///     profile,
///     serial_number,
///     validity,
///     subject,
///     pub_key,
///     &signer,
/// )
/// .expect("Create certificate");
/// ```
pub struct CertificateBuilder<'s, S> {
    tbs: TbsCertificate,
    extensions: Extensions,
    cert_signer: &'s S,
}

impl<'s, S> CertificateBuilder<'s, S>
where
    S: Keypair + DynSignatureAlgorithmIdentifier,
    S::VerifyingKey: EncodePublicKey,
{
    /// Creates a new certificate builder
    pub fn new(
        profile: Profile,
        serial_number: SerialNumber,
        mut validity: Validity,
        subject: Name,
        subject_public_key_info: SubjectPublicKeyInfoOwned,
        cert_signer: &'s S,
    ) -> Result<Self> {
        let verifying_key = cert_signer.verifying_key();
        let signer_pub = SubjectPublicKeyInfoOwned::from_key(verifying_key)?;

        let signature_alg = cert_signer.signature_algorithm_identifier()?;
        let issuer = profile.get_issuer(&subject);

        validity.not_before.rfc5280_adjust_utc_time()?;
        validity.not_after.rfc5280_adjust_utc_time()?;

        let tbs = TbsCertificate {
            version: Version::V3,
            serial_number,
            signature: signature_alg,
            issuer,
            validity,
            subject,
            subject_public_key_info,
            extensions: None,

            // We will not generate unique identifier because as per RFC5280 Section 4.1.2.8:
            //   CAs conforming to this profile MUST NOT generate
            //   certificates with unique identifiers.
            //
            // https://datatracker.ietf.org/doc/html/rfc5280#section-4.1.2.8
            issuer_unique_id: None,
            subject_unique_id: None,
        };

        let extensions = profile.build_extensions(
            tbs.subject_public_key_info.owned_to_ref(),
            signer_pub.owned_to_ref(),
            &tbs,
        )?;
        Ok(Self {
            tbs,
            extensions,
            cert_signer,
        })
    }

    /// Add an extension to this certificate
    pub fn add_extension<E: AsExtension>(&mut self, extension: &E) -> Result<()> {
        let ext = extension.to_extension(&self.tbs.subject, &self.extensions)?;
        self.extensions.push(ext);

        Ok(())
    }
}

/// Builder for X509 Certificate Requests
///
/// ```
/// # use p256::{pkcs8::DecodePrivateKey, NistP256, ecdsa::DerSignature};
/// # const PKCS8_PRIVATE_KEY_DER: &[u8] = include_bytes!("../tests/examples/p256-priv.der");
/// # fn ecdsa_signer() -> ecdsa::SigningKey<NistP256> {
/// #     let secret_key = p256::SecretKey::from_pkcs8_der(PKCS8_PRIVATE_KEY_DER).unwrap();
/// #     ecdsa::SigningKey::from(secret_key)
/// # }
/// use x509_cert::{
///     builder::{Builder, RequestBuilder},
///     ext::pkix::{name::GeneralName, SubjectAltName},
///     name::Name,
/// };
/// use std::str::FromStr;
///
/// use std::net::{IpAddr, Ipv4Addr};
/// let subject = Name::from_str("CN=service.domination.world").unwrap();
///
/// let signer = ecdsa_signer();
/// let mut builder = RequestBuilder::new(subject, &signer).expect("Create certificate request");
/// builder
///     .add_extension(&SubjectAltName(vec![GeneralName::from(IpAddr::V4(
///         Ipv4Addr::new(192, 0, 2, 0),
///     ))]))
///     .unwrap();
///
/// let cert_req = builder.build::<DerSignature>().unwrap();
/// ```
pub struct RequestBuilder<'s, S> {
    info: CertReqInfo,
    extension_req: ExtensionReq,
    req_signer: &'s S,
}

impl<'s, S> RequestBuilder<'s, S>
where
    S: Keypair + DynSignatureAlgorithmIdentifier,
    S::VerifyingKey: EncodePublicKey,
{
    /// Creates a new certificate request builder
    pub fn new(subject: Name, req_signer: &'s S) -> Result<Self> {
        let version = Default::default();
        let verifying_key = req_signer.verifying_key();
        let public_key = SubjectPublicKeyInfoOwned::from_key(verifying_key)?;
        let attributes = Default::default();
        let extension_req = Default::default();

        Ok(Self {
            info: CertReqInfo {
                version,
                subject,
                public_key,
                attributes,
            },
            extension_req,
            req_signer,
        })
    }

    /// Add an extension to this certificate request
    pub fn add_extension<E: AsExtension>(&mut self, extension: &E) -> Result<()> {
        let ext = extension.to_extension(&self.info.subject, &self.extension_req.0)?;

        self.extension_req.0.push(ext);

        Ok(())
    }

    /// Add an attribute to this certificate request
    pub fn add_attribute<A: AsAttribute>(&mut self, attribute: &A) -> Result<()> {
        let attr = attribute.to_attribute()?;

        self.info.attributes.insert(attr)?;
        Ok(())
    }
}

/// Trait for X509 builders
///
/// This trait defines the interface between builder and the signers.
pub trait Builder: Sized {
    /// The builder's object signer
    type Signer;

    /// Type built by this builder
    type Output: Sized;

    /// Return a reference to the signer.
    fn signer(&self) -> &Self::Signer;

    /// Assemble the final object from signature.
    fn assemble(self, signature: BitString) -> Result<Self::Output>;

    /// Finalize and return a serialization of the object for signature.
    fn finalize(&mut self) -> der::Result<vec::Vec<u8>>;

    /// Run the object through the signer and build it.
    fn build<Signature>(mut self) -> Result<Self::Output>
    where
        Self::Signer: Signer<Signature>,
        Signature: SignatureBitStringEncoding,
    {
        let blob = self.finalize()?;

        let signature = self.signer().try_sign(&blob)?.to_bitstring()?;

        self.assemble(signature)
    }

    /// Run the object through the signer and build it.
    fn build_with_rng<Signature>(mut self, rng: &mut impl CryptoRngCore) -> Result<Self::Output>
    where
        Self::Signer: RandomizedSigner<Signature>,
        Signature: SignatureBitStringEncoding,
    {
        let blob = self.finalize()?;

        let signature = self
            .signer()
            .try_sign_with_rng(rng, &blob)?
            .to_bitstring()?;

        self.assemble(signature)
    }
}

impl<'s, S> Builder for CertificateBuilder<'s, S>
where
    S: Keypair + DynSignatureAlgorithmIdentifier,
    S::VerifyingKey: EncodePublicKey,
{
    type Signer = S;
    type Output = Certificate;

    fn signer(&self) -> &Self::Signer {
        self.cert_signer
    }

    fn finalize(&mut self) -> der::Result<vec::Vec<u8>> {
        if !self.extensions.is_empty() {
            self.tbs.extensions = Some(self.extensions.clone());
        }

        if self.tbs.extensions.is_none() {
            if self.tbs.issuer_unique_id.is_some() || self.tbs.subject_unique_id.is_some() {
                self.tbs.version = Version::V2;
            } else {
                self.tbs.version = Version::V1;
            }
        }

        self.tbs.to_der()
    }

    fn assemble(self, signature: BitString) -> Result<Self::Output> {
        let signature_algorithm = self.tbs.signature.clone();

        Ok(Certificate {
            tbs_certificate: self.tbs,
            signature_algorithm,
            signature,
        })
    }
}

impl<'s, S> Builder for RequestBuilder<'s, S>
where
    S: Keypair + DynSignatureAlgorithmIdentifier,
    S::VerifyingKey: EncodePublicKey,
{
    type Signer = S;
    type Output = CertReq;

    fn signer(&self) -> &Self::Signer {
        self.req_signer
    }

    fn finalize(&mut self) -> der::Result<vec::Vec<u8>> {
        self.info
            .attributes
            .insert(self.extension_req.clone().try_into()?)?;

        self.info.to_der()
    }

    fn assemble(self, signature: BitString) -> Result<Self::Output> {
        let algorithm = self.req_signer.signature_algorithm_identifier()?;

        Ok(CertReq {
            info: self.info,
            algorithm,
            signature,
        })
    }
}
