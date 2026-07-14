pub mod body_reader;
pub mod buffers;
pub mod chunked_reader;
pub mod compressed_reader;
pub mod response;
pub mod response_reader;
#[cfg(feature = "charsets")]
pub mod text_reader;

pub use self::response::{parse_response, Response};
pub use self::response_reader::ResponseReader;
#[cfg(feature = "charsets")]
pub use self::text_reader::TextReader;
