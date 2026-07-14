use oid::ObjectIdentifier;
use picky::oids;
use picky_asn1::wrapper::{
    ExplicitContextTag0, ExplicitContextTag1, ExplicitContextTag2, ExplicitContextTag3, IntegerAsn1,
    ObjectIdentifierAsn1, OctetStringAsn1, Optional,
};
use picky_asn1_der::Asn1RawDer;
use picky_krb::constants::gss_api::{ACCEPT_INCOMPLETE, AP_REP_TOKEN_ID, TGT_REP_TOKEN_ID};
use picky_krb::constants::key_usages::{ACCEPTOR_SIGN, AP_REP_ENC};
use picky_krb::constants::types::{AP_REP_MSG_TYPE, TGT_REP_MSG_TYPE};
use picky_krb::crypto::aes::{checksum_sha_aes, AesSize};
use picky_krb::data_types::{
    EncApRepPart, EncApRepPartInner, EncryptedData, EncryptionKey, KerberosTime, Microseconds, Ticket,
};
use picky_krb::gss_api::{ApplicationTag0, KrbMessage, MechType, MicToken, NegTokenTarg, NegTokenTarg1};
use picky_krb::messages::{ApRep, ApRepInner, TgtRep};

use crate::kerberos::{EncryptionParams, DEFAULT_ENCRYPTION_TYPE};
use crate::{Result, KERBEROS_VERSION};

pub(super) fn generate_neg_token_targ(mech_type: ObjectIdentifier, tgt_rep: Option<TgtRep>) -> Result<NegTokenTarg1> {
    let response_token = tgt_rep
        .map(|tgt_rep| {
            Result::Ok(ExplicitContextTag2::from(OctetStringAsn1::from(
                picky_asn1_der::to_vec(&ApplicationTag0(KrbMessage {
                    krb5_oid: ObjectIdentifierAsn1::from(oids::krb5_user_to_user()),
                    krb5_token_id: TGT_REP_TOKEN_ID,
                    krb_msg: tgt_rep,
                }))?,
            )))
        })
        .transpose()?;
    Ok(NegTokenTarg1::from(NegTokenTarg {
        neg_result: Optional::from(Some(ExplicitContextTag0::from(Asn1RawDer(ACCEPT_INCOMPLETE.to_vec())))),
        supported_mech: Optional::from(Some(ExplicitContextTag1::from(MechType::from(mech_type)))),
        response_token: Optional::from(response_token),
        mech_list_mic: Optional::from(None),
    }))
}

pub(super) fn generate_ap_rep(
    session_key: &[u8],
    ctime: KerberosTime,
    cusec: Microseconds,
    seq_number: Vec<u8>,
    enc_params: &EncryptionParams,
) -> Result<ApRep> {
    let encryption_type = enc_params.encryption_type.as_ref().unwrap_or(&DEFAULT_ENCRYPTION_TYPE);

    let enc_part = EncApRepPart::from(EncApRepPartInner {
        ctime: ExplicitContextTag0::from(ctime),
        cusec: ExplicitContextTag1::from(cusec),
        subkey: Optional::from(enc_params.sub_session_key.as_ref().map(|sub_key| {
            ExplicitContextTag2::from(EncryptionKey {
                key_type: ExplicitContextTag0::from(IntegerAsn1::from(vec![encryption_type.into()])),
                key_value: ExplicitContextTag1::from(OctetStringAsn1::from(sub_key.clone())),
            })
        })),
        seq_number: Optional::from(Some(ExplicitContextTag3::from(IntegerAsn1::from(seq_number)))),
    });

    let cipher = encryption_type.cipher();
    let enc_data = cipher.encrypt(session_key, AP_REP_ENC, &picky_asn1_der::to_vec(&enc_part)?)?;

    Ok(ApRep::from(ApRepInner {
        pvno: ExplicitContextTag0::from(IntegerAsn1::from(vec![KERBEROS_VERSION])),
        msg_type: ExplicitContextTag1::from(IntegerAsn1::from(vec![AP_REP_MSG_TYPE])),
        enc_part: ExplicitContextTag2::from(EncryptedData {
            etype: ExplicitContextTag0::from(IntegerAsn1::from(vec![encryption_type.into()])),
            kvno: Optional::from(None),
            cipher: ExplicitContextTag2::from(OctetStringAsn1::from(enc_data)),
        }),
    }))
}

pub(super) fn generate_final_neg_token_targ(
    mech_id: ObjectIdentifier,
    ap_rep: ApRep,
    mic: Vec<u8>,
) -> Result<NegTokenTarg1> {
    let krb_blob = ApplicationTag0(KrbMessage {
        krb5_oid: ObjectIdentifierAsn1::from(mech_id),
        krb5_token_id: AP_REP_TOKEN_ID,
        krb_msg: ap_rep,
    });

    Ok(NegTokenTarg1::from(NegTokenTarg {
        neg_result: Optional::from(Some(ExplicitContextTag0::from(Asn1RawDer(ACCEPT_INCOMPLETE.to_vec())))),
        supported_mech: Optional::from(None),
        response_token: Optional::from(Some(ExplicitContextTag2::from(OctetStringAsn1::from(
            picky_asn1_der::to_vec(&krb_blob)?,
        )))),
        mech_list_mic: Optional::from(Some(ExplicitContextTag3::from(OctetStringAsn1::from(mic)))),
    }))
}

pub(super) fn generate_mic_token(seq_number: u64, mut payload: Vec<u8>, session_key: &[u8]) -> Result<Vec<u8>> {
    let mut mic_token = MicToken::with_acceptor_flags().with_seq_number(seq_number);

    payload.extend_from_slice(&mic_token.header());

    mic_token.set_checksum(checksum_sha_aes(
        session_key,
        ACCEPTOR_SIGN,
        &payload,
        &AesSize::Aes256,
    )?);

    let mut mic_token_raw = Vec::new();
    mic_token.encode(&mut mic_token_raw)?;

    Ok(mic_token_raw)
}

pub(super) fn generate_tgt_rep(ticket: Ticket) -> TgtRep {
    TgtRep {
        pvno: ExplicitContextTag0::from(IntegerAsn1::from(vec![KERBEROS_VERSION])),
        msg_type: ExplicitContextTag1::from(IntegerAsn1::from(vec![TGT_REP_MSG_TYPE])),
        ticket: ExplicitContextTag2::from(ticket),
    }
}
