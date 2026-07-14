mod as_exchange;
mod change_password;
pub mod extractors;
pub mod generators;

use std::io::Write;

pub(crate) use as_exchange::as_exchange;
pub use change_password::change_password;
use picky_asn1_x509::oids;
use picky_krb::constants::gss_api::AUTHENTICATOR_CHECKSUM_TYPE;
use picky_krb::constants::key_usages::ACCEPTOR_SIGN;
use picky_krb::crypto::CipherSuite;
use picky_krb::data_types::{KrbResult, ResultExt};
use picky_krb::gss_api::NegTokenTarg1;
use picky_krb::messages::TgsRep;
use rand::prelude::StdRng;
use rand::{RngCore, SeedableRng};

use self::extractors::{
    extract_ap_rep_from_neg_token_targ, extract_encryption_params_from_as_rep, extract_seq_number_from_ap_rep,
    extract_session_key_from_tgs_rep, extract_sub_session_key_from_ap_rep, extract_tgt_ticket_with_oid,
};
use self::generators::{
    generate_ap_rep, generate_ap_req, generate_as_req_kdc_body, generate_authenticator, generate_neg_ap_req,
    generate_neg_token_init, generate_tgs_req, get_client_principal_name_type, get_client_principal_realm,
    get_mech_list, ChecksumOptions, ChecksumValues, EncKey, GenerateAsPaDataOptions, GenerateAsReqOptions,
    GenerateAuthenticatorOptions, GenerateTgsReqOptions, GssFlags,
};
use crate::channel_bindings::ChannelBindings;
use crate::generator::YieldPointLocal;
use crate::kerberos::pa_datas::{AsRepSessionKeyExtractor, AsReqPaDataOptions};
use crate::kerberos::utils::{serialize_message, unwrap_hostname, validate_mic_token};
use crate::kerberos::{DEFAULT_ENCRYPTION_TYPE, EC, TGT_SERVICE_NAME};
use crate::utils::{generate_random_symmetric_key, parse_target_name, utf16_bytes_to_utf8_string};
use crate::{
    BufferType, ClientRequestFlags, ClientResponseFlags, CredentialsBuffers, Error, ErrorKind,
    InitializeSecurityContextResult, Kerberos, KerberosState, Result, SecurityBuffer, SecurityStatus, SspiImpl,
};

/// Indicated that the MIC token `SentByAcceptor` flag must be enabled in the incoming MIC token.
const SENT_BY_ACCEPTOR: u8 = 1;

/// Performs one authentication step.
///
/// The user should call this function until it returns `SecurityStatus::Ok`.
pub async fn initialize_security_context<'a>(
    client: &'a mut Kerberos,
    yield_point: &mut YieldPointLocal,
    builder: &'a mut crate::builders::FilledInitializeSecurityContext<'_, <Kerberos as SspiImpl>::CredentialsHandle>,
) -> Result<InitializeSecurityContextResult> {
    trace!(?builder);

    let status = match client.state {
        KerberosState::Negotiate => {
            let sname = if builder
                .context_requirements
                .contains(ClientRequestFlags::USE_SESSION_KEY)
            {
                let (service_name, service_principal_name) =
                    parse_target_name(builder.target_name.ok_or_else(|| {
                        Error::new(
                            ErrorKind::NoCredentials,
                            "Service target name (service principal name) is not provided",
                        )
                    })?)?;

                Some([service_name, service_principal_name])
            } else {
                None
            };

            debug!(?sname);

            let encoded_neg_token_init =
                picky_asn1_der::to_vec(&generate_neg_token_init(sname.as_ref().map(|sname| sname.as_slice()))?)?;

            let output_token = SecurityBuffer::find_buffer_mut(builder.output, BufferType::Token)?;
            output_token.buffer.write_all(&encoded_neg_token_init)?;

            client.state = KerberosState::Preauthentication;

            SecurityStatus::ContinueNeeded
        }
        KerberosState::Preauthentication => {
            let input = builder
                .input
                .as_ref()
                .ok_or_else(|| Error::new(ErrorKind::InvalidToken, "input buffers must be specified"))?;

            if let Ok(sec_buffer) =
                SecurityBuffer::find_buffer(builder.input.as_ref().unwrap(), BufferType::ChannelBindings)
            {
                client.channel_bindings = Some(ChannelBindings::from_bytes(&sec_buffer.buffer)?);
            }

            let input_token = SecurityBuffer::find_buffer(input, BufferType::Token)?;

            let (tgt_ticket, mech_id) =
                if let Some((tbt_ticket, mech_oid)) = extract_tgt_ticket_with_oid(&input_token.buffer)? {
                    (Some(tbt_ticket), mech_oid.0)
                } else {
                    (None, oids::krb5())
                };
            client.krb5_user_to_user = mech_id == oids::krb5_user_to_user();

            let credentials = builder
                .credentials_handle
                .as_ref()
                .unwrap()
                .as_ref()
                .ok_or_else(|| Error::new(ErrorKind::WrongCredentialHandle, "No credentials provided"))?;

            let (username, password, realm, cname_type) = match credentials {
                CredentialsBuffers::AuthIdentity(auth_identity) => {
                    let username = utf16_bytes_to_utf8_string(&auth_identity.user)?;
                    let domain = utf16_bytes_to_utf8_string(&auth_identity.domain)?;
                    let password = utf16_bytes_to_utf8_string(auth_identity.password.as_ref())?;

                    let realm = get_client_principal_realm(&username, &domain);
                    let cname_type = get_client_principal_name_type(&username, &domain);

                    (username, password, realm, cname_type)
                }
                #[cfg(feature = "scard")]
                CredentialsBuffers::SmartCard(smart_card) => {
                    let username = utf16_bytes_to_utf8_string(&smart_card.username)?;
                    let password = utf16_bytes_to_utf8_string(smart_card.pin.as_ref())?;

                    let realm = get_client_principal_realm(&username, "");
                    let cname_type = get_client_principal_name_type(&username, "");

                    (username, password, realm.to_uppercase(), cname_type)
                }
            };
            client.realm = Some(realm.clone());

            let mut rand = StdRng::try_from_os_rng()?;
            let options = GenerateAsReqOptions {
                realm: &realm,
                username: &username,
                cname_type,
                snames: &[TGT_SERVICE_NAME, &realm],
                // 4 = size of u32
                nonce: &rand.next_u32().to_be_bytes(),
                hostname: &unwrap_hostname(client.config.client_computer_name.as_deref())?,
                context_requirements: builder.context_requirements,
            };
            let kdc_req_body = generate_as_req_kdc_body(&options)?;

            let pa_data_options = match credentials {
                CredentialsBuffers::AuthIdentity(auth_identity) => {
                    let domain = utf16_bytes_to_utf8_string(&auth_identity.domain)?;
                    let salt = format!("{}{}", domain, username);

                    AsReqPaDataOptions::AuthIdentity(GenerateAsPaDataOptions {
                        password: &password,
                        salt: salt.as_bytes().to_vec(),
                        enc_params: client.encryption_params.clone(),
                        with_pre_auth: false,
                    })
                }
                #[cfg(feature = "scard")]
                CredentialsBuffers::SmartCard(scard_identity_buffer) => {
                    use sha1::{Digest, Sha1};

                    use crate::pku2u::generate_client_dh_parameters;
                    use crate::smartcard::SmartCard;
                    use crate::{pk_init, SmartCardIdentity};

                    let scard_identity = SmartCardIdentity::try_from(scard_identity_buffer)?;

                    let mut smart_card = SmartCard::from_credentials(&scard_identity)?;
                    let p2p_cert = scard_identity.certificate;

                    client.dh_parameters = Some(generate_client_dh_parameters(&mut rand));

                    AsReqPaDataOptions::SmartCard(Box::new(pk_init::GenerateAsPaDataOptions {
                        p2p_cert,
                        kdc_req_body: &kdc_req_body,
                        dh_parameters: client.dh_parameters.clone().unwrap(),
                        sign_data: Box::new(move |data_to_sign| {
                            let mut sha1 = Sha1::new();
                            sha1.update(data_to_sign);
                            let digest = sha1.finalize().to_vec();

                            smart_card.sign(digest)
                        }),
                        with_pre_auth: false,
                        authenticator_nonce: rand.next_u32().to_be_bytes(),
                    }))
                }
            };

            let as_rep = as_exchange(client, yield_point, &kdc_req_body, pa_data_options).await?;

            debug!("AS exchange finished successfully.");

            client.realm = Some(as_rep.0.crealm.0.to_string());

            let (encryption_type, salt) = extract_encryption_params_from_as_rep(&as_rep)?;

            let encryption_type = CipherSuite::try_from(encryption_type as usize)?;

            client.encryption_params.encryption_type = Some(encryption_type);

            let mut authenticator = generate_authenticator(GenerateAuthenticatorOptions {
                kdc_rep: &as_rep.0,
                seq_num: Some(rand.next_u32()),
                sub_key: None,
                checksum: None,
                channel_bindings: client.channel_bindings.as_ref(),
                extensions: Vec::new(),
            })?;

            let mut session_key_extractor = match credentials {
                CredentialsBuffers::AuthIdentity(_) => AsRepSessionKeyExtractor::AuthIdentity {
                    salt: &salt,
                    password: &password,
                    enc_params: &mut client.encryption_params,
                },
                #[cfg(feature = "scard")]
                CredentialsBuffers::SmartCard(_) => AsRepSessionKeyExtractor::SmartCard {
                    dh_parameters: client.dh_parameters.as_mut().unwrap(),
                    enc_params: &mut client.encryption_params,
                },
            };
            let session_key_1 = session_key_extractor.session_key(&as_rep)?;

            let service_principal = builder.target_name.ok_or_else(|| {
                Error::new(
                    ErrorKind::NoCredentials,
                    "Service target name (service principal name) is not provided",
                )
            })?;

            let mut context_requirements = builder.context_requirements;

            if client.krb5_user_to_user && !context_requirements.contains(ClientRequestFlags::USE_SESSION_KEY) {
                warn!("KRB5 U2U has been negotiated (selected by the server) but the USE_SESSION_KEY flag is not set. Forcibly turning it on...");
                context_requirements.set(ClientRequestFlags::USE_SESSION_KEY, true);
            }

            let tgs_req = generate_tgs_req(GenerateTgsReqOptions {
                realm: &as_rep.0.crealm.0.to_string(),
                service_principal,
                session_key: &session_key_1,
                ticket: as_rep.0.ticket.0,
                authenticator: &mut authenticator,
                additional_tickets: tgt_ticket.map(|ticket| vec![ticket]),
                enc_params: &client.encryption_params,
                context_requirements,
            })?;

            let response = client.send(yield_point, &serialize_message(&tgs_req)?).await?;

            if response.len() < 4 {
                return Err(Error::new(
                    ErrorKind::InternalError,
                    "the KDC reply message is too small: expected at least 4 bytes",
                ));
            }

            // first 4 bytes are message len. skipping them
            let mut d = picky_asn1_der::Deserializer::new_from_bytes(&response[4..]);
            let tgs_rep: KrbResult<TgsRep> = KrbResult::deserialize(&mut d)?;
            let tgs_rep = tgs_rep?;

            debug!("TGS exchange finished successfully");

            let session_key_2 = extract_session_key_from_tgs_rep(&tgs_rep, &session_key_1, &client.encryption_params)?;

            client.encryption_params.session_key = Some(session_key_2);

            let enc_type = client
                .encryption_params
                .encryption_type
                .as_ref()
                .unwrap_or(&DEFAULT_ENCRYPTION_TYPE);
            let authenticator_sub_key = generate_random_symmetric_key(enc_type, &mut rand);

            // the original flag is
            // GSS_C_MUTUAL_FLAG | GSS_C_REPLAY_FLAG | GSS_C_SEQUENCE_FLAG | GSS_C_CONF_FLAG | GSS_C_INTEG_FLAG
            // we want to be able to turn of sign and seal, so we leave confidentiality and integrity flags out
            let mut flags: GssFlags = builder.context_requirements.into();
            if flags.contains(GssFlags::GSS_C_DELEG_FLAG) {
                // Below are reasons why we turn off the GSS_C_DELEG_FLAG flag.
                //
                // RFC4121: The Kerberos Version 5 GSS-API. Section 4.1.1:  Authenticator Checksum
                // https://datatracker.ietf.org/doc/html/rfc4121#section-4.1.1.1
                //
                // "The length of the checksum field MUST be at least 24 octets when GSS_C_DELEG_FLAG is not set,
                // and at least 28 octets plus Dlgth octets when GSS_C_DELEG_FLAG is set."
                // Out implementation _always_ uses the 24 octets checksum and do not support Kerberos credentials delegation.
                //
                // "When delegation is used, a ticket-granting ticket will be transferred in a KRB_CRED message."
                // We do not support KRB_CRED messages. So, the GSS_C_DELEG_FLAG flags should be turned off.
                warn!("Kerberos ApReq Authenticator checksum GSS_C_DELEG_FLAG is not supported. Turning it off...");
                flags.remove(GssFlags::GSS_C_DELEG_FLAG);
            }
            debug!(?flags, "ApReq Authenticator checksum flags");

            let mut checksum_value = ChecksumValues::default();
            checksum_value.set_flags(flags);

            let authenticator_options = GenerateAuthenticatorOptions {
                kdc_rep: &tgs_rep.0,
                // The AP_REQ Authenticator sequence number should be the same as `seq_num` in the first Kerberos Wrap token generated
                // by the `encrypt_message` method. So, we set the next sequence number but do not increment the counter,
                // which will be incremented on each `encrypt_message` method call.
                seq_num: Some(client.seq_number + 1),
                sub_key: Some(EncKey {
                    key_type: enc_type.clone(),
                    key_value: authenticator_sub_key,
                }),

                checksum: Some(ChecksumOptions {
                    checksum_type: AUTHENTICATOR_CHECKSUM_TYPE.to_vec(),
                    checksum_value,
                }),
                channel_bindings: client.channel_bindings.as_ref(),
                extensions: Vec::new(),
            };

            let authenticator = generate_authenticator(authenticator_options)?;
            let encoded_auth = picky_asn1_der::to_vec(&authenticator)?;
            debug!(encoded_ap_req_authenticator = ?encoded_auth);

            let ap_req = generate_ap_req(
                tgs_rep.0.ticket.0,
                client
                    .encryption_params
                    .session_key
                    .as_ref()
                    .ok_or_else(|| Error::new(ErrorKind::InternalError, "session key is not set"))?,
                &authenticator,
                &client.encryption_params,
                context_requirements.into(),
            )?;

            let encoded_neg_ap_req = if !builder.context_requirements.contains(ClientRequestFlags::USE_DCE_STYLE) {
                // Wrap in a NegToken.
                picky_asn1_der::to_vec(&generate_neg_ap_req(ap_req, mech_id)?)?
            } else {
                // Do not wrap if the `USE_DCE_STYLE` flag is set.
                // https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-kile/190ab8de-dc42-49cf-bf1b-ea5705b7a087
                picky_asn1_der::to_vec(&ap_req)?
            };

            let output_token = SecurityBuffer::find_buffer_mut(builder.output, BufferType::Token)?;
            output_token.buffer.write_all(&encoded_neg_ap_req)?;

            client.state = KerberosState::ApExchange;

            SecurityStatus::ContinueNeeded
        }
        KerberosState::ApExchange => {
            let input = builder
                .input
                .as_ref()
                .ok_or_else(|| Error::new(ErrorKind::InvalidToken, "Input buffers must be specified"))?;
            let input_token = SecurityBuffer::find_buffer(input, BufferType::Token)?;

            if builder.context_requirements.contains(ClientRequestFlags::USE_DCE_STYLE) {
                // The `EC` field depends on the authentication type. For example, during RDP auth
                // it is equal to 0, but during RPC auth it is equal to EC.
                client.encryption_params.ec = EC;

                use picky_krb::messages::ApRep;

                let ap_rep: ApRep = picky_asn1_der::from_bytes(&input_token.buffer)?;

                let session_key = client
                    .encryption_params
                    .session_key
                    .as_ref()
                    .ok_or_else(|| Error::new(ErrorKind::InternalError, "session key is not set"))?;
                let sub_session_key =
                    extract_sub_session_key_from_ap_rep(&ap_rep, session_key, &client.encryption_params)?;
                let seq_number = extract_seq_number_from_ap_rep(&ap_rep, session_key, &client.encryption_params)?;

                trace!(?sub_session_key, "DCE AP_REP sub-session key");

                client.encryption_params.sub_session_key = Some(sub_session_key);

                let ap_rep = generate_ap_rep(session_key, seq_number, &client.encryption_params)?;
                let ap_rep = picky_asn1_der::to_vec(&ap_rep)?;

                let output_token = SecurityBuffer::find_buffer_mut(builder.output, BufferType::Token)?;
                output_token.buffer.write_all(&ap_rep)?;
            } else {
                let neg_token_targ = {
                    let mut d = picky_asn1_der::Deserializer::new_from_bytes(&input_token.buffer);
                    let neg_token_targ: NegTokenTarg1 = KrbResult::deserialize(&mut d)??;
                    neg_token_targ
                };

                let ap_rep = extract_ap_rep_from_neg_token_targ(&neg_token_targ)?;

                let session_key = client
                    .encryption_params
                    .session_key
                    .as_ref()
                    .ok_or_else(|| Error::new(ErrorKind::InternalError, "session key is not set"))?;
                let sub_session_key =
                    extract_sub_session_key_from_ap_rep(&ap_rep, session_key, &client.encryption_params)?;

                client.encryption_params.sub_session_key = Some(sub_session_key);

                if let Some(ref token) = neg_token_targ.0.mech_list_mic.0 {
                    validate_mic_token::<SENT_BY_ACCEPTOR>(
                        &token.0 .0,
                        ACCEPTOR_SIGN,
                        &client.encryption_params,
                        &get_mech_list(),
                    )?;
                }

                client.next_seq_number();
                client.prepare_final_neg_token(builder)?;
            }

            client.state = KerberosState::PubKeyAuth;
            SecurityStatus::Ok
        }
        _ => {
            return Err(Error::new(
                ErrorKind::OutOfSequence,
                format!("got wrong Kerberos state: {:?}", client.state),
            ))
        }
    };

    trace!(output_buffers = ?builder.output);

    Ok(InitializeSecurityContextResult {
        status,
        flags: ClientResponseFlags::empty(),
        expiry: None,
    })
}
