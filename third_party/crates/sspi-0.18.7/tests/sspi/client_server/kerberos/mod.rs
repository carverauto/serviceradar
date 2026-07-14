#![allow(clippy::result_large_err)]

pub(super) mod kdc;
pub(super) mod network_client;

use std::collections::{HashMap, HashSet};
use std::panic;

use picky_asn1::restricted_string::IA5String;
use picky_asn1::wrapper::{Asn1SequenceOf, ExplicitContextTag0, ExplicitContextTag1, IntegerAsn1};
use picky_krb::constants::types::{NT_PRINCIPAL, NT_SRV_INST};
use picky_krb::data_types::{KerberosStringAsn1, PrincipalName};
use picky_krb::gss_api::MechTypeList;
use sspi::credssp::SspiContext;
use sspi::kerberos::ServerProperties;
use sspi::network_client::NetworkClient;
use sspi::{
    AuthIdentity, BufferType, ClientRequestFlags, Credentials, CredentialsBuffers, DataRepresentation, Kerberos,
    KerberosConfig, SecurityBuffer, SecurityStatus, ServerRequestFlags, Sspi, SspiImpl, Username,
};
use url::Url;

use crate::client_server::kerberos::kdc::{
    KdcMock, PasswordCreds, UserName, Validators, CLIENT_COMPUTER_NAME, KDC_URL, MAX_TIME_SKEW,
};
use crate::client_server::kerberos::network_client::NetworkClientMock;
use crate::client_server::{test_encryption, test_rpc_request_encryption, test_stream_buffer_encryption};

/// Represents a Kerberos environment:
/// * user and services keys;
/// * user logon credentials;
/// * realm and target application service name;
///
/// It is used for simplifying tests environment preparation.
pub(super) struct KrbEnvironment {
    pub keys: HashMap<UserName, Vec<u8>>,
    pub users: HashMap<UserName, PasswordCreds>,
    pub credentials: Credentials,
    pub realm: String,
    pub target_name: String,
    pub target_service_name: PrincipalName,
}

/// Initializes a Kerberos environment. It includes:
/// * User logon credentials (password-based).
/// * Kerberos services keys.
/// * Target machine name.
pub(super) fn init_krb_environment() -> KrbEnvironment {
    let username = "pw13";
    let user_password = "qweQWE123!@#";
    let domain = "EXAMPLE";
    let realm = "EXAMPLE.COM";
    let mut salt = realm.to_string();
    salt.push_str(username);
    let krbtgt = "krbtgt";
    let termsrv = "TERMSRV";
    let target_machine_name = "DESKTOP-8F33RFH.example.com";
    let mut target_name = termsrv.to_string();
    target_name.push('/');
    target_name.push_str(target_machine_name);

    let tgt_service_key = vec![
        199, 133, 201, 239, 57, 139, 61, 128, 71, 236, 217, 130, 250, 148, 117, 193, 197, 86, 155, 11, 92, 124, 232,
        146, 3, 14, 158, 220, 113, 63, 110, 230,
    ];
    let application_service_key = vec![
        168, 29, 77, 196, 211, 88, 148, 180, 123, 188, 196, 182, 173, 30, 249, 191, 89, 35, 44, 56, 20, 217, 132, 131,
        89, 144, 33, 79, 16, 91, 126, 72,
    ];
    let keys = [
        (
            UserName(PrincipalName {
                name_type: ExplicitContextTag0::from(IntegerAsn1::from(vec![NT_SRV_INST])),
                name_string: ExplicitContextTag1::from(Asn1SequenceOf::from(vec![
                    KerberosStringAsn1::from(IA5String::from_string(krbtgt.into()).unwrap()),
                    KerberosStringAsn1::from(IA5String::from_string(domain.into()).unwrap()),
                ])),
            }),
            tgt_service_key.clone(),
        ),
        (
            UserName(PrincipalName {
                name_type: ExplicitContextTag0::from(IntegerAsn1::from(vec![NT_SRV_INST])),
                name_string: ExplicitContextTag1::from(Asn1SequenceOf::from(vec![
                    KerberosStringAsn1::from(IA5String::from_string(krbtgt.into()).unwrap()),
                    KerberosStringAsn1::from(IA5String::from_string(realm.to_string()).unwrap()),
                ])),
            }),
            tgt_service_key,
        ),
        (
            UserName(PrincipalName {
                name_type: ExplicitContextTag0::from(IntegerAsn1::from(vec![NT_SRV_INST])),
                name_string: ExplicitContextTag1::from(Asn1SequenceOf::from(vec![
                    KerberosStringAsn1::from(IA5String::from_string(termsrv.into()).unwrap()),
                    KerberosStringAsn1::from(IA5String::from_string(target_machine_name.into()).unwrap()),
                ])),
            }),
            application_service_key,
        ),
    ]
    .into_iter()
    .collect();
    let users = [(
        UserName(PrincipalName {
            name_type: ExplicitContextTag0::from(IntegerAsn1::from(vec![NT_PRINCIPAL])),
            name_string: ExplicitContextTag1::from(Asn1SequenceOf::from(vec![KerberosStringAsn1::from(
                IA5String::from_string(username.into()).unwrap(),
            )])),
        }),
        PasswordCreds {
            password: user_password.as_bytes().to_vec(),
            salt,
        },
    )]
    .into_iter()
    .collect();

    let credentials = Credentials::AuthIdentity(AuthIdentity {
        username: Username::new_down_level_logon_name(username, domain).unwrap(),
        password: user_password.to_owned().into(),
    });

    KrbEnvironment {
        keys,
        users,
        realm: realm.to_string(),
        credentials,
        target_name,
        target_service_name: PrincipalName {
            name_type: ExplicitContextTag0::from(IntegerAsn1::from(vec![NT_SRV_INST])),
            name_string: ExplicitContextTag1::from(Asn1SequenceOf::from(vec![
                KerberosStringAsn1::from(IA5String::from_string("TERMSRV".into()).unwrap()),
                KerberosStringAsn1::from(IA5String::from_string("DESKTOP-8F33RFH.example.com".into()).unwrap()),
            ])),
        },
    }
}

/// Does all preparations and calls the [initialize_security_context_impl] function
/// on the provided Kerberos context.
pub(super) fn initialize_security_context(
    client: &mut SspiContext,
    credentials_handle: &mut Option<CredentialsBuffers>,
    flags: ClientRequestFlags,
    target_name: &str,
    in_token: Vec<u8>,
    network_client: &mut dyn NetworkClient,
) -> (SecurityStatus, Vec<u8>) {
    let mut input_token = [SecurityBuffer::new(in_token, BufferType::Token)];
    let mut output_token = vec![SecurityBuffer::new(Vec::with_capacity(1024), BufferType::Token)];

    let mut builder = client
        .initialize_security_context()
        .with_credentials_handle(credentials_handle)
        .with_context_requirements(flags)
        .with_target_data_representation(DataRepresentation::Native)
        .with_target_name(target_name)
        .with_input(&mut input_token)
        .with_output(&mut output_token);
    let result = client
        .initialize_security_context_impl(&mut builder)
        .expect("Kerberos initialize_security_context should not fail")
        .resolve_with_client(network_client)
        .expect("Kerberos initialize_security_context should not fail");

    (result.status, output_token.remove(0).buffer)
}

/// Does all preparations and calls the [accept_security_context] function
/// on the provided Kerberos context.
pub(super) fn accept_security_context(
    server: &mut SspiContext,
    credentials_handle: &mut Option<CredentialsBuffers>,
    flags: ServerRequestFlags,
    in_token: Vec<u8>,
    network_client: &mut dyn NetworkClient,
) -> (SecurityStatus, Vec<u8>) {
    let mut input_token = [SecurityBuffer::new(in_token, BufferType::Token)];
    let mut output_token = vec![SecurityBuffer::new(Vec::with_capacity(1024), BufferType::Token)];

    let builder = server
        .accept_security_context()
        .with_credentials_handle(credentials_handle)
        .with_context_requirements(flags)
        .with_target_data_representation(DataRepresentation::Native)
        .with_input(&mut input_token)
        .with_output(&mut output_token);
    let result = server
        .accept_security_context_impl(builder)
        .expect("Kerberos accept_security_context should not fail")
        .resolve_with_client(network_client)
        .expect("Kerberos accept_security_context should not fail");

    (result.status, output_token.remove(0).buffer)
}

fn run_kerberos(
    client: &mut SspiContext,
    client_credentials_handle: &mut Option<CredentialsBuffers>,
    client_flags: ClientRequestFlags,
    target_name: &str,

    server: &mut SspiContext,
    server_credentials_handle: &mut Option<CredentialsBuffers>,
    server_flags: ServerRequestFlags,

    network_client: &mut dyn NetworkClient,
) {
    let mut client_in_token = Vec::new();

    for _ in 0..3 {
        let (client_status, token) = initialize_security_context(
            client,
            client_credentials_handle,
            client_flags,
            target_name,
            client_in_token,
            network_client,
        );

        let (_, token) =
            accept_security_context(server, server_credentials_handle, server_flags, token, network_client);
        client_in_token = token;

        if client_status == SecurityStatus::Ok {
            test_encryption(client, server);
            test_stream_buffer_encryption(client, server);
            test_rpc_request_encryption(client, server);
            return;
        }
    }

    panic!("Kerberos authentication should not exceed 3 steps");
}

#[test]
fn kerberos_auth() {
    let KrbEnvironment {
        realm,
        credentials,
        keys,
        users,
        target_name,
        target_service_name,
    } = init_krb_environment();

    let ticket_decryption_key = keys[&UserName(target_service_name.clone())].clone();

    let kdc = KdcMock::new(
        realm,
        keys,
        users,
        Validators {
            as_req: Box::new(|_as_req| {
                // Nothing to validate in AsReq.
            }),
            tgs_req: Box::new(|tgs_req| {
                // Here, we should check that the Kerberos client does not negotiated Kerberos U2U auth and not enabled any unneeded flags.

                let kdc_options = tgs_req.0.req_body.kdc_options.0 .0.as_bytes();
                // enc-tkt-in-skey must be disabled.
                assert_eq!(kdc_options[4], 0x00, "some unneeded KDC options are enabled");

                let additional_tickets = tgs_req
                    .0
                    .req_body
                    .0
                    .additional_tickets
                    .0
                    .as_ref()
                    .map(|additional_tickets| additional_tickets.0 .0.as_slice());
                assert!(
                    matches!(additional_tickets, None | Some(&[])),
                    "TgsReq should not contain any additional tickets"
                );
            }),
        },
    );
    let mut network_client = NetworkClientMock { kdc };

    let client_config = KerberosConfig {
        kdc_url: Some(Url::parse("tcp://192.168.1.103:88").unwrap()),
        client_computer_name: Some("DESKTOP-I7E8EFA.example.com".into()),
    };
    let kerberos_client = Kerberos::new_client_from_config(client_config).unwrap();

    let server_config = KerberosConfig {
        kdc_url: Some(Url::parse("tcp://192.168.1.103:88").unwrap()),
        client_computer_name: Some("DESKTOP-8F33RFH.example.com".into()),
    };
    let server_properties = ServerProperties {
        mech_types: MechTypeList::from(Vec::new()),
        max_time_skew: MAX_TIME_SKEW,
        ticket_decryption_key: Some(ticket_decryption_key),
        service_name: target_service_name,
        user: None,
        client: None,
        authenticators_cache: HashSet::new(),
    };
    let kerberos_server = Kerberos::new_server_from_config(server_config, server_properties).unwrap();

    let credentials = CredentialsBuffers::try_from(credentials).unwrap();
    let mut client_credentials_handle = Some(credentials.clone());
    let mut server_credentials_handle = Some(credentials);

    let client_flags = ClientRequestFlags::MUTUAL_AUTH
        | ClientRequestFlags::INTEGRITY
        | ClientRequestFlags::SEQUENCE_DETECT
        | ClientRequestFlags::REPLAY_DETECT
        | ClientRequestFlags::CONFIDENTIALITY;
    let server_flags = ServerRequestFlags::MUTUAL_AUTH
        | ServerRequestFlags::INTEGRITY
        | ServerRequestFlags::SEQUENCE_DETECT
        | ServerRequestFlags::REPLAY_DETECT
        | ServerRequestFlags::CONFIDENTIALITY;

    run_kerberos(
        &mut SspiContext::Kerberos(kerberos_client),
        &mut client_credentials_handle,
        client_flags,
        &target_name,
        &mut SspiContext::Kerberos(kerberos_server),
        &mut server_credentials_handle,
        server_flags,
        &mut network_client,
    );
}

#[test]
fn kerberos_u2u_auth() {
    let KrbEnvironment {
        realm,
        credentials,
        keys,
        users,
        target_name,
        target_service_name,
    } = init_krb_environment();

    let kdc = KdcMock::new(
        realm,
        keys,
        users,
        Validators {
            as_req: Box::new(|_as_req| {
                // Nothing to validate in AsReq.
            }),
            tgs_req: Box::new(|tgs_req| {
                // Here, we should check that the Kerberos client successfully negotiated Kerberos U2U auth.

                let kdc_options = tgs_req.0.req_body.kdc_options.0 .0.as_bytes();
                // KDC options must have enc-tkt-in-skey enabled.
                assert_eq!(kdc_options[4], 0x08, "the enc-tkt-in-skey KDC option is not enabled");

                if let Some(tickets) = tgs_req.0.req_body.0.additional_tickets.0.as_ref() {
                    assert!(
                        !tickets.0 .0.is_empty(),
                        "TgsReq must have at least one additional ticket: TGT from the application service"
                    );
                } else {
                    panic!("TgsReq must have at least one additional ticket: TGT from the application service");
                }
            }),
        },
    );
    let mut network_client = NetworkClientMock { kdc };

    let client_config = KerberosConfig {
        kdc_url: Some(Url::parse(KDC_URL).unwrap()),
        client_computer_name: Some(CLIENT_COMPUTER_NAME.into()),
    };
    let kerberos_client = Kerberos::new_client_from_config(client_config).unwrap();

    let server_config = KerberosConfig {
        kdc_url: Some(Url::parse(KDC_URL).unwrap()),
        client_computer_name: Some(CLIENT_COMPUTER_NAME.into()),
    };
    let server_properties = ServerProperties {
        mech_types: MechTypeList::default(),
        max_time_skew: MAX_TIME_SKEW,
        ticket_decryption_key: None,
        service_name: target_service_name,
        user: None,
        client: None,
        authenticators_cache: HashSet::new(),
    };
    let kerberos_server = Kerberos::new_server_from_config(server_config, server_properties).unwrap();

    let credentials = CredentialsBuffers::try_from(credentials).unwrap();
    let mut client_credentials_handle = Some(credentials.clone());
    let mut server_credentials_handle = Some(credentials);

    let client_flags = ClientRequestFlags::MUTUAL_AUTH
        | ClientRequestFlags::INTEGRITY
        | ClientRequestFlags::USE_SESSION_KEY // Kerberos U2U auth
        | ClientRequestFlags::SEQUENCE_DETECT
        | ClientRequestFlags::REPLAY_DETECT
        | ClientRequestFlags::CONFIDENTIALITY;
    let server_flags = ServerRequestFlags::MUTUAL_AUTH
        | ServerRequestFlags::INTEGRITY
        | ServerRequestFlags::USE_SESSION_KEY // Kerberos U2U auth
        | ServerRequestFlags::SEQUENCE_DETECT
        | ServerRequestFlags::REPLAY_DETECT
        | ServerRequestFlags::CONFIDENTIALITY;

    run_kerberos(
        &mut SspiContext::Kerberos(kerberos_client),
        &mut client_credentials_handle,
        client_flags,
        &target_name,
        &mut SspiContext::Kerberos(kerberos_server),
        &mut server_credentials_handle,
        server_flags,
        &mut network_client,
    );
}
