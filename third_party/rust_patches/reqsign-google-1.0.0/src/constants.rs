use percent_encoding::AsciiSet;
use percent_encoding::NON_ALPHANUMERIC;

// Env values used in google services.
pub const GOOGLE_APPLICATION_CREDENTIALS: &str = "GOOGLE_APPLICATION_CREDENTIALS";
pub const GOOGLE_SCOPE: &str = "GOOGLE_SCOPE";

// Default OAuth2 scope for Google Cloud services
pub const DEFAULT_SCOPE: &str = "https://www.googleapis.com/auth/cloud-platform";

/// AsciiSet for [Google UriEncode](https://cloud.google.com/storage/docs/authentication/canonical-requests)
///
/// - URI encode every byte except the unreserved characters: 'A'-'Z', 'a'-'z', '0'-'9', '-', '.', '_', and '~'.
pub static GOOG_URI_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'/')
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// AsciiSet for [Google UriEncode](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html)
///
/// But used in query.
pub static GOOG_QUERY_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');
