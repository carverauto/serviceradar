#[cfg(feature = "pem")]
use pem::Pem;
use std::convert::TryFrom;
use std::fmt;
use yasna::DERWriter;

use crate::error::ExternalError;
use crate::ring_like::error as ring_error;
use crate::ring_like::rand::SystemRandom;
use crate::ring_like::signature::{
	self, EcdsaKeyPair, Ed25519KeyPair, KeyPair as RingKeyPair, RsaEncoding, RsaKeyPair,
};
use crate::ring_like::{ecdsa_from_pkcs8, rsa_key_pair_public_modulus_len};
use crate::sign_algo::algo::*;
use crate::sign_algo::SignAlgo;
#[cfg(feature = "pem")]
use crate::ENCODE_CONFIG;
use crate::{Error, SignatureAlgorithm};

/// A key pair vairant
#[allow(clippy::large_enum_variant)]
pub(crate) enum KeyPairKind {
	/// A Ecdsa key pair
	Ec(EcdsaKeyPair),
	/// A Ed25519 key pair
	Ed(Ed25519KeyPair),
	/// A RSA key pair
	Rsa(RsaKeyPair, &'static dyn RsaEncoding),
	/// A remote key pair
	Remote(Box<dyn RemoteKeyPair + Send + Sync>),
}

impl fmt::Debug for KeyPairKind {
	fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
		match self {
			Self::Ec(key_pair) => write!(f, "{:?}", key_pair),
			Self::Ed(key_pair) => write!(f, "{:?}", key_pair),
			Self::Rsa(key_pair, _) => write!(f, "{:?}", key_pair),
			Self::Remote(_) => write!(f, "Box<dyn RemotePrivateKey>"),
		}
	}
}

/// A key pair used to sign certificates and CSRs
///
/// Note that ring, the underlying library to handle RSA keys
/// requires them to be in a special format, meaning that
/// `openssl genrsa` doesn't work. See ring's [documentation](ring::signature::RsaKeyPair::from_pkcs8)
/// for how to generate RSA keys in the wanted format
/// and conversion between the formats.
#[derive(Debug)]
pub struct KeyPair {
	pub(crate) kind: KeyPairKind,
	pub(crate) alg: &'static SignatureAlgorithm,
	pub(crate) serialized_der: Vec<u8>,
}

impl KeyPair {
	/// Parses the key pair from the DER format
	///
	/// Equivalent to using the [`TryFrom`] implementation.
	pub fn from_der(der: &[u8]) -> Result<Self, Error> {
		Ok(der.try_into()?)
	}

	/// Returns the key pair's signature algorithm
	pub fn algorithm(&self) -> &'static SignatureAlgorithm {
		self.alg
	}

	/// Parses the key pair from the ASCII PEM format
	#[cfg(feature = "pem")]
	pub fn from_pem(pem_str: &str) -> Result<Self, Error> {
		let private_key = pem::parse(pem_str)._err()?;
		let private_key_der: &[_] = private_key.contents();
		Ok(private_key_der.try_into()?)
	}

	/// Obtains the key pair from a raw public key and a remote private key
	pub fn from_remote(key_pair: Box<dyn RemoteKeyPair + Send + Sync>) -> Result<Self, Error> {
		Ok(Self {
			alg: key_pair.algorithm(),
			kind: KeyPairKind::Remote(key_pair),
			serialized_der: Vec::new(),
		})
	}

	/// Obtains the key pair from a DER formatted key
	/// using the specified [`SignatureAlgorithm`]
	///
	/// Same as [from_pem_and_sign_algo](Self::from_pem_and_sign_algo).
	#[cfg(feature = "pem")]
	pub fn from_pem_and_sign_algo(
		pem_str: &str,
		alg: &'static SignatureAlgorithm,
	) -> Result<Self, Error> {
		let private_key = pem::parse(pem_str)._err()?;
		let private_key_der: &[_] = private_key.contents();
		Ok(Self::from_der_and_sign_algo(private_key_der, alg)?)
	}

	/// Obtains the key pair from a DER formatted key
	/// using the specified [`SignatureAlgorithm`]
	///
	/// Usually, calling this function is not neccessary and you can just call
	/// [`from_der`](Self::from_der) instead. That function will try to figure
	/// out a fitting [`SignatureAlgorithm`] for the given
	/// key pair. However, sometimes multiple signature algorithms fit for the
	/// same der key. In that instance, you can use this function to precisely
	/// specify the `SignatureAlgorithm`.
	pub fn from_der_and_sign_algo(
		pkcs8: &[u8],
		alg: &'static SignatureAlgorithm,
	) -> Result<Self, Error> {
		let rng = &SystemRandom::new();
		let pkcs8_vec = pkcs8.to_vec();

		let kind = if alg == &PKCS_ED25519 {
			KeyPairKind::Ed(Ed25519KeyPair::from_pkcs8_maybe_unchecked(pkcs8)._err()?)
		} else if alg == &PKCS_ECDSA_P256_SHA256 {
			KeyPairKind::Ec(ecdsa_from_pkcs8(
				&signature::ECDSA_P256_SHA256_ASN1_SIGNING,
				pkcs8,
				rng,
			)?)
		} else if alg == &PKCS_ECDSA_P384_SHA384 {
			KeyPairKind::Ec(ecdsa_from_pkcs8(
				&signature::ECDSA_P384_SHA384_ASN1_SIGNING,
				pkcs8,
				rng,
			)?)
		} else if alg == &PKCS_RSA_SHA256 {
			let rsakp = RsaKeyPair::from_pkcs8(pkcs8)._err()?;
			KeyPairKind::Rsa(rsakp, &signature::RSA_PKCS1_SHA256)
		} else if alg == &PKCS_RSA_SHA384 {
			let rsakp = RsaKeyPair::from_pkcs8(pkcs8)._err()?;
			KeyPairKind::Rsa(rsakp, &signature::RSA_PKCS1_SHA384)
		} else if alg == &PKCS_RSA_SHA512 {
			let rsakp = RsaKeyPair::from_pkcs8(pkcs8)._err()?;
			KeyPairKind::Rsa(rsakp, &signature::RSA_PKCS1_SHA512)
		} else if alg == &PKCS_RSA_PSS_SHA256 {
			let rsakp = RsaKeyPair::from_pkcs8(pkcs8)._err()?;
			KeyPairKind::Rsa(rsakp, &signature::RSA_PSS_SHA256)
		} else {
			panic!("Unknown SignatureAlgorithm specified!");
		};

		Ok(KeyPair {
			kind,
			alg,
			serialized_der: pkcs8_vec,
		})
	}

	pub(crate) fn from_raw(
		pkcs8: &[u8],
	) -> Result<(KeyPairKind, &'static SignatureAlgorithm), Error> {
		let rng = SystemRandom::new();
		let (kind, alg) = if let Ok(edkp) = Ed25519KeyPair::from_pkcs8_maybe_unchecked(pkcs8) {
			(KeyPairKind::Ed(edkp), &PKCS_ED25519)
		} else if let Ok(eckp) =
			ecdsa_from_pkcs8(&signature::ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8, &rng)
		{
			(KeyPairKind::Ec(eckp), &PKCS_ECDSA_P256_SHA256)
		} else if let Ok(eckp) =
			ecdsa_from_pkcs8(&signature::ECDSA_P384_SHA384_ASN1_SIGNING, pkcs8, &rng)
		{
			(KeyPairKind::Ec(eckp), &PKCS_ECDSA_P384_SHA384)
		} else if let Ok(rsakp) = RsaKeyPair::from_pkcs8(pkcs8) {
			(
				KeyPairKind::Rsa(rsakp, &signature::RSA_PKCS1_SHA256),
				&PKCS_RSA_SHA256,
			)
		} else {
			return Err(Error::CouldNotParseKeyPair);
		};
		Ok((kind, alg))
	}

	/// Generate a new random key pair for the specified signature algorithm
	pub fn generate(alg: &'static SignatureAlgorithm) -> Result<Self, Error> {
		let rng = &SystemRandom::new();

		match alg.sign_alg {
			SignAlgo::EcDsa(sign_alg) => {
				let key_pair_doc = EcdsaKeyPair::generate_pkcs8(sign_alg, rng)._err()?;
				let key_pair_serialized = key_pair_doc.as_ref().to_vec();

				let key_pair = ecdsa_from_pkcs8(&sign_alg, &&key_pair_doc.as_ref(), rng).unwrap();
				Ok(KeyPair {
					kind: KeyPairKind::Ec(key_pair),
					alg,
					serialized_der: key_pair_serialized,
				})
			},
			SignAlgo::EdDsa(_sign_alg) => {
				let key_pair_doc = Ed25519KeyPair::generate_pkcs8(rng)._err()?;
				let key_pair_serialized = key_pair_doc.as_ref().to_vec();

				let key_pair = Ed25519KeyPair::from_pkcs8(&&key_pair_doc.as_ref()).unwrap();
				Ok(KeyPair {
					kind: KeyPairKind::Ed(key_pair),
					alg,
					serialized_der: key_pair_serialized,
				})
			},
			// Ring doesn't have RSA key generation yet:
			// https://github.com/briansmith/ring/issues/219
			// https://github.com/briansmith/ring/pull/733
			SignAlgo::Rsa() => Err(Error::KeyGenerationUnavailable),
		}
	}

	/// Get the raw public key of this key pair
	///
	/// The key is in raw format, as how [`ring::signature::KeyPair::public_key`]
	/// would output, and how [`ring::signature::UnparsedPublicKey::verify`]
	/// would accept.
	pub fn public_key_raw(&self) -> &[u8] {
		self.raw_bytes()
	}

	/// Check if this key pair can be used with the given signature algorithm
	pub fn is_compatible(&self, signature_algorithm: &SignatureAlgorithm) -> bool {
		self.alg == signature_algorithm
	}

	/// Returns (possibly multiple) compatible [`SignatureAlgorithm`]'s
	/// that the key can be used with
	pub fn compatible_algs(&self) -> impl Iterator<Item = &'static SignatureAlgorithm> {
		std::iter::once(self.alg)
	}

	pub(crate) fn sign(&self, msg: &[u8], writer: DERWriter) -> Result<(), Error> {
		match &self.kind {
			KeyPairKind::Ec(kp) => {
				let system_random = SystemRandom::new();
				let signature = kp.sign(&system_random, msg)._err()?;
				let sig = &signature.as_ref();
				writer.write_bitvec_bytes(&sig, &sig.len() * 8);
			},
			KeyPairKind::Ed(kp) => {
				let signature = kp.sign(msg);
				let sig = &signature.as_ref();
				writer.write_bitvec_bytes(&sig, &sig.len() * 8);
			},
			KeyPairKind::Rsa(kp, padding_alg) => {
				let system_random = SystemRandom::new();
				let mut signature = vec![0; rsa_key_pair_public_modulus_len(kp)];
				kp.sign(*padding_alg, &system_random, msg, &mut signature)
					._err()?;
				let sig = &signature.as_ref();
				writer.write_bitvec_bytes(&sig, &sig.len() * 8);
			},
			KeyPairKind::Remote(kp) => {
				let signature = kp.sign(msg)?;
				writer.write_bitvec_bytes(&signature, &signature.len() * 8);
			},
		}
		Ok(())
	}

	/// Return the key pair's public key in DER format
	///
	/// The key is formatted according to the SubjectPublicKeyInfo struct of
	/// X.509.
	/// See [RFC 5280 section 4.1](https://tools.ietf.org/html/rfc5280#section-4.1).
	pub fn public_key_der(&self) -> Vec<u8> {
		yasna::construct_der(|writer| self.serialize_public_key_der(writer))
	}

	/// Return the key pair's public key in PEM format
	///
	/// The returned string can be interpreted with `openssl pkey --inform PEM -pubout -pubin -text`
	#[cfg(feature = "pem")]
	pub fn public_key_pem(&self) -> String {
		let contents = self.public_key_der();
		let p = Pem::new("PUBLIC KEY", contents);
		pem::encode_config(&p, ENCODE_CONFIG)
	}

	/// Serializes the key pair (including the private key) in PKCS#8 format in DER
	///
	/// Panics if called on a remote key pair.
	pub fn serialize_der(&self) -> Vec<u8> {
		if let KeyPairKind::Remote(_) = self.kind {
			panic!("Serializing a remote key pair is not supported")
		}

		self.serialized_der.clone()
	}

	/// Returns a reference to the serialized key pair (including the private key)
	/// in PKCS#8 format in DER
	///
	/// Panics if called on a remote key pair.
	pub fn serialized_der(&self) -> &[u8] {
		if let KeyPairKind::Remote(_) = self.kind {
			panic!("Serializing a remote key pair is not supported")
		}

		&self.serialized_der
	}

	/// Access the remote key pair if it is a remote one
	pub fn as_remote(&self) -> Option<&(dyn RemoteKeyPair + Send + Sync)> {
		if let KeyPairKind::Remote(remote) = &self.kind {
			Some(remote.as_ref())
		} else {
			None
		}
	}

	/// Serializes the key pair (including the private key) in PKCS#8 format in PEM
	#[cfg(feature = "pem")]
	pub fn serialize_pem(&self) -> String {
		let contents = self.serialize_der();
		let p = Pem::new("PRIVATE KEY", contents);
		pem::encode_config(&p, ENCODE_CONFIG)
	}
}

impl TryFrom<&[u8]> for KeyPair {
	type Error = Error;

	fn try_from(pkcs8: &[u8]) -> Result<KeyPair, Error> {
		let (kind, alg) = KeyPair::from_raw(pkcs8)?;
		Ok(KeyPair {
			kind,
			alg,
			serialized_der: pkcs8.to_vec(),
		})
	}
}

impl TryFrom<Vec<u8>> for KeyPair {
	type Error = Error;

	fn try_from(pkcs8: Vec<u8>) -> Result<KeyPair, Error> {
		let (kind, alg) = KeyPair::from_raw(pkcs8.as_slice())?;
		Ok(KeyPair {
			kind,
			alg,
			serialized_der: pkcs8,
		})
	}
}

impl PublicKeyData for KeyPair {
	fn alg(&self) -> &SignatureAlgorithm {
		self.alg
	}
	fn raw_bytes(&self) -> &[u8] {
		match &self.kind {
			KeyPairKind::Ec(kp) => kp.public_key().as_ref(),
			KeyPairKind::Ed(kp) => kp.public_key().as_ref(),
			KeyPairKind::Rsa(kp, _) => kp.public_key().as_ref(),
			KeyPairKind::Remote(kp) => kp.public_key(),
		}
	}
}

/// A private key that is not directly accessible, but can be used to sign messages
///
/// Trait objects based on this trait can be passed to the [`KeyPair::from_remote`] function for generating certificates
/// from a remote and raw private key, for example an HSM.
pub trait RemoteKeyPair {
	/// Returns the public key of this key pair in the binary format as in [`KeyPair::public_key_raw`]
	fn public_key(&self) -> &[u8];

	/// Signs `msg` using the selected algorithm
	fn sign(&self, msg: &[u8]) -> Result<Vec<u8>, Error>;

	/// Reveals the algorithm to be used when calling `sign()`
	fn algorithm(&self) -> &'static SignatureAlgorithm;
}

impl<T> ExternalError<T> for Result<T, ring_error::KeyRejected> {
	fn _err(self) -> Result<T, Error> {
		self.map_err(|e| Error::RingKeyRejected(e.to_string()))
	}
}

impl<T> ExternalError<T> for Result<T, ring_error::Unspecified> {
	fn _err(self) -> Result<T, Error> {
		self.map_err(|_| Error::RingUnspecified)
	}
}

#[cfg(feature = "pem")]
impl<T> ExternalError<T> for Result<T, pem::PemError> {
	fn _err(self) -> Result<T, Error> {
		self.map_err(|e| Error::PemError(e.to_string()))
	}
}

pub(crate) trait PublicKeyData {
	fn alg(&self) -> &SignatureAlgorithm;

	fn raw_bytes(&self) -> &[u8];

	fn serialize_public_key_der(&self, writer: DERWriter) {
		writer.write_sequence(|writer| {
			self.alg().write_oids_sign_alg(writer.next());
			let pk = self.raw_bytes();
			writer.next().write_bitvec_bytes(&pk, pk.len() * 8);
		})
	}
}

#[cfg(test)]
mod test {
	use super::*;

	use crate::ring_like::rand::SystemRandom;
	use crate::ring_like::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

	#[test]
	fn test_algorithm() {
		let rng = SystemRandom::new();
		let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
		let der = pkcs8.as_ref().to_vec();

		let key_pair = KeyPair::from_der(&der).unwrap();
		assert_eq!(key_pair.algorithm(), &PKCS_ECDSA_P256_SHA256);
	}
}
