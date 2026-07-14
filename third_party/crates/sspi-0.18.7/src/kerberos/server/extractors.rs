use oid::ObjectIdentifier;
use picky::oids;
use picky_asn1::wrapper::ExplicitContextTag1;
use picky_krb::constants::gss_api::{ACCEPT_COMPLETE, AP_REQ_TOKEN_ID};
use picky_krb::constants::key_usages::{AP_REQ_AUTHENTICATOR, TICKET_REP};
use picky_krb::constants::types::{NT_ENTERPRISE, NT_PRINCIPAL};
use picky_krb::crypto::CipherSuite;
use picky_krb::data_types::{Authenticator, EncTicketPart, KerberosStringAsn1, PrincipalName};
use picky_krb::gss_api::{
    ApplicationTag0, GssApiNegInit, KrbMessage, MechTypeList, NegTokenInit, NegTokenTarg, NegTokenTarg1,
};
use picky_krb::messages::{ApReq, TgtReq};

use crate::{Error, ErrorKind, Result, Username};

/// Extract TGT request and mech types from the first token returned by the Kerberos client.
#[instrument(ret, level = "trace")]
pub(super) fn decode_initial_neg_init(data: &[u8]) -> Result<(Option<TgtReq>, MechTypeList)> {
    let token: ApplicationTag0<GssApiNegInit> = picky_asn1_der::from_bytes(data)?;
    let NegTokenInit {
        mech_types,
        req_flags: _,
        mech_token,
        mech_list_mic: _,
    } = token.0.neg_token_init.0;

    let mech_types = mech_types
        .0
        .ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidToken,
                "mech_types is missing in GssApiNegInit message",
            )
        })?
        .0;

    let tgt_req = if let Some(mech_token) = mech_token.0 {
        let encoded_tgt_req = mech_token.0 .0;
        let neg_token_init = KrbMessage::<TgtReq>::decode_application_krb_message(&encoded_tgt_req)?;

        let token_oid = &neg_token_init.0.krb5_oid.0;
        let krb5_u2u = oids::krb5_user_to_user();
        if *token_oid != krb5_u2u {
            return Err(Error::new(
                ErrorKind::InvalidToken,
                format!(
                    "invalid oid inside mech_token: expected krb5 u2u ({:?}) but got {:?}",
                    krb5_u2u, token_oid
                ),
            ));
        }

        Some(neg_token_init.0.krb_msg)
    } else {
        None
    };

    Ok((tgt_req, mech_types))
}

/// Decodes incoming SPNEGO message and extracts [ApReq] Kerberos message.
pub(super) fn decode_neg_ap_req(data: &[u8]) -> Result<ApReq> {
    let neg_token_targ: ExplicitContextTag1<NegTokenTarg> = picky_asn1_der::from_bytes(data)?;

    let krb_message = KrbMessage::<ApReq>::decode_application_krb_message(
        &neg_token_targ
            .0
            .response_token
            .0
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::InvalidToken,
                    "response_token is missing in NegTokenTarg message",
                )
            })?
            .0
             .0,
    )?
    .0;

    if krb_message.krb5_token_id != AP_REQ_TOKEN_ID {
        return Err(Error::new(
            ErrorKind::InvalidToken,
            format!(
                "invalid kerberos token id: expected {:?} but got {:?}",
                AP_REQ_TOKEN_ID, krb_message.krb5_token_id
            ),
        ));
    }

    Ok(krb_message.krb_msg)
}

/// Decrypts the [ApReq] ticket and returns decoded encrypted part of the ticket.
pub(super) fn decrypt_ap_req_ticket(key: &[u8], ap_req: &ApReq) -> Result<EncTicketPart> {
    let ticket_enc_part = &ap_req.0.ticket.0 .0.enc_part.0;
    let cipher = CipherSuite::try_from(ticket_enc_part.etype.0 .0.as_slice())?.cipher();

    let encoded_enc_part = cipher.decrypt(key, TICKET_REP, &ticket_enc_part.cipher.0 .0)?;

    Ok(picky_asn1_der::from_bytes(&encoded_enc_part)?)
}

/// Decrypts [ApReq] Authenticator and returns decoded authenticator.
pub(super) fn decrypt_ap_req_authenticator(session_key: &[u8], ap_req: &ApReq) -> Result<Authenticator> {
    let encrypted_authenticator = &ap_req.0.authenticator.0;
    let cipher = CipherSuite::try_from(encrypted_authenticator.etype.0 .0.as_slice())?.cipher();

    let encoded_authenticator =
        cipher.decrypt(session_key, AP_REQ_AUTHENTICATOR, &encrypted_authenticator.cipher.0 .0)?;

    Ok(picky_asn1_der::from_bytes(&encoded_authenticator)?)
}

/// Validated client final [NegTokenTarg1] message and extract its MIC token.
///
/// **Note**: the input client message should be last message in the _authentication_ sequence.
pub(super) fn extract_client_mic_token(data: &[u8]) -> Result<Vec<u8>> {
    let neg_token_targ: NegTokenTarg1 = picky_asn1_der::from_bytes(data)?;
    let NegTokenTarg {
        neg_result,
        supported_mech: _,
        response_token: _,
        mech_list_mic,
    } = neg_token_targ.0;

    let neg_result = neg_result
        .0
        .ok_or_else(|| Error::new(ErrorKind::InvalidToken, "neg_result is missing in NegTokenTarg message"))?
        .0
         .0;
    if neg_result != ACCEPT_COMPLETE {
        return Err(Error::new(
            ErrorKind::InvalidToken,
            "invalid neg result: expected accept_complete",
        ));
    }

    let mic_token = mech_list_mic
        .0
        .ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidToken,
                "mech_list_mic is missing in NegTokenTarg message",
            )
        })?
        .0
         .0;

    Ok(mic_token)
}

/// Selects the preferred Kerberos oid.
///
/// 1.2.840.48018.1.2.2 (MS KRB5 - Microsoft Kerberos 5) is preferred over 1.2.840.113554.1.2.2 (KRB5 - Kerberos 5).
pub(super) fn select_mech_type(mech_list: &MechTypeList) -> Result<ObjectIdentifier> {
    let ms_krb5 = oids::ms_krb5();
    if mech_list.0.iter().any(|mech_type| mech_type.0 == ms_krb5) {
        return Ok(ms_krb5);
    }

    let krb5 = oids::krb5();
    if mech_list.0.iter().any(|mech_type| mech_type.0 == krb5) {
        return Ok(krb5);
    }

    Err(Error::new(
        ErrorKind::InvalidToken,
        "invalid mech type list: Kerberos protocol is not present",
    ))
}

/// Constructs [Username] from the client's [PrincipalName] and realm.
pub(super) fn client_upn(cname: &PrincipalName, crealm: &KerberosStringAsn1) -> Result<Username> {
    let username = cname
        .name_string
        .0
         .0
        .first()
        .map(|name| name.to_string())
        .ok_or_else(|| Error::new(ErrorKind::InvalidToken, "missing cname value in token"))?;

    let name_type = &cname.name_type.0 .0;
    if name_type == &[NT_PRINCIPAL] {
        Ok(Username::new_upn(
            &username,
            &crealm.0.to_string().to_ascii_lowercase(),
        )?)
    } else if name_type == &[NT_ENTERPRISE] {
        Ok(Username::parse(&username)?)
    } else {
        Err(Error::new(
            ErrorKind::InvalidToken,
            format!("unsupported principal name type: {:?}", name_type),
        ))
    }
}
