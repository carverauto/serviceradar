#![deny(
    clippy::pedantic,
    clippy::missing_docs_in_private_items,
    clippy::missing_errors_doc,
    rustdoc::broken_intra_doc_links,
    warnings
)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
// Required for AVX512 until stable
#![cfg_attr(
    all(feature = "nightly", target_arch = "x86_64"),
    feature(stdarch_x86_avx512)
)]
#![doc = include_str!("../README.md")]

// If the client or server implementation is enabled, at least one SHA1 backend
// is required.
#[cfg(all(
    any(feature = "client", feature = "server"),
    not(any(
        feature = "ring",
        feature = "aws_lc_rs",
        feature = "openssl",
        feature = "sha1_smol"
    ))
))]
compile_error!("client and server implementation require at least one SHA1 backend");

#[cfg(feature = "client")]
pub mod client;
pub mod error;
mod mask;
pub mod proto;
#[cfg(feature = "client")]
mod rand;
#[cfg(feature = "client")]
pub mod resolver;
#[cfg(feature = "server")]
pub mod server;
#[cfg(any(feature = "client", feature = "server"))]
mod sha;
pub mod tls;
#[cfg(any(feature = "client", feature = "server"))]
pub mod upgrade;
mod utf8;

#[cfg(feature = "client")]
pub use client::Builder as ClientBuilder;
pub use error::Error;
pub use proto::{CloseCode, Config, Limits, Message, Payload, WebSocketStream};
#[cfg(feature = "server")]
pub use server::Builder as ServerBuilder;
pub use tls::{Connector, MaybeTlsStream};
