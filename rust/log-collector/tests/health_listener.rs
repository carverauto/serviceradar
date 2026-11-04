use std::fs::{self, File};
use std::net::{TcpListener, UdpSocket};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use rcgen::{BasicConstraints, Certificate, CertificateParams, IsCa};
use tonic::transport::{Certificate as TlsCertificate, ClientTlsConfig, Endpoint, Identity};
use tonic_health::pb::{HealthCheckRequest, health_client::HealthClient};

struct Collector(Child);

impl Drop for Collector {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn embedded_syslog_and_unified_health_share_one_mtls_listener() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let files = tempfile::tempdir().unwrap();
    let root = files.path();
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = Certificate::from_params(ca_params).unwrap();
    let leaf = Certificate::from_params(CertificateParams::new(vec!["localhost".into()])).unwrap();
    let ca_pem = ca.serialize_pem().unwrap();
    let cert_pem = leaf.serialize_pem_with_signer(&ca).unwrap();
    let key_pem = leaf.serialize_private_key_pem();
    fs::write(root.join("ca.pem"), &ca_pem).unwrap();
    fs::write(root.join("cert.pem"), &cert_pem).unwrap();
    fs::write(root.join("key.pem"), &key_pem).unwrap();

    let health = TcpListener::bind("127.0.0.1:0").unwrap();
    let health_addr = health.local_addr().unwrap();
    let input = UdpSocket::bind("127.0.0.1:0").unwrap();
    let input_addr = input.local_addr().unwrap();
    fs::write(
        root.join("flowgger.toml"),
        format!(
            r#"[input]
type = "udp"
listen = "{input_addr}"
format = "rfc5424"
[output]
type = "debug"
format = "gelf"
[grpc]
listen_addr = "{health_addr}"
mode = "mtls"
cert_file = "{root}/cert.pem"
key_file = "{root}/key.pem"
ca_file = "{root}/ca.pem"
"#,
            root = root.display()
        ),
    )
    .unwrap();
    fs::write(
        root.join("collector.toml"),
        format!(
            "[flowgger]\nenabled = true\nconfig_file = {:?}\n[otel]\nenabled = false\n[health]\nlisten_addr = \"{health_addr}\"\n",
            root.join("flowgger.toml")
        ),
    )
    .unwrap();
    let binary = option_env!("CARGO_BIN_EXE_serviceradar-log-collector")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            runfiles::Runfiles::create()
                .unwrap()
                .rlocation_from("serviceradar/rust/log-collector/log-collector", "")
                .expect("declared collector executable")
        });
    drop(health);
    drop(input);
    let mut collector = Collector(
        Command::new(&binary)
            .arg("--config")
            .arg(root.join("collector.toml"))
            .env_remove("PINNED_CONFIG_PATH")
            .stdin(Stdio::null())
            .stdout(File::create(root.join("output")).unwrap())
            .stderr(File::create(root.join("errors")).unwrap())
            .spawn()
            .unwrap(),
    );
    let endpoint = Endpoint::from_shared(format!("https://{health_addr}"))
        .unwrap()
        .connect_timeout(Duration::from_millis(200))
        .timeout(Duration::from_secs(1));
    let tls = ClientTlsConfig::new()
        .domain_name("localhost")
        .ca_certificate(TlsCertificate::from_pem(&ca_pem));
    let authenticated = endpoint
        .clone()
        .tls_config(tls.clone().identity(Identity::from_pem(cert_pem, key_pem)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut client = loop {
        assert!(
            collector.0.try_wait().unwrap().is_none(),
            "collector exited"
        );
        if let Ok(channel) = authenticated.connect().await {
            break HealthClient::new(channel);
        }
        assert!(
            Instant::now() < deadline,
            "mTLS health listener never became ready: {}",
            fs::read_to_string(root.join("errors")).unwrap()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    for service in ["", "log-collector", "flowgger"] {
        let response = client
            .check(HealthCheckRequest {
                service: service.into(),
            })
            .await
            .expect("unified authenticated health check");
        assert_eq!(response.into_inner().status, 1);
    }
    if let Ok(channel) = endpoint.tls_config(tls).unwrap().connect().await {
        assert!(
            HealthClient::new(channel)
                .check(HealthCheckRequest {
                    service: "flowgger".into()
                })
                .await
                .is_err(),
            "health must require a client certificate"
        );
    }
    let sender = UdpSocket::bind("127.0.0.1:0").unwrap();
    let marker = "synthetic-collector-health-probe";
    loop {
        sender
            .send_to(
                format!("<14>1 2025-01-01T00:00:00Z host01.example.com fixture - - - {marker}")
                    .as_bytes(),
                input_addr,
            )
            .unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        if fs::read_to_string(root.join("output"))
            .unwrap()
            .contains(marker)
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "syslog pipeline did not deliver the probe"
        );
    }
    let errors = fs::read_to_string(root.join("errors")).unwrap();
    assert!(!errors.contains("Address already in use"), "{errors}");
    assert!(collector.0.try_wait().unwrap().is_none());

    drop(collector);
    let _occupied = TcpListener::bind(health_addr).unwrap();
    let mut collector = Collector(
        Command::new(binary)
            .arg("--config")
            .arg(root.join("collector.toml"))
            .env_remove("PINNED_CONFIG_PATH")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(File::create(root.join("errors")).unwrap())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = collector.0.try_wait().unwrap() {
            assert!(
                !status.success(),
                "a failed health listener must fail startup"
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "collector ignored its occupied health port"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        fs::read_to_string(root.join("errors"))
            .unwrap()
            .contains("log collector service failed")
    );
}
