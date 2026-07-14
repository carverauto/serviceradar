use tls_codec_derive::{TlsDeserialize, TlsSerialize, TlsSize};

#[derive(TlsDeserialize, TlsSerialize, TlsSize)]
struct StructWithDuplicateSkip {
    #[tls_codec(skip, skip)]
    a: u8,
}

fn main() {}
