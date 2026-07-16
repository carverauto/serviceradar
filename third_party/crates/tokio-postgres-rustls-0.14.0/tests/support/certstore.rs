use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

pub(crate) struct CertStore<'a> {
    pub roots: rustls::RootCertStore,
    pub client_certs: Vec<CertificateDer<'a>>,
    pub client_key: PrivateKeyDer<'a>,
}

impl CertStore<'_> {
    pub(crate) fn roots() -> rustls::RootCertStore {
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(CertificateDer::from_pem_file("tests/support/ca.crt").expect("load ca cert"))
            .expect("add root ca");
        roots
    }

    pub(crate) fn sha256<'a>() -> CertStore<'a> {
        let client_certs = vec![
            CertificateDer::from_pem_file("tests/support/client.crt").expect("load client cert"),
        ];
        let client_key =
            PrivateKeyDer::from_pem_file("tests/support/client.key").expect("load client key");

        CertStore {
            roots: CertStore::roots(),
            client_certs,
            client_key,
        }
    }

    pub(crate) fn sha384<'a>() -> CertStore<'a> {
        let client_certs = vec![
            CertificateDer::from_pem_file("tests/support/client_sha384.crt")
                .expect("load client cert"),
        ];
        let client_key =
            PrivateKeyDer::from_pem_file("tests/support/client.key").expect("load client key");

        CertStore {
            roots: CertStore::roots(),
            client_certs,
            client_key,
        }
    }

    pub(crate) fn sha512<'a>() -> CertStore<'a> {
        let client_certs = vec![
            CertificateDer::from_pem_file("tests/support/client_sha512.crt")
                .expect("load client cert"),
        ];
        let client_key =
            PrivateKeyDer::from_pem_file("tests/support/client.key").expect("load client key");

        CertStore {
            roots: CertStore::roots(),
            client_certs,
            client_key,
        }
    }
}
