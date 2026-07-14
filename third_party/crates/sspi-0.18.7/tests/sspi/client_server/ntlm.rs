use sspi::builders::{AcquireCredentialsHandle, WithoutCredentialUse};
use sspi::credssp::SspiContext;
use sspi::ntlm::NtlmConfig;
use sspi::{
    AcquireCredentialsHandleResult, AuthIdentity, BufferType, ClientRequestFlags, CredentialUse, Credentials,
    DataRepresentation, InitializeSecurityContextResult, Ntlm, Secret, SecurityBuffer, SecurityStatus,
    ServerRequestFlags, Sspi, Username,
};

use crate::client_server::{test_encryption, test_rpc_request_encryption, test_stream_buffer_encryption};

fn run_ntlm(config: NtlmConfig) {
    let credentials = Credentials::AuthIdentity(AuthIdentity {
        username: Username::parse("test_user").unwrap(),
        password: Secret::from("test_password".to_owned()),
    });
    let target_name = "TERMSRV/DESKTOP-8F33RFH.example.com";

    let mut client = SspiContext::Ntlm(Ntlm::with_config(config.clone()));
    let mut server = SspiContext::Ntlm(Ntlm::with_config(config));

    let builder = AcquireCredentialsHandle::<'_, _, _, WithoutCredentialUse>::new();
    let AcquireCredentialsHandleResult {
        credentials_handle: mut client_credentials_handle,
        ..
    } = builder
        .with_auth_data(&credentials)
        .with_credential_use(CredentialUse::Outbound)
        .execute(&mut client)
        .unwrap();

    let builder = AcquireCredentialsHandle::<'_, _, _, WithoutCredentialUse>::new();
    let AcquireCredentialsHandleResult {
        credentials_handle: mut server_credentials_handle,
        ..
    } = builder
        .with_auth_data(&credentials)
        .with_credential_use(CredentialUse::Inbound)
        .execute(&mut server)
        .unwrap();

    let mut input_token = [SecurityBuffer::new(Vec::new(), BufferType::Token)];
    let mut output_token = [SecurityBuffer::new(Vec::new(), BufferType::Token)];

    for _ in 0..3 {
        let mut builder = client
            .initialize_security_context()
            .with_credentials_handle(&mut client_credentials_handle)
            .with_context_requirements(
                ClientRequestFlags::MUTUAL_AUTH
                    | ClientRequestFlags::USE_SESSION_KEY
                    | ClientRequestFlags::INTEGRITY
                    | ClientRequestFlags::CONFIDENTIALITY,
            )
            .with_target_data_representation(DataRepresentation::Native)
            .with_target_name(target_name)
            .with_input(&mut input_token)
            .with_output(&mut output_token);
        let InitializeSecurityContextResult { status, .. } =
            client.initialize_security_context_sync(&mut builder).unwrap();

        input_token[0].buffer.clear();

        let builder = server
            .accept_security_context()
            .with_credentials_handle(&mut server_credentials_handle)
            .with_context_requirements(ServerRequestFlags::empty())
            .with_target_data_representation(DataRepresentation::Native)
            .with_input(&mut output_token)
            .with_output(&mut input_token);
        server.accept_security_context_sync(builder).unwrap();

        output_token[0].buffer.clear();

        if status == SecurityStatus::Ok {
            test_encryption(&mut client, &mut server);
            test_stream_buffer_encryption(&mut client, &mut server);
            test_rpc_request_encryption(&mut client, &mut server);
            return;
        }
    }

    panic!("NTLM authentication should not exceed 3 steps")
}

#[test]
fn ntlm_with_computer_name() {
    run_ntlm(NtlmConfig {
        client_computer_name: Some("DESKTOP-3D83IAN.example.com".to_owned()),
    });
}

#[test]
fn ntlm_without_computer_name() {
    run_ntlm(NtlmConfig {
        client_computer_name: None,
    });
}
