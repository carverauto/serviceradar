//! To run this example enable the rustls feature (--features rustls).
//! If you use this code in your own project you need to enable suppaftp's
//! rustls feature through Cargo.toml and also include the webpki-roots crate
//! as a dependency (this includes Mozilla's root certificates for use with
//! rustls).

use std::sync::Arc;

use suppaftp::rustls::ClientConfig;
use suppaftp::{RustlsConnector, RustlsFtpStream, rustls};

fn main() {
    let root_store =
        rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

    let config = ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();

    // Create a connection to an FTP server and authenticate to it.
    let mut ftp_stream = RustlsFtpStream::connect("test.rebex.net:21")
        .unwrap()
        .into_secure(RustlsConnector::from(Arc::new(config)), "test.rebex.net")
        .unwrap();

    // Terminate the connection to the server.
    let _ = ftp_stream.quit();
}
