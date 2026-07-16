# tokio-postgres-rustls
This is an integration between the [rustls TLS stack](https://github.com/ctz/rustls)
and the [tokio-postgres asynchronous PostgreSQL client library](https://github.com/sfackler/rust-postgres).

[![Crate](https://img.shields.io/crates/v/tokio-postgres-rustls.svg)](https://crates.io/crates/tokio-postgres-rustls)

[API Documentation](https://docs.rs/tokio-postgres-rustls/)

# Features

This crate has no default features. Enable the rustls crypto provider that your
application uses, either `ring` or `aws-lc-rs`. The optional `webpki-roots` and
`native-certs` features add convenience constructors for common root stores.

# Example

```no_run
let config = rustls::ClientConfig::builder()
    .with_root_certificates(rustls::RootCertStore::empty())
    .with_no_client_auth();
let tls = tokio_postgres_rustls::MakeRustlsConnect::new(config);
let connect_fut = tokio_postgres::connect("sslmode=require host=localhost user=postgres", tls);
// ...
```

# License
tokio-postgres-rustls is distributed under the MIT license.
