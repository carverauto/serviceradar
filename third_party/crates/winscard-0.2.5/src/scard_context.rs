use alloc::borrow::{Cow, ToOwned};
use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;
use alloc::{format, vec};

use picky::key::PrivateKey;
use picky_asn1_x509::{PublicKey, SubjectPublicKeyInfo};
use uuid::Uuid;

use crate::scard::{SmartCard, SUPPORTED_CONNECTION_PROTOCOL};
use crate::winscard::{
    CurrentState, DeviceTypeId, Icon, Protocol, ProviderId, ReaderState, ScardConnectData, ShareMode, WinScardContext,
};
use crate::{Error, ErrorKind, WinScardResult};

/// https://learn.microsoft.com/en-us/windows/win32/api/winscard/nf-winscard-scardgetstatuschangew
/// To be notified of the arrival of a new smart card reader,
/// set the szReader member of a SCARD_READERSTATE structure to "\\?PnP?\Notification",
const NEW_READER_NOTIFICATION: &str = "\\\\?PnP?\\Notification";

/// Default name of the emulated smart card.
pub const DEFAULT_CARD_NAME: &str = "Sspi-rs emulated smart card";
/// Default CSP name.
pub const MICROSOFT_DEFAULT_CSP: &str = "Microsoft Base Smart Card Crypto Provider";
/// Default KSP name.
pub const MICROSOFT_DEFAULT_KSP: &str = "Microsoft Smart Card Key Storage Provider";
/// Default smart card driver location.
pub const MICROSOFT_SCARD_DRIVER_LOCATION: &str = "msclmd.dll\0";

/// Describes a smart card reader.
#[derive(Debug, Clone)]
pub struct Reader<'a> {
    /// Reader name.
    pub name: Cow<'a, str>,
    /// Reader icon buff.
    pub icon: Icon<'a>,
    /// Device Type Id.
    pub device_type_id: DeviceTypeId,
}

/// Describes smart card info used for the smart card creation.
#[derive(Debug, Clone)]
pub struct SmartCardInfo<'a> {
    /// Container name which stores the certificate along with its private key.
    pub container_name: Cow<'a, str>,
    /// Smart card PIN code.
    pub pin: Vec<u8>,
    /// DER-encoded smart card certificate.
    pub auth_cert_der: Vec<u8>,
    /// Encoded private key (pem).
    pub auth_pk_pem: Cow<'a, str>,
    /// Private key.
    pub auth_pk: PrivateKey,
    /// Information about smart card reader.
    pub reader: Reader<'a>,
}

impl<'a> SmartCardInfo<'a> {
    /// Returns image bytes (BMP encoded) of the stadard Windowss Reader Icon.
    pub fn reader_icon() -> &'static [u8] {
        include_bytes!("../assets/reader_icon.bmp")
    }

    /// Tries to create [SmartCardInfo] structure based on environment variables.
    /// Required environment variables are listed in the `env` module of this crate.
    #[cfg(feature = "std")]
    pub fn try_from_env() -> WinScardResult<Self> {
        use crate::env::{
            auth_cert_from_env, container_name, private_key_from_env, WINSCARD_PIN_ENV, WINSCARD_READER_NAME_ENV,
        };

        let container_name = container_name()?.into();
        let reader_name: Cow<'_, str> = env!(WINSCARD_READER_NAME_ENV)?.into();
        let pin = env!(WINSCARD_PIN_ENV)?.into();

        let auth_cert_der = auth_cert_from_env()?.to_der()?;
        let (raw_private_key, private_key) = private_key_from_env()?;

        // Standard Windows Reader Icon
        let icon: &[u8] = Self::reader_icon();
        let reader: Reader<'_> = Reader {
            name: reader_name,
            icon: Icon::from(icon),
            device_type_id: DeviceTypeId::Tpm,
        };

        Ok(Self {
            container_name,
            pin,
            auth_cert_der,
            auth_pk_pem: raw_private_key.into(),
            auth_pk: private_key,
            reader,
        })
    }

    /// Creates a new [ScardContext] based on the provided data.
    pub fn new(
        container_name: Cow<'a, str>,
        reader_name: Cow<'a, str>,
        pin: Vec<u8>,
        auth_cert_der: Vec<u8>,
        auth_pk_pem: Cow<'a, str>,
        auth_pk: PrivateKey,
    ) -> Self {
        // Standard Windows Reader Icon
        let icon: &[u8] = Self::reader_icon();
        let reader: Reader<'_> = Reader {
            name: reader_name,
            icon: Icon::from(icon),
            device_type_id: DeviceTypeId::Tpm,
        };
        SmartCardInfo {
            container_name,
            pin,
            auth_cert_der,
            auth_pk_pem,
            auth_pk,
            reader,
        }
    }
}

/// Represents the resource manager context (the scope).
///
/// Currently, we support only one smart card per smart card context.
#[derive(Debug, Clone)]
pub struct ScardContext<'a> {
    smart_card_info: SmartCardInfo<'a>,
    cache: BTreeMap<String, Vec<u8>>,
}

impl<'a> ScardContext<'a> {
    /// Creates a new smart card based on the list of smart card readers
    pub fn new(smart_card_info: SmartCardInfo<'a>) -> WinScardResult<Self> {
        // Freshness values may vary at different points in time.
        // We do not need to change them in runtime, so we hardcode them here.
        // Those values do not mean anything special. They are just extracted from the real TPM smart card.
        const PIN_FRESHNESS: [u8; 2] = [0x00, 0x00];
        const CONTAINER_FRESHNESS: [u8; 2] = [0x01, 0x00];
        const FILE_FRESHNESS: [u8; 2] = [0x0b, 0x00];

        // The following header is formed based on the extracted information from the Windows Smart Card Minidriver (`msclmd.dll`).
        // Do not change it unless you know what you are doing.
        // A broken cache will break the entire authentication.
        const CACHE_ITEM_HEADER: [u8; 6] = {
            let mut header = [0; 6];

            // reference: msclmd!I_GetPIVCache
            header[0] = 1;
            header[1] = PIN_FRESHNESS[1];
            header[2] = CONTAINER_FRESHNESS[0] + 1;
            header[3] = CONTAINER_FRESHNESS[1];
            header[4] = FILE_FRESHNESS[0] + 1;
            header[5] = FILE_FRESHNESS[1];

            header
        };

        let mut cache = BTreeMap::new();
        cache.insert("Cached_CardProperty_Read Only Mode_0".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&4_u32.to_le_bytes());
            // false
            value.extend_from_slice(&0_u32.to_le_bytes());

            value
        });
        cache.insert("Cached_CardProperty_Cache Mode_0".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&4_u32.to_le_bytes());
            // true
            value.extend_from_slice(&1_u32.to_le_bytes());

            value
        });
        cache.insert("Cached_CardProperty_Supports Windows x.509 Enrollment_0".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&4_u32.to_le_bytes());
            // true
            value.extend_from_slice(&1_u32.to_le_bytes());

            value
        });
        cache.insert("Cached_GeneralFile/mscp/cmapfile".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len: size_of<CONTAINER_MAP_RECORD>()
            // https://github.com/selfrender/Windows-Server-2003/blob/5c6fe3db626b63a384230a1aa6b92ac416b0765f/ds/security/csps/wfsccsp/inc/basecsp.h#L104-L110
            value.extend_from_slice(&86_u32.to_le_bytes());
            // CONTAINER_MAP_RECORD:
            let container = smart_card_info
                .container_name
                .as_ref()
                .encode_utf16()
                .chain(core::iter::once(0))
                .flat_map(|v| v.to_le_bytes())
                .collect::<Vec<_>>();
            value.extend_from_slice(&container); // wszGuid
            value.extend_from_slice(&[3, 0]); // bFlags
            value.extend_from_slice(&[0, 0]); // wSigKeySizeBits
            value.extend_from_slice(&[0, 8]); // wKeyExchangeKeySizeBits

            value
        });
        cache.insert("Cached_CardmodFile\\Cached_CMAPFile".into(), {
            // CONTAINER_MAP_RECORD:
            let mut value = smart_card_info
                .container_name
                .as_ref()
                .encode_utf16()
                .chain(core::iter::once(0))
                .flat_map(|v| v.to_le_bytes())
                .collect::<Vec<_>>(); // wszGuid
            value.extend_from_slice(&[3, 0]); // bFlags
            value.extend_from_slice(&[0, 0]); // wSigKeySizeBits
            value.extend_from_slice(&[0, 8]); // wKeyExchangeKeySizeBits

            value
        });
        cache.insert("Cached_ContainerProperty_PIN Identifier_0".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&4_u32.to_le_bytes());
            // PIN identifier
            value.extend_from_slice(&1_u32.to_le_bytes());

            value
        });
        cache.insert("Cached_ContainerInfo_00".into(), {
            // Note. We can hardcode lengths values in this cache item because we support only 2048 RSA keys.
            // RSA 4096 is not defined in the specification so we don't support it.
            // https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-73-4.pdf#page=34
            // 5.3 Cryptographic Mechanism Identifiers
            // '07' - RSA 2048

            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len (precalculated)
            value.extend_from_slice(&292_u32.to_le_bytes());

            value.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x14, 0x01, 0x00, 0x00]); // container info header

            // https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/ns-wincrypt-publickeystruc
            // PUBLICKEYSTRUC
            value.push(0x06); // bType = PUBLICKEYBLOB
            value.push(0x02); // bVersion = 0x2
            value.extend_from_slice(&[0x00, 0x00]); // reserved
            value.extend_from_slice(&[0x00, 0xa4, 0x00, 0x00]); // aiKeyAlg = CALG_RSA_KEYX

            // https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/ns-wincrypt-rsapubkey
            // RSAPUBKEY
            value.extend_from_slice(b"RSA1"); // magic = RSA1
            value.extend_from_slice(&2048_u32.to_le_bytes()); // bitlen = 2048

            // let pub_key = smart_cards_info.
            let public_key = smart_card_info
                .auth_pk
                .to_public_key()
                .expect("RSA private key to public key");
            let public_key: &SubjectPublicKeyInfo = public_key.as_ref();
            let (modulus, public_exponent) = match &public_key.subject_public_key {
                PublicKey::Rsa(rsa) => (
                    {
                        let mut modulus = rsa.0.modulus.to_vec();
                        modulus.reverse();
                        modulus.resize(256, 0);
                        modulus
                    },
                    {
                        let mut pub_exp = rsa.0.public_exponent.to_vec();
                        pub_exp.reverse();
                        pub_exp.resize(4, 0);
                        pub_exp
                    },
                ),
                _ => {
                    return Err(Error::new(
                        ErrorKind::UnsupportedFeature,
                        "only RSA 2048 keys are supported",
                    ))
                }
            };

            value.extend_from_slice(&public_exponent); // pubexp
            value.extend_from_slice(&modulus); // public key

            value
        });
        cache.insert("Cached_GeneralFile/mscp/kxc00".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);

            let mut compressed_cert = vec![0; smart_card_info.auth_cert_der.len()];
            let compressed = crate::compression::compress_cert(&smart_card_info.auth_cert_der, &mut compressed_cert)?;

            let total_value_len =
                (compressed.len() + 2 /* unknown flags */ + 2/* uncompressed certificate len */) as u32;
            value.extend_from_slice(&total_value_len.to_le_bytes());

            value.extend_from_slice(&[0x01, 0x00]); // flags that specify that the certificate is compressed
            value.extend_from_slice(&(smart_card_info.auth_cert_der.len() as u16).to_le_bytes()); // uncompressed certificate data len
            value.extend_from_slice(&compressed_cert);

            value
        });
        cache.insert("Cached_CardProperty_Capabilities_0".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&12_u32.to_le_bytes());
            // Here should be the CARD_CAPABILITIES struct but the actual extracted data is different.
            // So, we just insert the extracted data from a real smart card.
            // Card capabilities:
            value.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]);

            value
        });

        cache.insert("Cached_CardProperty_Key Sizes_2".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&20_u32.to_le_bytes());
            // https://learn.microsoft.com/en-us/previous-versions/windows/desktop/secsmart/card-key-sizes
            value.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]);
            value.extend_from_slice(&[
                1, 0, 0, 0, // dwVersion = 1
                0, 4, 0, 0, // dwMinimumBitlen = 1024
                0, 4, 0, 0, // dwDefaultBitlen = 1048
                0, 8, 0, 0, // dwMaximumBitlen = 2048
                0, 4, 0, 0, // dwIncrementalBitlen = 1024
            ]);

            value
        });

        cache.insert("Cached_CardProperty_Key Sizes_1".into(), {
            let mut value = CACHE_ITEM_HEADER.to_vec();
            // unkown flags
            value.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
            // actual data len
            value.extend_from_slice(&20_u32.to_le_bytes());
            // https://learn.microsoft.com/en-us/previous-versions/windows/desktop/secsmart/card-key-sizes
            value.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]);
            value.extend_from_slice(&[
                1, 0, 0, 0, // dwVersion = 1
                0, 4, 0, 0, // dwMinimumBitlen = 1024
                0, 4, 0, 0, // dwDefaultBitlen = 1048
                0, 8, 0, 0, // dwMaximumBitlen = 2048
                0, 4, 0, 0, // dwIncrementalBitlen = 1024
            ]);

            value
        });

        cache.insert(
            "Cached_CardmodFile\\Cached_Pin_Freshness".into(),
            PIN_FRESHNESS.to_vec(),
        );
        cache.insert(
            "Cached_CardmodFile\\Cached_File_Freshness".into(),
            FILE_FRESHNESS.to_vec(),
        );
        cache.insert(
            "Cached_CardmodFile\\Cached_Container_Freshness".into(),
            CONTAINER_FRESHNESS.to_vec(),
        );

        Ok(Self { smart_card_info, cache })
    }

    /// Returns available smart card reader name.
    pub fn reader_name(&self) -> &str {
        self.smart_card_info.reader.name.as_ref()
    }
}

impl WinScardContext for ScardContext<'_> {
    fn connect(
        &self,
        reader_name: &str,
        _share_mode: ShareMode,
        _protocol: Option<Protocol>,
    ) -> WinScardResult<ScardConnectData> {
        if self.smart_card_info.reader.name != reader_name {
            return Err(Error::new(
                ErrorKind::UnknownReader,
                format!("reader {:?} not found", reader_name),
            ));
        }

        Ok(ScardConnectData {
            handle: Box::new(SmartCard::new(
                Cow::Owned(reader_name.to_owned()),
                self.smart_card_info.pin.clone(),
                self.smart_card_info.auth_cert_der.clone(),
                self.smart_card_info.auth_pk.clone(),
            )?),
            protocol: SUPPORTED_CONNECTION_PROTOCOL,
        })
    }

    fn list_readers(&self) -> WinScardResult<Vec<Cow<'_, str>>> {
        Ok(vec![self.smart_card_info.reader.name.clone()])
    }

    fn device_type_id(&self, reader_name: &str) -> WinScardResult<DeviceTypeId> {
        if self.smart_card_info.reader.name != reader_name {
            return Err(Error::new(
                ErrorKind::UnknownReader,
                format!("reader {:?} not found", reader_name),
            ));
        }

        Ok(self.smart_card_info.reader.device_type_id)
    }

    fn reader_icon(&self, reader_name: &str) -> WinScardResult<Icon<'_>> {
        if self.smart_card_info.reader.name != reader_name {
            return Err(Error::new(
                ErrorKind::UnknownReader,
                format!("reader {:?} not found", reader_name),
            ));
        }

        Ok(self.smart_card_info.reader.icon.clone())
    }

    fn is_valid(&self) -> bool {
        true
    }

    fn read_cache(&self, _: Uuid, _: u32, key: &str) -> WinScardResult<Cow<'_, [u8]>> {
        self.cache
            .get(key)
            .map(|item| Cow::Borrowed(item.as_slice()))
            .ok_or_else(|| Error::new(ErrorKind::CacheItemNotFound, format!("Cache item '{}' not found", key)))
    }

    fn write_cache(&mut self, _: Uuid, _: u32, key: String, value: Vec<u8>) -> WinScardResult<()> {
        self.cache.insert(key, value);

        Ok(())
    }

    fn list_reader_groups(&self) -> WinScardResult<Vec<Cow<'_, str>>> {
        // We don't support configuring or introducing reader groups. So, we just return hardcoded values.
        //
        // https://learn.microsoft.com/en-us/windows/win32/api/winscard/nf-winscard-scardlistreadergroupsw
        // SCARD_DEFAULT_READERS: TEXT("SCard$DefaultReaders\000")
        // Default group to which all readers are added when introduced into the system.
        Ok(vec![Cow::Borrowed("SCard$DefaultReaders\u{0}00")])
    }

    fn cancel(&mut self) -> WinScardResult<()> {
        // https://learn.microsoft.com/en-us/windows/win32/api/winscard/nf-winscard-scardcancel
        // The only requests that you can cancel are those that require waiting for external action by the smart card or user.
        //
        // We don't have any external actions, so we just return success.
        Ok(())
    }

    fn get_status_change(&mut self, _timeout: u32, reader_states: &mut [ReaderState<'_>]) -> WinScardResult<()> {
        use crate::ATR;

        let supported_readers = self.list_readers()?;

        for reader_state in reader_states {
            if supported_readers.contains(&reader_state.reader_name) {
                reader_state.event_state = CurrentState::SCARD_STATE_UNNAMED_CONSTANT
                    | CurrentState::SCARD_STATE_INUSE
                    | CurrentState::SCARD_STATE_PRESENT
                    | CurrentState::SCARD_STATE_CHANGED;
                reader_state.atr[0..ATR.len()].copy_from_slice(&ATR);
                reader_state.atr_len = ATR.len();
            } else if reader_state.reader_name.as_ref() == NEW_READER_NOTIFICATION {
                reader_state.event_state = CurrentState::SCARD_STATE_UNNAMED_CONSTANT;
            } else {
                error!(?reader_state.reader_name, "Unsupported reader");
            }
        }

        Ok(())
    }

    fn list_cards(
        &self,
        _atr: Option<&[u8]>,
        _required_interfaces: Option<&[Uuid]>,
    ) -> WinScardResult<Vec<Cow<'_, str>>> {
        // we have only one smart card with only one default name
        Ok(vec![DEFAULT_CARD_NAME.into()])
    }

    fn get_card_type_provider_name(&self, _card_name: &str, provider_id: ProviderId) -> WinScardResult<Cow<'_, str>> {
        Ok(match provider_id {
            ProviderId::Primary => {
                return Err(Error::new(
                    ErrorKind::UnsupportedFeature,
                    "ProviderId::Primary is not supported for emulated smart card",
                ))
            }
            ProviderId::Csp => MICROSOFT_DEFAULT_CSP.into(),
            ProviderId::Ksp => MICROSOFT_DEFAULT_KSP.into(),
            ProviderId::CardModule => MICROSOFT_SCARD_DRIVER_LOCATION.into(),
        })
    }
}
