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

use std::io::{BufReader, Cursor};
use std::sync::Once;

use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::certs;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_postgres::tls::MakeTlsConnect;
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::MigratorError;

static CRYPTO_PROVIDER: Once = Once::new();

fn ensure_crypto_provider() {
    CRYPTO_PROVIDER.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[derive(Clone)]
pub struct PgRustlsConnect {
    inner: MakeRustlsConnect,
    server_name: Option<String>,
}

impl PgRustlsConnect {
    pub fn new(config: ClientConfig, server_name: Option<String>) -> Self {
        Self {
            inner: MakeRustlsConnect::new(config),
            server_name,
        }
    }
}

impl<S> MakeTlsConnect<S> for PgRustlsConnect
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    type Stream = <MakeRustlsConnect as MakeTlsConnect<S>>::Stream;
    type TlsConnect = <MakeRustlsConnect as MakeTlsConnect<S>>::TlsConnect;
    type Error = <MakeRustlsConnect as MakeTlsConnect<S>>::Error;

    fn make_tls_connect(&mut self, hostname: &str) -> Result<Self::TlsConnect, Self::Error> {
        let hostname = self.server_name.as_deref().unwrap_or(hostname);
        <MakeRustlsConnect as MakeTlsConnect<S>>::make_tls_connect(&mut self.inner, hostname)
    }
}

pub fn postgres_connector(
    ca_pem: &[u8],
    client_cert_pem: Option<&[u8]>,
    client_key_pem: Option<&[u8]>,
    server_name: Option<&str>,
) -> Result<PgRustlsConnect, MigratorError> {
    ensure_crypto_provider();

    let mut root_store = RootCertStore::empty();
    let mut reader = BufReader::new(Cursor::new(ca_pem));
    let mut added = 0usize;
    for cert in certs(&mut reader) {
        let cert = cert.map_err(|err| MigratorError::Postgres(err.to_string()))?;
        root_store
            .add(cert)
            .map_err(|_| MigratorError::Postgres("invalid certificate in the CA bundle".into()))?;
        added += 1;
    }
    if added == 0 {
        return Err(MigratorError::Postgres(
            "the CA bundle contained no certificates".into(),
        ));
    }

    let builder = ClientConfig::builder().with_root_certificates(root_store);
    let config = match (client_cert_pem, client_key_pem) {
        (Some(cert_pem), Some(key_pem)) => {
            let certs = rustls_pemfile::certs(&mut BufReader::new(Cursor::new(cert_pem)))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|err| MigratorError::Postgres(err.to_string()))?;
            if certs.is_empty() {
                return Err(MigratorError::Postgres(
                    "the client certificate contained no certificates".into(),
                ));
            }
            // CNPG runtime certs ship PKCS#1 (`BEGIN RSA PRIVATE KEY`). Accept
            // PKCS#8, PKCS#1, and SEC1 the same way `rust/srql` does.
            let key = rustls_pemfile::private_key(&mut BufReader::new(Cursor::new(key_pem)))
                .map_err(|err| MigratorError::Postgres(err.to_string()))?
                .ok_or_else(|| {
                    MigratorError::Postgres("client key PEM contained no private key".into())
                })?;
            builder
                .with_client_auth_cert(certs, key)
                .map_err(|err| MigratorError::Postgres(err.to_string()))?
        }
        _ => builder.with_no_client_auth(),
    };

    Ok(PgRustlsConnect::new(
        config,
        server_name.map(str::to_string),
    ))
}

#[cfg(test)]
mod tests {
    use super::postgres_connector;

    // Invented PEMs for host01.example.com / ca.example.com. Not a live dump.
    const PKCS1_KEY: &str = r#"-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0LJQE5sBq6//QcmTEvAHqwmjUZ90xIHL8GCjc6qwM+ciolWv
FkPcaGTqcUPRCZq2o6Rt2c4ulkGbeCAPxVY3icb9K020UTZKMk0I0uCgpb07d78S
k+A8EEcb5dICC7p0PWgsDwyHpUkk4ZvefyY8Da4bp3tLNHlfUHSNdZveT2Jabav7
AYpOsUG0PHsO+a22rX7BjSYmI6c9UlGoJ/MaQiaByskmbccQwAlJRcWQHR/cshC0
XKebQOHB00pK93styF52d4Ul1tf4ohQto3duchX5sLXDfIKRnAxnizT2xzjXWSMU
86OJnYK3NpJmvCd3xvpg3E9OVIAZFUOvwdI2xQIDAQABAoIBAC7Rziaz1/pbO94X
uZveRy4fNaleZ10djHHzUEAnCyw9vraiF+tcEpLGDxWVhAxOTgqk3TMnryps8hLP
SJJ6Pu/1OT9xiZJNpnQl9aSPmeLM8w4witurivYQ6eiThnt4m1Lab8X5huX1JKXL
qO0oGAFurcwTXEIbt58uYrz/mK6Ap7A0Z2eaoVne0MJj0prs+8Z/BjFkuTULjXZd
fc29gHAW8KdcmCT/YK+BZvNPI5VLDmVIlwGSPv0/5iB4iEZw0Y57fESSQVeRctES
eoyBzqmn/Gvr5+07HeojxS0Sryl58NinC2s/LGBsjpCX0cBUUMWoKci5mHmB1wzP
8iy5MakCgYEA7Onq9rLj+MqFuXOjj/W1v/Ty4WLnjlPA3zMj3hcy3yDvVwCq9e2R
nJo1CQ1jpi6NuwncQQE2i0A0ey9kQdmnpkgFKpNaIFszU1x1XKxfLIWndl7GoUVW
W2HxgFyAbHkfHUJNndhEi4zuoOAwjpNaCjZ4PXXkM6hvcRqZ7nBolx0CgYEA4YJy
TQpHGCM6dvhQOYRGIU9uWLC3ciix78AaYG3NbihTcaHsS8z/l3yjVD6P5Ct5fHvR
fq0lY+I1VC4bCFZ6Xkuw0zomqUqCzbgP+Q0zkJg6/YjRnn08lcKzefLOmftFbdU+
73ksz0uTKQfYJ8EhyTPp/LIfSkYhpiTX0WvABckCgYBiS19AQdKSK7y1yAPJu+FP
plqLJtT52UgBkx9Diw6BQxHqYA2OgaXTequceOCqV1BYlOu8ULuHpPjhTzVimOKU
+/agxogzOoOeB5NuAtpuB3oGg6YXzUPaIFXpsvdZihtdsV+wqMUvvSZYuwuKbBqE
eDsFDP/EaxLps2bAZgUPBQKBgFpyBD/r6FnA/1jp/Nskty/y+LHvppPNyJf891dH
ksYkvFrt86TvQm/SmHtYYEPGQAJycrKY5U8rUfJCT6tHa+rX9sKxJwJtFQtHUHi2
F8FdnQNE1bX4Ss1R+sPlY4GUquMDTSuk8RjvGcWyFLrVFiTpgmZMVopmmGZXjou6
6JgpAoGBAJjTYb0fh/Et5OLm/vYm3OW39S0XvOpgf7oPGPbbu8cUVU3lpA1TTgrJ
XfUDJ2CRdZaDqcqdk0es5dCwiaiYJdaMGzHxGlN7LYdewXPGNiUAbxki0tP+FfNV
h9Kz2FbO1Ski3DRmCnYdhfdSs0pvCr3cmhxOoCtVzLaJZR4X5TXl
-----END RSA PRIVATE KEY-----
"#;

    const PKCS8_KEY: &str = r#"-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDQslATmwGrr/9B
yZMS8AerCaNRn3TEgcvwYKNzqrAz5yKiVa8WQ9xoZOpxQ9EJmrajpG3Zzi6WQZt4
IA/FVjeJxv0rTbRRNkoyTQjS4KClvTt3vxKT4DwQRxvl0gILunQ9aCwPDIelSSTh
m95/JjwNrhune0s0eV9QdI11m95PYlptq/sBik6xQbQ8ew75rbatfsGNJiYjpz1S
Uagn8xpCJoHKySZtxxDACUlFxZAdH9yyELRcp5tA4cHTSkr3ey3IXnZ3hSXW1/ii
FC2jd25yFfmwtcN8gpGcDGeLNPbHONdZIxTzo4mdgrc2kma8J3fG+mDcT05UgBkV
Q6/B0jbFAgMBAAECggEALtHOJrPX+ls73he5m95HLh81qV5nXR2McfNQQCcLLD2+
tqIX61wSksYPFZWEDE5OCqTdMyevKmzyEs9Ikno+7/U5P3GJkk2mdCX1pI+Z4szz
DjCK26uK9hDp6JOGe3ibUtpvxfmG5fUkpcuo7SgYAW6tzBNcQhu3ny5ivP+YroCn
sDRnZ5qhWd7QwmPSmuz7xn8GMWS5NQuNdl19zb2AcBbwp1yYJP9gr4Fm808jlUsO
ZUiXAZI+/T/mIHiIRnDRjnt8RJJBV5Fy0RJ6jIHOqaf8a+vn7Tsd6iPFLRKvKXnw
2KcLaz8sYGyOkJfRwFRQxagpyLmYeYHXDM/yLLkxqQKBgQDs6er2suP4yoW5c6OP
9bW/9PLhYueOU8DfMyPeFzLfIO9XAKr17ZGcmjUJDWOmLo27CdxBATaLQDR7L2RB
2aemSAUqk1ogWzNTXHVcrF8shad2XsahRVZbYfGAXIBseR8dQk2d2ESLjO6g4DCO
k1oKNng9deQzqG9xGpnucGiXHQKBgQDhgnJNCkcYIzp2+FA5hEYhT25YsLdyKLHv
wBpgbc1uKFNxoexLzP+XfKNUPo/kK3l8e9F+rSVj4jVULhsIVnpeS7DTOiapSoLN
uA/5DTOQmDr9iNGefTyVwrN58s6Z+0Vt1T7veSzPS5MpB9gnwSHJM+n8sh9KRiGm
JNfRa8AFyQKBgGJLX0BB0pIrvLXIA8m74U+mWosm1PnZSAGTH0OLDoFDEepgDY6B
pdN6q5x44KpXUFiU67xQu4ek+OFPNWKY4pT79qDGiDM6g54Hk24C2m4HegaDphfN
Q9ogVemy91mKG12xX7CoxS+9Jli7C4psGoR4OwUM/8RrEumzZsBmBQ8FAoGAWnIE
P+voWcD/WOn82yS3L/L4se+mk83Il/z3V0eSxiS8Wu3zpO9Cb9KYe1hgQ8ZAAnJy
spjlTytR8kJPq0dr6tf2wrEnAm0VC0dQeLYXwV2dA0TVtfhKzVH6w+VjgZSq4wNN
K6TxGO8ZxbIUutUWJOmCZkxWimaYZleOi7romCkCgYEAmNNhvR+H8S3k4ub+9ibc
5bf1LRe86mB/ug8Y9tu7xxRVTeWkDVNOCsld9QMnYJF1loOpyp2TR6zl0LCJqJgl
1owbMfEaU3sth17Bc8Y2JQBvGSLS0/4V81WH0rPYVs7VKSLcNGYKdh2F91KzSm8K
vdyaHE6gK1XMtollHhflNeU=
-----END PRIVATE KEY-----
"#;

    const CLIENT_CERT: &str = r#"-----BEGIN CERTIFICATE-----
MIIDGzCCAgOgAwIBAgIUK3C70/gNu/phf8CCXJrK3jND9icwDQYJKoZIhvcNAQEL
BQAwHTEbMBkGA1UEAwwSaG9zdDAxLmV4YW1wbGUuY29tMB4XDTI2MDkyMTA1NDAw
N1oXDTM2MDkxODA1NDAwN1owHTEbMBkGA1UEAwwSaG9zdDAxLmV4YW1wbGUuY29t
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0LJQE5sBq6//QcmTEvAH
qwmjUZ90xIHL8GCjc6qwM+ciolWvFkPcaGTqcUPRCZq2o6Rt2c4ulkGbeCAPxVY3
icb9K020UTZKMk0I0uCgpb07d78Sk+A8EEcb5dICC7p0PWgsDwyHpUkk4ZvefyY8
Da4bp3tLNHlfUHSNdZveT2Jabav7AYpOsUG0PHsO+a22rX7BjSYmI6c9UlGoJ/Ma
QiaByskmbccQwAlJRcWQHR/cshC0XKebQOHB00pK93styF52d4Ul1tf4ohQto3du
chX5sLXDfIKRnAxnizT2xzjXWSMU86OJnYK3NpJmvCd3xvpg3E9OVIAZFUOvwdI2
xQIDAQABo1MwUTAdBgNVHQ4EFgQU3X4wcXaFzDKOMaiE9+dEJtw5S4swHwYDVR0j
BBgwFoAU3X4wcXaFzDKOMaiE9+dEJtw5S4swDwYDVR0TAQH/BAUwAwEB/zANBgkq
hkiG9w0BAQsFAAOCAQEAdh+WUmDtHrXYRopNulBa1lb/u5bTz9qmfgiv4diF0TK3
OPJWwyOmaFmbWn4q1KCZTxsxfRaA5cvKJFsDPCAnFzKoPIJVYYRoGtkPvTHAU4wv
kbIFRLPEQqRjjxBWAARl1bV6Mdt+z8shzxzlOzyyn7MxDvrsLneyX4RI3jIBAeCg
xpBQPymgT6qyuWsvGM58L96vPi36GStBKG2xHasMCVe61CK/x2HXV3jTikGwpJzL
umtiM5oFRwMHGZXIimS4A9dx7N6axE6NyPkb4+rgIf6SEDwY9D/qYi7B8I7GVrs+
JO6OViSkBQr0CO4zpRCkA5juskxEZu3evWDmDlYbgw==
-----END CERTIFICATE-----
"#;

    const CA_CERT: &str = r#"-----BEGIN CERTIFICATE-----
MIIDEzCCAfugAwIBAgIUW5KuzrUnvSNgVIItLPkmG6/Kz5swDQYJKoZIhvcNAQEL
BQAwGTEXMBUGA1UEAwwOY2EuZXhhbXBsZS5jb20wHhcNMjYwOTIxMDU0MDA3WhcN
MzYwOTE4MDU0MDA3WjAZMRcwFQYDVQQDDA5jYS5leGFtcGxlLmNvbTCCASIwDQYJ
KoZIhvcNAQEBBQADggEPADCCAQoCggEBANCyUBObAauv/0HJkxLwB6sJo1GfdMSB
y/Bgo3OqsDPnIqJVrxZD3Ghk6nFD0QmatqOkbdnOLpZBm3ggD8VWN4nG/StNtFE2
SjJNCNLgoKW9O3e/EpPgPBBHG+XSAgu6dD1oLA8Mh6VJJOGb3n8mPA2uG6d7SzR5
X1B0jXWb3k9iWm2r+wGKTrFBtDx7Dvmttq1+wY0mJiOnPVJRqCfzGkImgcrJJm3H
EMAJSUXFkB0f3LIQtFynm0DhwdNKSvd7LchedneFJdbX+KIULaN3bnIV+bC1w3yC
kZwMZ4s09sc411kjFPOjiZ2CtzaSZrwnd8b6YNxPTlSAGRVDr8HSNsUCAwEAAaNT
MFEwHQYDVR0OBBYEFN1+MHF2hcwyjjGohPfnRCbcOUuLMB8GA1UdIwQYMBaAFN1+
MHF2hcwyjjGohPfnRCbcOUuLMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEL
BQADggEBAAcTasfsp/LKrngPJulLiPcGMMjzw0lmdyh0hwzPuiVfBz4cinkVnO5O
3dltC+f5lQSONosyaQLIZYL01Ch7d99zthc9JuxbF5pmAl1RFNAZPEMmXm6MVJ7d
/R0BYVFaXoxlqSjvTnUushnS8gCGU60dKkypgj+6BzYJqGidb9Sa5HShwjOtcxPM
am4bgEZLnPjt5uMKwxrnZdoQjJSvNkC5JemyNT/y9b5Sc/IthgKsZzIXWdYn44uE
4mqSODOan0TKqVlBFPaigmyDoMlWfkoB2awPcRlaqXfUl4eXZCr3QE4RZEM4ISco
hiLAw4qSBfpp0cf74kUge4NmHeSlwGk=
-----END CERTIFICATE-----
"#;

    #[test]
    fn accepts_pkcs1_rsa_client_key() {
        postgres_connector(
            CA_CERT.as_bytes(),
            Some(CLIENT_CERT.as_bytes()),
            Some(PKCS1_KEY.as_bytes()),
            Some("cnpg"),
        )
        .expect("PKCS#1 RSA client key");
    }

    #[test]
    fn accepts_pkcs8_client_key() {
        postgres_connector(
            CA_CERT.as_bytes(),
            Some(CLIENT_CERT.as_bytes()),
            Some(PKCS8_KEY.as_bytes()),
            Some("cnpg"),
        )
        .expect("PKCS#8 client key");
    }

    #[test]
    fn rejects_empty_client_key() {
        let err = match postgres_connector(
            CA_CERT.as_bytes(),
            Some(CLIENT_CERT.as_bytes()),
            Some(b"-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n"),
            Some("cnpg"),
        ) {
            Ok(_) => panic!("empty key should fail"),
            Err(err) => err,
        };
        let message = err.to_string();
        assert!(
            message.contains("no private key") || message.contains("failed to parse private key"),
            "{message}"
        );
    }
}
