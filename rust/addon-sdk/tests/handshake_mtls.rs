/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Rust-side integration test for the go-plugin handshake + AutoMTLS server.
//!
//! This test plays the *host* (go-plugin client) role within Rust: it generates
//! a client certificate exactly as go-plugin's `Client` does (a self-signed
//! `localhost` CA), drives the server through [`addon_sdk::serve_on_listener`],
//! and dials the Unix socket over mTLS while **pinning the server's advertised
//! cert by exact DER** and presenting the client identity — precisely the trust
//! decision go-plugin's Go client makes (`loadServerCert` +
//! `RequireAndVerifyClientCert`). It then exercises Info / Configure / Health.
//!
//! It deliberately uses a raw `rustls::ClientConfig` with a DER-pinning verifier
//! rather than tonic's `ClientTlsConfig`, because rustls' default WebPKI
//! verifier rejects go-plugin's self-signed-CA certs (the same reason the server
//! uses a custom client verifier — see `addon_sdk::tls`).
//!
//! The *authoritative* cross-language proof — that the agent's unmodified Go
//! go-plugin client accepts this server — lives in
//! `go/pkg/agent/addon/manager_rust_addon_test.go`.

use std::path::PathBuf;
use std::sync::Arc;

use addon_sdk::handshake;
use addon_sdk::pb::addon_service_client::AddonServiceClient;
use addon_sdk::pb::{ConfigureRequest, HealthRequest, InfoRequest};
use addon_sdk::tls;
use addon_sdk::{Addon, ConfigureResult, Health, HealthStatus, Info};
use async_trait::async_trait;
use rcgen::generate_simple_self_signed;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use tokio::net::UnixStream;
use tokio_rustls::TlsConnector;

#[derive(Default)]
struct TestAddon;

#[async_trait]
impl Addon for TestAddon {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info {
            id: "rust-sample".into(),
            version: "9.9.9".into(),
            capabilities: vec!["rust-sample".into()],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        use sha2::{Digest as _, Sha256};
        let mut h = Sha256::new();
        h.update(config_json);
        Ok(ConfigureResult {
            config_hash: hex::encode(h.finalize()),
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        Ok(Health {
            status: HealthStatus::Healthy,
            version: "9.9.9".into(),
            degradation_reason: String::new(),
            details: Default::default(),
        })
    }
}

/// Pins the server certificate by exact DER, mirroring go-plugin's
/// `loadServerCert` (which adds the advertised cert as the sole RootCA and then
/// effectively trusts that exact cert).
#[derive(Debug)]
struct PinnedServerVerifier {
    pinned: CertificateDer<'static>,
}

impl ServerCertVerifier for PinnedServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if end_entity.as_ref() == self.pinned.as_ref() {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "server certificate does not match the pinned handshake cert".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[tokio::test]
async fn server_completes_automtls_handshake_and_serves_rpcs() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    // 1. Generate a client cert/key the way go-plugin's Client does (self-signed
    //    `localhost`), and build the server's mTLS material from that PEM.
    let client_kp = generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
    // Serialize the client cert exactly ONCE (rcgen re-signs per call with fresh
    // ECDSA randomness), then derive both the PEM handed to the server and the
    // DER the client presents from those same bytes — otherwise the server's
    // pinned DER and the presented DER differ and mTLS fails. This mirrors the
    // real host, where the go-plugin client uses one cert for both
    // PLUGIN_CLIENT_CERT and its TLS identity.
    let client_cert_der = client_kp.serialize_der().unwrap();
    let client_cert_pem = {
        use base64::Engine as _;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&client_cert_der);
        let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
        for chunk in b64.as_bytes().chunks(64) {
            pem.push_str(std::str::from_utf8(chunk).unwrap());
            pem.push('\n');
        }
        pem.push_str("-----END CERTIFICATE-----\n");
        pem
    };
    let client_key_der = client_kp.serialize_private_key_der();

    let server_mtls = tls::build_server_mtls(&client_cert_pem).expect("build server mtls");
    let server_cert_b64 = server_mtls.server_cert_b64.clone();
    let server_cert_der =
        tls::decode_server_cert_b64(&server_cert_b64).expect("decode server cert");

    // 2. Bind a Unix socket and assert the handshake line is well-formed
    //    (CORE|APP|unix|addr|grpc|cert).
    let tmp = tempfile::tempdir().unwrap();
    let sock_path: PathBuf = tmp.path().join("plugin.sock");
    let listener = tokio::net::UnixListener::bind(&sock_path).unwrap();

    let line = handshake::build_handshake_line(&sock_path, &server_cert_b64);
    let parts: Vec<&str> = line.split('|').collect();
    assert_eq!(parts.len(), 6, "handshake line must have 6 fields: {line}");
    assert_eq!(parts[0], handshake::CORE_PROTOCOL_VERSION.to_string());
    assert_eq!(parts[1], handshake::APP_PROTOCOL_VERSION.to_string());
    assert_eq!(parts[2], "unix");
    assert_eq!(parts[3], sock_path.display().to_string());
    assert_eq!(parts[4], "grpc");
    assert!(parts[5].len() > 50, "server cert field must be a real cert");

    // 3. Serve the add-on over mTLS on that socket.
    let server = tokio::spawn(async move {
        let _ = addon_sdk::serve_on_listener(TestAddon, listener, Some(server_mtls)).await;
    });

    // 4. Dial as the host: pin the server's advertised DER, present the client
    //    identity, request ServerName "localhost".
    let client_identity = CertificateDer::from(client_cert_der);
    let client_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(client_key_der));
    let mut client_config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedServerVerifier {
            pinned: CertificateDer::from(server_cert_der),
        }))
        .with_client_auth_cert(vec![client_identity], client_key)
        .expect("client auth cert");
    client_config.alpn_protocols = vec![b"h2".to_vec()];
    let connector = TlsConnector::from(Arc::new(client_config));

    let server_name = ServerName::try_from("localhost").unwrap();
    let connect_path = sock_path.clone();
    // Use an http:// URI: TLS is performed inside our custom connector (which
    // returns an already-encrypted TlsStream), so the Endpoint must not try to
    // layer its own TLS on top.
    let channel = tonic::transport::Endpoint::try_from("http://localhost")
        .unwrap()
        .connect_with_connector(tower::service_fn(move |_: tonic::transport::Uri| {
            let connector = connector.clone();
            let server_name = server_name.clone();
            let p = connect_path.clone();
            async move {
                let unix = UnixStream::connect(p).await?;
                let tls = connector.connect(server_name, unix).await?;
                Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(tls))
            }
        }))
        .await
        .expect("client connects to server over mTLS");

    let mut client = AddonServiceClient::new(channel);

    let info = client
        .info(InfoRequest {})
        .await
        .expect("Info")
        .into_inner();
    assert_eq!(info.id, "rust-sample");
    assert_eq!(info.version, "9.9.9");
    assert_eq!(info.capabilities, vec!["rust-sample".to_string()]);

    let cfg = client
        .configure(ConfigureRequest {
            config_json: br#"{"scan_interval_seconds":60}"#.to_vec(),
        })
        .await
        .expect("Configure")
        .into_inner();
    assert!(cfg.accepted);
    assert_eq!(cfg.config_hash.len(), 64, "sha256 hex");

    let health = client
        .health(HealthRequest {})
        .await
        .expect("Health")
        .into_inner();
    assert_eq!(
        health.status,
        addon_sdk::pb::health_response::Status::Healthy as i32
    );

    server.abort();
}
