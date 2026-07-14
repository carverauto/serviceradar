use tls_codec_derive::{TlsDeserialize, TlsSerialize, TlsSize};

struct NonDefaultField {}

#[derive(TlsDeserialize, TlsSerialize, TlsSize)]
struct StructWithNonDefaultField {
    #[tls_codec(skip)]
    a: NonDefaultField,
    b: u8,
}

fn main() {}
