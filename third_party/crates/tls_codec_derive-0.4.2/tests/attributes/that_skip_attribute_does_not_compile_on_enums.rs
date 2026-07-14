use tls_codec_derive::{TlsDeserialize, TlsSerialize, TlsSize};

#[derive(TlsDeserialize, TlsSerialize, TlsSize)]
#[repr(u8)]
enum EnumWithSkip {
    #[tls_codec(skip)]
    A,
    B,
}

fn main() {}
