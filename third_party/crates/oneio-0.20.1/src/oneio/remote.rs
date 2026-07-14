//! This module provides functionality to handle remote file operations such as downloading files
//! from HTTP, FTP, and S3 protocols.
use crate::oneio::{get_protocol, get_writer_raw};
use crate::OneIoError;
#[cfg(feature = "http")]
use reqwest::blocking::Client;
use std::io::Read;

#[cfg(feature = "ftp")]
pub(crate) fn get_ftp_reader_raw(path: &str) -> Result<Box<dyn Read + Send>, OneIoError> {
    if !path.starts_with("ftp://") {
        return Err(OneIoError::NotSupported(path.to_string()));
    }

    #[cfg(feature = "rustls")]
    super::crypto::ensure_default_provider()?;

    let parts = path.split('/').collect::<Vec<&str>>();
    let socket = match parts[2].contains(':') {
        true => parts[2].to_string(),
        false => format!("{}:21", parts[2]),
    };
    let path = parts[3..].join("/");

    let mut ftp_stream = suppaftp::FtpStream::connect(socket)?;
    // use anonymous login
    ftp_stream.login("anonymous", "oneio")?;
    ftp_stream.transfer_type(suppaftp::types::FileType::Binary)?;
    let reader = Box::new(ftp_stream.retr_as_stream(path.as_str())?);
    Ok(reader)
}

#[cfg(feature = "http")]
pub(crate) fn get_http_reader_raw(
    path: &str,
    opt_client: Option<Client>,
) -> Result<reqwest::blocking::Response, OneIoError> {
    dotenvy::dotenv().ok();

    #[cfg(feature = "rustls")]
    super::crypto::ensure_default_provider()?;

    let client = match opt_client {
        Some(c) => c,
        None => {
            let mut headers = reqwest::header::HeaderMap::new();
            headers.insert(
                reqwest::header::USER_AGENT,
                reqwest::header::HeaderValue::from_static("oneio"),
            );
            headers.insert(
                reqwest::header::CONTENT_LENGTH,
                reqwest::header::HeaderValue::from_static("0"),
            );
            #[cfg(feature = "cli")]
            headers.insert(
                reqwest::header::CACHE_CONTROL,
                reqwest::header::HeaderValue::from_static("no-cache"),
            );

            #[cfg(any(feature = "rustls", feature = "native-tls"))]
            {
                let accept_invalid_certs = matches!(
                    std::env::var("ONEIO_ACCEPT_INVALID_CERTS")
                        .unwrap_or_default()
                        .to_lowercase()
                        .as_str(),
                    "true" | "yes" | "y" | "1"
                );
                Client::builder()
                    .default_headers(headers)
                    .danger_accept_invalid_certs(accept_invalid_certs)
                    .build()?
            }

            #[cfg(not(any(feature = "rustls", feature = "native-tls")))]
            {
                Client::builder().default_headers(headers).build()?
            }
        }
    };
    let res = client
        .execute(client.get(path).build()?)?
        .error_for_status()?;
    Ok(res)
}

/// Creates a reqwest blocking client with custom headers.
///
/// # Arguments
///
/// * `headers_map` - A argument of header key-value pairs.
///
/// # Returns
///
/// Returns a Result containing the constructed Client or a [OneIoError].
///
/// # Example
///
/// Example usage with custom header fields:
/// ```no_run
/// use std::collections::HashMap;
/// use reqwest::header::HeaderMap;
///
/// let client = oneio::create_client_with_headers([("X-Custom-Auth-Key", "TOKEN")]).unwrap();
/// let mut reader = oneio::get_http_reader(
///   "https://SOME_REMOTE_RESOURCE_PROTECTED_BY_ACCESS_TOKEN",
///   Some(client),
/// ).unwrap();
/// let mut text = "".to_string();
/// reader.read_to_string(&mut text).unwrap();
/// println!("{}", text);
/// ```
#[cfg(feature = "http")]
pub fn create_client_with_headers<I, K, V>(headers: I) -> Result<Client, OneIoError>
where
    I: IntoIterator<Item = (K, V)>,
    K: Into<String>,
    V: Into<String>,
{
    #[cfg(feature = "rustls")]
    super::crypto::ensure_default_provider()?;

    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
    let mut header_map = HeaderMap::new();
    for (k, v) in headers {
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(k.into().as_bytes()),
            HeaderValue::from_str(&v.into()),
        ) {
            header_map.insert(name, value);
        }
    }
    Ok(Client::builder().default_headers(header_map).build()?)
}

/// Get a reader for remote content with the capability to specify headers, and customer reqwest options.
///
/// See [`create_client_with_headers`] for more details on how to create a client with custom headers.
///
/// Example with customer builder that allows invalid certificates (bad practice):
/// ```no_run
/// use std::collections::HashMap;
/// let client = reqwest::blocking::ClientBuilder::new().danger_accept_invalid_certs(true).build().unwrap();
/// let mut reader = oneio::get_http_reader(
///     "https://example.com",
///     Some(client)
/// ).unwrap();
/// let mut text = "".to_string();
/// reader.read_to_string(&mut text).unwrap();
/// println!("{}", text);
/// ```
#[cfg(feature = "http")]
pub fn get_http_reader(
    path: &str,
    opt_client: Option<Client>,
) -> Result<Box<dyn Read + Send>, OneIoError> {
    use crate::oneio::compressions::get_compression_reader;

    let raw_reader: Box<dyn Read + Send> = Box::new(get_http_reader_raw(path, opt_client)?);
    let file_type = path.rsplit('.').next().unwrap_or("");
    get_compression_reader(raw_reader, file_type)
}

/// Downloads a file from a remote location to a local path.
///
/// # Arguments
///
/// * `remote_path` - The remote path of the file to download.
/// * `local_path` - The local path where the downloaded file will be saved.
/// * `opt_client` - Optional custom [Client] to use for the request.
///
/// # Errors
///
/// Returns an `Err` variant of `OneIoError` if any of the following occur:
///
/// * The protocol of the remote path is not supported.
/// * An error occurs while downloading the file.
///
/// # Example
///
/// ```rust,no_run
/// use std::collections::HashMap;
/// use crate::oneio::{download, OneIoError};
///
/// fn main() -> Result<(), OneIoError> {
///     let remote_path = "https://example.com/file.txt";
///     let local_path = "path/to/save/file.txt";
///     download(remote_path, local_path, None)?;
///
///     Ok(())
/// }
/// ```
pub fn download(
    remote_path: &str,
    local_path: &str,
    // FIXME: the Client is only useful for `http` feature, but `ftp` feature has to depend on it too
    opt_client: Option<Client>,
) -> Result<(), OneIoError> {
    match get_protocol(remote_path) {
        None => {
            return Err(OneIoError::NotSupported(remote_path.to_string()));
        }
        Some(protocol) => match protocol.as_str() {
            #[cfg(feature = "http")]
            "http" | "https" => {
                let mut writer = get_writer_raw(local_path)?;
                let mut response = get_http_reader_raw(remote_path, opt_client)?;
                response.copy_to(&mut writer)?;
            }
            #[cfg(feature = "ftp")]
            "ftp" => {
                let mut writer = get_writer_raw(local_path)?;
                let mut reader = get_ftp_reader_raw(remote_path)?;
                std::io::copy(&mut reader, &mut writer)?;
            }
            #[cfg(feature = "s3")]
            "s3" => {
                let (bucket, path) = crate::oneio::s3::s3_url_parse(remote_path)?;
                crate::oneio::s3::s3_download(bucket.as_str(), path.as_str(), local_path)?;
            }
            _ => {
                return Err(OneIoError::NotSupported(remote_path.to_string()));
            }
        },
    };
    Ok(())
}

/// Downloads a file from a remote path and saves it locally with retry mechanism.
///
/// # Arguments
///
/// * `remote_path` - The URL or file path of the file to download.
/// * `local_path` - The file path to save the downloaded file.
/// * `opt_client` - Optional custom [Client] to use for the request.
/// * `retry` - The number of times to retry downloading in case of failure.
///
/// # Errors
///
/// Returns an `Err` variant if downloading fails after all retries, otherwise `Ok(())` indicating success.
///
/// # Examples
///
/// ```rust,no_run
/// use oneio::download_with_retry;
///
/// let remote_path = "https://example.com/file.txt";
/// let local_path = "/path/to/save/file.txt";
/// let retry = 3;
///
/// match download_with_retry(remote_path, local_path, retry, None) {
///     Ok(_) => println!("File downloaded successfully"),
///     Err(e) => eprintln!("Error downloading file: {:?}", e),
/// }
/// ```
pub fn download_with_retry(
    remote_path: &str,
    local_path: &str,
    retry: usize,
    opt_client: Option<Client>,
) -> Result<(), OneIoError> {
    let mut retry = retry;
    loop {
        match download(remote_path, local_path, opt_client.clone()) {
            Ok(_) => {
                return Ok(());
            }
            Err(e) => {
                if retry > 0 {
                    retry -= 1;
                    continue;
                } else {
                    return Err(e);
                }
            }
        }
    }
}

/// Check if a remote or local file exists.
///
/// # Arguments
///
/// * `path` - The path of the file to check.
///
/// # Returns
///
/// Returns a `Result` containing a `bool` indicating whether the file exists or not. If the path is not supported,
/// an `Err` variant with a `OneIoError::NotSupported` error is returned. If there is an error during the file check,
/// an `Err` variant with a `OneIoError` is returned.
pub(crate) fn remote_file_exists(path: &str) -> Result<bool, OneIoError> {
    match get_protocol(path) {
        Some(protocol) => match protocol.as_str() {
            "http" | "https" => {
                #[cfg(feature = "rustls")]
                super::crypto::ensure_default_provider()?;

                let client = Client::builder()
                    .timeout(std::time::Duration::from_secs(2))
                    .build()?;
                let res = client.head(path).send()?;
                Ok(res.status().is_success())
            }
            #[cfg(feature = "s3")]
            "s3" => {
                let (bucket, path) = crate::oneio::s3::s3_url_parse(path)?;
                let res = crate::oneio::s3::s3_exists(bucket.as_str(), path.as_str())?;
                Ok(res)
            }
            _ => Err(OneIoError::NotSupported(path.to_string())),
        },
        None => {
            // check if local file exists
            Ok(std::path::Path::new(path).exists())
        }
    }
}
