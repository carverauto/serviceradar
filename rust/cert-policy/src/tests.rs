use crate::{Snapshot, Store, fingerprint, nats};
use async_nats::ConnectOptions;
use chrono::{Duration as ChronoDuration, Utc};
use rcgen::{BasicConstraints, Certificate, CertificateParams, IsCa};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_rustls::TlsAcceptor;

// The small protocol peer supplies actual TLS and the minimum NATS handshake.
// async-nats owns its real socket and reconnect task; no connection-close mock
// or callback invocation can make this test pass without EOF at the peer.
async fn nats_peer(cert: Vec<u8>, key: Vec<u8>) -> (String, oneshot::Receiver<()>) {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert)],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key)),
        )
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (closed_tx, closed_rx) = oneshot::channel();
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        socket.write_all(b"INFO {\"server_id\":\"SYNTHETIC_POLICY_SERVER\",\"version\":\"2.14.0\",\"proto\":1,\"max_payload\":1048576,\"tls_required\":true}\r\n").await.unwrap();
        let tls = TlsAcceptor::from(Arc::new(tls))
            .accept(socket)
            .await
            .unwrap();
        let mut stream = BufReader::new(tls);
        let mut line = String::new();
        loop {
            line.clear();
            match stream.read_line(&mut line).await {
                Ok(0) | Err(_) => {
                    let _ = closed_tx.send(());
                    return;
                }
                Ok(_) if line == "PING\r\n" => {
                    stream.get_mut().write_all(b"PONG\r\n").await.unwrap()
                }
                Ok(_) if line.starts_with("CONNECT ") => {}
                Ok(_) => panic!("unexpected NATS command: {line}"),
            }
        }
    });
    (format!("nats://localhost:{}", address.port()), closed_rx)
}

fn apply(store: &Store, lifetime: ChronoDuration, allowed: &[String]) {
    let now = Utc::now();
    store
        .apply(Snapshot {
            version: 1,
            generated_at: now,
            valid_until: now + lifetime,
            allowed_fingerprints: allowed.to_vec(),
        })
        .unwrap();
}

#[tokio::test]
async fn policy_closes_actual_nats_socket_and_preserves_same_serial_control() {
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = Certificate::from_params(ca_params).unwrap();
    let certificate = || {
        let mut params = CertificateParams::new(vec!["localhost".into()]);
        params.serial_number = Some(7_u64.into());
        Certificate::from_params(params).unwrap()
    };
    let a = certificate();
    let b = certificate();
    let a_der = a.serialize_der_with_signer(&ca).unwrap();
    let b_der = b.serialize_der_with_signer(&ca).unwrap();
    let fp_a = fingerprint(&CertificateDer::from(a_der.clone()));
    let fp_b = fingerprint(&CertificateDer::from(b_der.clone()));
    assert_ne!(fp_a, fp_b);
    let (address_a, closed_a) = nats_peer(a_der, a.serialize_private_key_der()).await;
    let (address_b, closed_b) = nats_peer(b_der, b.serialize_private_key_der()).await;
    let files = tempfile::tempdir().unwrap();
    let ca_path = files.path().join("ca.pem");
    let cert_path = files.path().join("client.pem");
    let key_path = files.path().join("client-key.pem");
    std::fs::write(&ca_path, ca.serialize_pem().unwrap()).unwrap();
    std::fs::write(&cert_path, a.serialize_pem_with_signer(&ca).unwrap()).unwrap();
    std::fs::write(&key_path, a.serialize_private_key_pem()).unwrap();
    let store = Arc::new(Store::default());
    apply(
        &store,
        ChronoDuration::seconds(20),
        &[fp_a.clone(), fp_b.clone()],
    );
    let (client_a, guard_a) = nats::connect_with_store(
        ConnectOptions::new().max_reconnects(1),
        address_a,
        store.clone(),
        &ca_path,
        &cert_path,
        &key_path,
    )
    .await
    .unwrap();
    let (client_b, guard_b) = nats::connect_with_store(
        ConnectOptions::new().max_reconnects(1),
        address_b,
        store.clone(),
        &ca_path,
        &cert_path,
        &key_path,
    )
    .await
    .unwrap();
    let guard_a = guard_a.unwrap();
    let guard_b = guard_b.unwrap();
    client_a.flush().await.unwrap();
    client_b.flush().await.unwrap();
    apply(&store, ChronoDuration::seconds(1), &[fp_b]);
    assert!(guard_a.ensure_authorized().is_err());
    tokio::time::timeout(Duration::from_secs(3), closed_a)
        .await
        .unwrap()
        .unwrap();
    guard_b.ensure_authorized().unwrap();
    client_b.flush().await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), closed_b)
        .await
        .unwrap()
        .unwrap();
    assert!(guard_b.ensure_authorized().is_err());
}

#[test]
fn policy_retains_webpki_and_hostname_checks_and_rejects_stale_refresh() {
    use rustls::client::WebPkiServerVerifier;
    use rustls::client::danger::ServerCertVerifier;
    use rustls::pki_types::{ServerName, UnixTime};
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = Certificate::from_params(ca_params).unwrap();
    let cert = Certificate::from_params(CertificateParams::new(vec!["localhost".into()])).unwrap();
    let cert = CertificateDer::from(cert.serialize_der_with_signer(&ca).unwrap());
    let fp = fingerprint(&cert);
    let store = Arc::new(Store::default());
    assert!(store.authorize(&fp).is_err());
    let snapshot = Snapshot {
        version: 1,
        generated_at: Utc::now(),
        valid_until: Utc::now() + ChronoDuration::seconds(20),
        allowed_fingerprints: vec![fp.clone()],
    };
    // Fresh replicas consume the authority's wire representation, not local state.
    let bytes = serde_json::to_vec(&snapshot).unwrap();
    store
        .apply(serde_json::from_slice(&bytes).unwrap())
        .unwrap();
    let replica = Store::default();
    replica
        .apply(serde_json::from_slice(&bytes).unwrap())
        .unwrap();
    replica.authorize(&fp).unwrap();
    for invalid in [
        Snapshot {
            version: 2,
            ..snapshot.clone()
        },
        Snapshot {
            valid_until: snapshot.generated_at + ChronoDuration::seconds(31),
            ..snapshot.clone()
        },
        Snapshot {
            generated_at: snapshot.generated_at - ChronoDuration::seconds(1),
            ..snapshot.clone()
        },
        Snapshot {
            allowed_fingerprints: vec![],
            ..snapshot.clone()
        },
    ] {
        assert!(store.apply(invalid).is_err());
        store.authorize(&fp).unwrap();
    }
    let mut roots = rustls::RootCertStore::empty();
    roots
        .add(CertificateDer::from(ca.serialize_der().unwrap()))
        .unwrap();
    let base = WebPkiServerVerifier::builder_with_provider(
        Arc::new(roots),
        Arc::new(rustls::crypto::ring::default_provider()),
    )
    .build()
    .unwrap();
    let verifier = crate::PolicyVerifier::new(base, store);
    assert!(
        verifier
            .verify_server_cert(
                &cert,
                &[],
                &ServerName::try_from("localhost").unwrap(),
                &[],
                UnixTime::now()
            )
            .is_ok()
    );
    assert!(
        verifier
            .verify_server_cert(
                &cert,
                &[],
                &ServerName::try_from("wrong.example.test").unwrap(),
                &[],
                UnixTime::now()
            )
            .is_err()
    );
    // Removing trust anchors must fail even though the exact leaf is allowlisted.
    let unrelated = Certificate::from_params(CertificateParams::default()).unwrap();
    let mut roots = rustls::RootCertStore::empty();
    roots
        .add(CertificateDer::from(unrelated.serialize_der().unwrap()))
        .unwrap();
    let base = WebPkiServerVerifier::builder_with_provider(
        Arc::new(roots),
        Arc::new(rustls::crypto::ring::default_provider()),
    )
    .build()
    .unwrap();
    let verifier = crate::PolicyVerifier::new(base, Arc::new(replica));
    assert!(
        verifier
            .verify_server_cert(
                &cert,
                &[],
                &ServerName::try_from("localhost").unwrap(),
                &[],
                UnixTime::now()
            )
            .is_err()
    );
}

#[test]
fn fresh_admission_restores_publishing_after_unconfirmed_only_while_transport_is_up() {
    use crate::Admission;
    use nats::EnforcementStatus;

    // Oracle: async-nats `connection_state` is the transport fact. A valid
    // snapshot must not report Connected after the socket has dropped, and an
    // Unconfirmed client whose socket never left must publish again.
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::Unconfirmed, Admission::Fresh, true),
        Some(EnforcementStatus::Connected)
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::Disconnecting, Admission::Fresh, true),
        Some(EnforcementStatus::Connected)
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::Disconnected, Admission::Fresh, true),
        Some(EnforcementStatus::Connected)
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::Unconfirmed, Admission::Fresh, false),
        None
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::Disconnected, Admission::StaleLocal, false),
        None
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::Connected, Admission::StaleLocal, true),
        Some(EnforcementStatus::StaleLocal)
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::StaleLocal, Admission::StaleLocal, true),
        None
    );
    assert_eq!(
        super::restored_enforcement(EnforcementStatus::StaleLocal, Admission::Fresh, true),
        Some(EnforcementStatus::Connected)
    );
}

#[tokio::test]
async fn enrolled_local_leaf_survives_stale_policy_but_closes_on_revocation_and_certificate_expiry()
{
    use chrono::{Datelike, Timelike};
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = Certificate::from_params(ca_params).unwrap();
    let dns_name = "leaf-synthetic-server.default.serviceradar";
    let certificate = |short_lived: bool| {
        let mut params = CertificateParams::new(vec!["localhost".into()]);
        params
            .subject_alt_names
            .push(rcgen::SanType::DnsName(dns_name.to_string()));
        if short_lived {
            let now = Utc::now();
            params.not_after = rcgen::date_time_ymd(now.year(), now.month() as u8, now.day() as u8)
                + Duration::from_secs(u64::from(now.num_seconds_from_midnight()) + 4);
        }
        Certificate::from_params(params).unwrap()
    };
    let a = certificate(false);
    let b = certificate(true);
    let a_der = a.serialize_der_with_signer(&ca).unwrap();
    let b_der = b.serialize_der_with_signer(&ca).unwrap();
    let fp_a = fingerprint(&CertificateDer::from(a_der.clone()));
    let fp_b = fingerprint(&CertificateDer::from(b_der.clone()));
    let (address_a, closed_a) = nats_peer(a_der, a.serialize_private_key_der()).await;
    let (address_b, closed_b) = nats_peer(b_der, b.serialize_private_key_der()).await;
    let files = tempfile::tempdir().unwrap();
    let ca_path = files.path().join("ca.pem");
    let cert_path = files.path().join("client.pem");
    let key_path = files.path().join("key.pem");
    std::fs::write(&ca_path, ca.serialize_pem().unwrap()).unwrap();
    std::fs::write(&cert_path, a.serialize_pem_with_signer(&ca).unwrap()).unwrap();
    std::fs::write(&key_path, a.serialize_private_key_pem()).unwrap();
    let store = Arc::new(Store::default());
    let now = Utc::now();
    // A process restarted during the outage consumes only the already verified
    // root-owned snapshot. Strict callers still reject its expired lease.
    store
        .restore_local(Snapshot {
            version: 1,
            generated_at: now - ChronoDuration::seconds(20),
            valid_until: now - ChronoDuration::seconds(1),
            allowed_fingerprints: vec![fp_a.clone(), fp_b.clone()],
        })
        .unwrap();
    assert!(store.authorize(&fp_a).is_err());
    let managed = |address: &str| super::ManagedPolicy {
        store: store.clone(),
        file: None,
        local_leaf: Some(super::LocalLeafBinding {
            version: 1,
            endpoint: address.replace("nats://", "tls://"),
            server_dns_name: dns_name.into(),
        }),
    };
    let (client_a, guard_a) = super::connect_managed(
        ConnectOptions::new().max_reconnects(1),
        &address_a,
        managed(&address_a),
        &ca_path,
        &cert_path,
        &key_path,
    )
    .await
    .unwrap();
    let (client_b, guard_b) = super::connect_managed(
        ConnectOptions::new().max_reconnects(1),
        &address_b,
        managed(&address_b),
        &ca_path,
        &cert_path,
        &key_path,
    )
    .await
    .unwrap();
    let guard_a = guard_a.unwrap();
    let guard_b = guard_b.unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        while guard_a.status() != nats::EnforcementStatus::StaleLocal {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    guard_a.ensure_authorized().unwrap();
    client_a.flush().await.unwrap();
    client_b.flush().await.unwrap();
    apply(&store, ChronoDuration::milliseconds(250), &[fp_b]);
    assert!(guard_a.ensure_authorized().is_err());
    tokio::time::timeout(Duration::from_secs(2), closed_a)
        .await
        .unwrap()
        .unwrap();
    guard_b.ensure_authorized().unwrap();
    client_b.flush().await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), closed_b)
        .await
        .unwrap()
        .unwrap();
    assert!(guard_b.ensure_authorized().is_err());
}

#[tokio::test]
async fn local_leaf_binding_rejects_another_endpoint_and_another_dns_name() {
    use rustls::client::WebPkiServerVerifier;
    use rustls::client::danger::ServerCertVerifier;
    use rustls::pki_types::{ServerName, UnixTime};
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = Certificate::from_params(ca_params).unwrap();
    let mut params = CertificateParams::new(vec!["localhost".into()]);
    params.subject_alt_names.push(rcgen::SanType::DnsName(
        "other-server.default.serviceradar".to_string(),
    ));
    let leaf = Certificate::from_params(params).unwrap();
    let der = CertificateDer::from(leaf.serialize_der_with_signer(&ca).unwrap());
    let store = Arc::new(Store::default());
    apply(&store, ChronoDuration::seconds(20), &[fingerprint(&der)]);
    let mut roots = rustls::RootCertStore::empty();
    roots
        .add(CertificateDer::from(ca.serialize_der().unwrap()))
        .unwrap();
    let base = WebPkiServerVerifier::builder_with_provider(
        Arc::new(roots),
        Arc::new(rustls::crypto::ring::default_provider()),
    )
    .build()
    .unwrap();
    let verifier = crate::PolicyVerifier::new(base, store.clone())
        .for_local_leaf("enrolled-server.default.serviceradar".into());
    assert!(
        verifier
            .verify_server_cert(
                &der,
                &[],
                &ServerName::try_from("localhost").unwrap(),
                &[],
                UnixTime::now()
            )
            .is_err()
    );
    let policy = super::ManagedPolicy {
        store,
        file: None,
        local_leaf: Some(super::LocalLeafBinding {
            version: 1,
            endpoint: "tls://localhost:4222".into(),
            server_dns_name: "enrolled-server.default.serviceradar".into(),
        }),
    };
    let missing = std::path::Path::new("synthetic-unused.pem");
    let error = super::connect_managed(
        ConnectOptions::new(),
        "tls://localhost:4223",
        policy,
        missing,
        missing,
        missing,
    )
    .await
    .err()
    .unwrap();
    assert_eq!(
        error.to_string(),
        "NATS endpoint differs from enrolled local leaf binding"
    );
}
