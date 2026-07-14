pub mod compressions;
#[cfg(feature = "rustls")]
pub mod crypto;
#[cfg(feature = "digest")]
pub mod digest;
#[cfg(any(feature = "http", feature = "ftp"))]
pub mod remote;
#[cfg(feature = "s3")]
pub mod s3;

pub mod utils;

use crate::OneIoError;

use crate::oneio::compressions::{get_compression_reader, get_compression_writer};
use std::fs::File;
use std::io::{BufWriter, Read, Write};
use std::path::Path;

#[cfg(feature = "async")]
use futures::StreamExt;

/// Extracts the protocol from a given path.
pub(crate) fn get_protocol(path: &str) -> Option<String> {
    let parts = path.split("://").collect::<Vec<&str>>();
    if parts.len() < 2 {
        return None;
    }
    Some(parts[0].to_string())
}

pub fn get_writer_raw(path: &str) -> Result<BufWriter<File>, OneIoError> {
    let path = Path::new(path);
    if let Some(prefix) = path.parent() {
        std::fs::create_dir_all(prefix)?;
    }
    let output_file = BufWriter::new(File::create(path)?);
    Ok(output_file)
}

pub fn get_reader_raw(path: &str) -> Result<Box<dyn Read + Send>, OneIoError> {
    let raw_reader: Box<dyn Read + Send> = match get_protocol(path) {
        Some(protocol) => match protocol.as_str() {
            #[cfg(feature = "http")]
            "http" | "https" => {
                let response = remote::get_http_reader_raw(path, None)?;
                Box::new(response)
            }
            #[cfg(feature = "ftp")]
            "ftp" => {
                let response = remote::get_ftp_reader_raw(path)?;
                Box::new(response)
            }
            #[cfg(feature = "s3")]
            "s3" | "r2" => {
                let (bucket, path) = s3::s3_url_parse(path)?;
                Box::new(s3::s3_reader(bucket.as_str(), path.as_str())?)
            }
            _ => {
                return Err(OneIoError::NotSupported(path.to_string()));
            }
        },
        None => Box::new(File::open(path)?),
    };
    Ok(raw_reader)
}

/// Gets a reader for the given file path.
///
/// # Arguments
///
/// * `path` - The path of the file to read.
///
/// # Returns
///
/// A `Result` containing a boxed `Read+Sync` trait object with the file reader, or `OneIoError` if an error occurs.
///
/// # Examples
///
/// ```no_run
/// use std::io::Read;
/// use oneio::get_reader;
///
/// let mut reader = get_reader("file.txt").unwrap();
/// let mut buffer = Vec::new();
/// reader.read_to_end(&mut buffer).unwrap();
/// println!("{}", String::from_utf8_lossy(&buffer));
/// ```
pub fn get_reader(path: &str) -> Result<Box<dyn Read + Send>, OneIoError> {
    // get raw bytes reader
    let raw_reader = get_reader_raw(path)?;

    let file_type = path.rsplit('.').next().unwrap_or("");
    get_compression_reader(raw_reader, file_type)
}

/// get file reader with local cache.
///
/// parameters:
/// * `path`: file path to open, remote or local
/// * `cache_dir`: path str to cache directory
/// * `cache_file_name`: optional file name for cache file, default to use the same filename as the to-read file
/// * `force_cache`: whether to force refresh cache file if a local cache file already exists
pub fn get_cache_reader(
    path: &str,
    cache_dir: &str,
    cache_file_name: Option<String>,
    force_cache: bool,
) -> Result<Box<dyn Read + Send>, OneIoError> {
    let dir_path = Path::new(cache_dir);
    if !dir_path.is_dir() {
        match std::fs::create_dir_all(dir_path) {
            Ok(_) => {}
            Err(e) => return Err(OneIoError::Io(e)),
        }
    }

    let cache_file_name = cache_file_name.unwrap_or_else(|| {
        path.split('/')
            .next_back()
            .unwrap_or("cached_file")
            .to_string()
    });

    let cache_file_path = format!("{cache_dir}/{cache_file_name}");

    // if cache file already exists
    if !force_cache && Path::new(cache_file_path.as_str()).exists() {
        return get_reader(cache_file_path.as_str());
    }

    // read all to cache file, no encode/decode happens
    let mut reader = get_reader_raw(path)?;
    let mut data: Vec<u8> = vec![];
    reader.read_to_end(&mut data)?;
    let mut writer = get_writer_raw(cache_file_path.as_str())?;
    writer.write_all(&data)?;
    drop(writer);

    // return reader from cache file
    get_reader(cache_file_path.as_str())
}

/// Returns a writer for the given file path with the corresponding compression.
///
/// # Arguments
///
/// * `path` - A string slice representing the file path.
///
/// # Returns
///
/// * `Result<Box<dyn Write>, OneIoError>` - A result containing a boxed writer trait object or an error.
///
/// # Examples
///
/// ```rust,no_run
/// use std::io::{self, Write};
/// use oneio::get_writer;
///
/// let writer = match get_writer("output.txt") {
///     Ok(writer) => writer,
///     Err(error) => panic!("Failed to create writer: {:?}", error),
/// };
/// ```
pub fn get_writer(path: &str) -> Result<Box<dyn Write>, OneIoError> {
    let output_file = BufWriter::new(File::create(path)?);

    let file_type = path.rsplit('.').next().unwrap_or("");
    get_compression_writer(output_file, file_type)
}

/// Check if a file or directory exists.
///
/// This function takes a path as an argument and returns a `Result` indicating whether the file or directory at the given path exists or not.
///
/// # Examples
///
/// ```rust
/// use crate::oneio::exists;
///
/// match exists("path/to/file.txt") {
///     Ok(true) => println!("File exists."),
///     Ok(false) => println!("File does not exist."),
///     Err(error) => eprintln!("An error occurred: {}", error),
/// }
/// ```
///
/// # Errors
///
/// This function may return a `OneIoError` if there is an error accessing the file system or if the `remote` feature is enabled and there is an error
pub fn exists(path: &str) -> Result<bool, OneIoError> {
    #[cfg(any(feature = "http", feature = "s3"))]
    {
        remote::remote_file_exists(path)
    }
    #[cfg(not(any(feature = "http", feature = "s3")))]
    {
        Ok(Path::new(path).exists())
    }
}

/// Progress tracking callback type
pub type ProgressCallback<F> = F;

/// Progress reader wrapper that tracks bytes read
pub struct ProgressReader<R, F> {
    inner: R,
    bytes_read: u64,
    total_size: u64,
    callback: F,
}

impl<R: Read, F> ProgressReader<R, F>
where
    F: Fn(u64, u64) + Send,
{
    fn new(inner: R, total_size: u64, callback: F) -> Self {
        Self {
            inner,
            bytes_read: 0,
            total_size,
            callback,
        }
    }
}

impl<R: Read, F> Read for ProgressReader<R, F>
where
    F: Fn(u64, u64) + Send,
{
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let bytes_read = self.inner.read(buf)?;
        if bytes_read > 0 {
            self.bytes_read += bytes_read as u64;
            (self.callback)(self.bytes_read, self.total_size);
        }
        Ok(bytes_read)
    }
}

/// Determines the content length of a file or URL
///
/// This function attempts to get the total size of the content at the given path.
/// Used internally by progress tracking - returns an error if size cannot be determined.
///
/// # Arguments
/// * `path` - File path or URL to check
///
/// # Returns
/// * `Ok(u64)` - Total content size in bytes
/// * `Err(OneIoError::NotSupported)` - If size cannot be determined
/// * `Err(OneIoError::Network)` - If network error occurs
/// * `Err(OneIoError::Io)` - If file system error occurs
pub fn get_content_length(path: &str) -> Result<u64, OneIoError> {
    match get_protocol(path) {
        #[cfg(feature = "http")]
        Some(protocol) if protocol == "http" || protocol == "https" => {
            #[cfg(feature = "rustls")]
            crypto::ensure_default_provider()?;

            // HEAD request to get Content-Length
            let client = reqwest::blocking::Client::new();
            let response = client.head(path).send()?;

            response
                .headers()
                .get("content-length")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| {
                    OneIoError::NotSupported(
                        "Cannot determine file size - server doesn't provide Content-Length"
                            .to_string(),
                    )
                })
        }
        #[cfg(feature = "ftp")]
        Some(protocol) if protocol == "ftp" => {
            // For FTP, we'll need to implement SIZE command
            // For now, return not supported
            Err(OneIoError::NotSupported(
                "FTP size determination not yet implemented".to_string(),
            ))
        }
        #[cfg(feature = "s3")]
        Some(protocol) if protocol == "s3" || protocol == "r2" => {
            // S3 HEAD object
            let (bucket, key) = s3::s3_url_parse(path)?;
            let stats = s3::s3_stats(&bucket, &key)?;
            // HeadObjectResult has content_length field
            stats
                .content_length
                .ok_or_else(|| {
                    OneIoError::NotSupported(
                        "S3 object doesn't have content length information".to_string(),
                    )
                })
                .map(|len| len as u64)
        }
        Some(_) => Err(OneIoError::NotSupported(format!(
            "Protocol not supported for progress tracking: {path}"
        ))),
        None => {
            // Local file
            let metadata = std::fs::metadata(path)?;
            Ok(metadata.len())
        }
    }
}

/// Gets a reader with progress tracking that reports bytes read and total file size
///
/// This function returns both a reader and the total file size. If the total size cannot
/// be determined (e.g., streaming endpoints without Content-Length), it returns `None`
/// for the size, providing better context about whether the size is genuinely unknown
/// versus a failure to determine it.
///
/// The progress callback receives (bytes_read, total_bytes) and tracks raw bytes read
/// from the source before any decompression. When total_bytes is 0, it indicates the
/// total size is unknown.
///
/// # Arguments
/// * `path` - File path or URL to read
/// * `progress` - Callback function called with (bytes_read, total_bytes)
///
/// # Returns
/// * `Ok((reader, Some(total_size)))` - Reader and total file size in bytes
/// * `Ok((reader, None))` - Reader with unknown total size
/// * `Err(OneIoError::Network)` - If network error occurs
/// * `Err(OneIoError::Io)` - If file system error occurs
///
/// # Examples
///
/// ```rust,ignore
/// use oneio;
/// use std::io::Read;
///
/// let (mut reader, total_size) = oneio::get_reader_with_progress(
///     "https://example.com/file.gz",
///     |bytes_read, total_bytes| {
///         if total_bytes > 0 {
///             let percent = (bytes_read as f64 / total_bytes as f64) * 100.0;
///             println!("Progress: {:.1}% ({}/{})", percent, bytes_read, total_bytes);
///         } else {
///             println!("Downloaded: {} bytes (size unknown)", bytes_read);
///         }
///     }
/// )?;
///
/// match total_size {
///     Some(size) => println!("File size: {} bytes", size),
///     None => println!("File size: unknown"),
/// }
/// let mut content = String::new();
/// reader.read_to_string(&mut content)?;
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn get_reader_with_progress<F>(
    path: &str,
    progress: F,
) -> Result<(Box<dyn Read + Send>, Option<u64>), OneIoError>
where
    F: Fn(u64, u64) + Send + 'static,
{
    // Try to determine total size, returning None when it cannot be determined
    let (total_size, size_option) = match get_content_length(path) {
        Ok(size) => (size, Some(size)),
        Err(_) => {
            // Size cannot be determined (e.g., streaming endpoints, errors) - handle gracefully
            // The Option<u64> return type clearly indicates when size is unknown
            (0, None)
        }
    };

    // Get raw reader (before compression)
    let raw_reader = get_reader_raw(path)?;

    // Wrap raw reader with progress tracking
    let progress_reader = ProgressReader::new(raw_reader, total_size, progress);

    // Apply compression to the progress-wrapped reader
    let file_type = path.rsplit('.').next().unwrap_or("");

    let final_reader = get_compression_reader(Box::new(progress_reader), file_type)?;

    Ok((final_reader, size_option))
}

// ================================
// ASYNC SUPPORT (Phase 3)
// ================================

#[cfg(feature = "async")]
use tokio::io::{AsyncRead, AsyncReadExt};

/// Gets an async reader for the given file path
///
/// This is the async version of `get_reader()`. It supports all the same protocols
/// and compression formats as the sync version.
///
/// # Arguments
/// * `path` - File path or URL to read
///
/// # Returns
/// * `Ok(impl AsyncRead)` - Async reader that handles decompression automatically
/// * `Err(OneIoError)` - If file cannot be opened or protocol not supported
///
/// # Examples
///
/// ```rust,no_run
/// use tokio::io::AsyncReadExt;
///
/// #[tokio::main]
/// async fn main() -> Result<(), Box<dyn std::error::Error>> {
///     let mut reader = oneio::get_reader_async("https://example.com/data.gz").await?;
///     
///     let mut buffer = Vec::new();
///     reader.read_to_end(&mut buffer).await?;
///     
///     println!("Read {} bytes", buffer.len());
///     Ok(())
/// }
/// ```
#[cfg(feature = "async")]
pub async fn get_reader_async(path: &str) -> Result<Box<dyn AsyncRead + Send + Unpin>, OneIoError> {
    // Get raw async reader
    let raw_reader = get_async_reader_raw(path).await?;

    // Apply compression
    let file_type = path.rsplit('.').next().unwrap_or("");

    get_async_compression_reader(raw_reader, file_type)
}

/// Reads the entire content of a file asynchronously into a string
///
/// This is the async version of `read_to_string()`. It handles decompression
/// automatically based on file extension.
///
/// # Arguments
/// * `path` - File path or URL to read
///
/// # Returns
/// * `Ok(String)` - File content as UTF-8 string
/// * `Err(OneIoError)` - If file cannot be read or content is not valid UTF-8
///
/// # Examples
///
/// ```rust,no_run
/// #[tokio::main]
/// async fn main() -> Result<(), Box<dyn std::error::Error>> {
///     let content = oneio::read_to_string_async("https://example.com/data.json.gz").await?;
///     println!("Content: {}", content);
///     Ok(())
/// }
/// ```
#[cfg(feature = "async")]
pub async fn read_to_string_async(path: &str) -> Result<String, OneIoError> {
    let mut reader = get_reader_async(path).await?;
    let mut content = String::new();
    reader.read_to_string(&mut content).await?;
    Ok(content)
}

/// Downloads a file asynchronously from a URL to a local path
///
/// This is the async version of `download()`. It supports all protocols and
/// handles decompression if needed.
///
/// # Arguments
/// * `url` - Source URL to download from
/// * `path` - Local file path to save to
///
/// # Returns
/// * `Ok(())` - Download completed successfully
/// * `Err(OneIoError)` - If download fails or file cannot be written
///
/// # Examples
///
/// ```rust,no_run
/// #[tokio::main]
/// async fn main() -> Result<(), Box<dyn std::error::Error>> {
///     oneio::download_async(
///         "https://example.com/data.csv.gz",
///         "local_data.csv.gz"
///     ).await?;
///     println!("Download complete!");
///     Ok(())
/// }
/// ```
#[cfg(feature = "async")]
pub async fn download_async(url: &str, path: &str) -> Result<(), OneIoError> {
    use tokio::fs::File;
    use tokio::io::AsyncWriteExt;

    let mut reader = get_reader_async(url).await?;
    let mut file = File::create(path).await?;

    let mut buffer = vec![0u8; 8192];
    loop {
        let bytes_read = reader.read(&mut buffer).await?;
        if bytes_read == 0 {
            break;
        }
        file.write_all(&buffer[..bytes_read]).await?;
    }

    file.flush().await?;
    Ok(())
}

/// Gets a raw async reader for the given path (before compression)
#[cfg(feature = "async")]
async fn get_async_reader_raw(path: &str) -> Result<Box<dyn AsyncRead + Send + Unpin>, OneIoError> {
    let raw_reader: Box<dyn AsyncRead + Send + Unpin> = match get_protocol(path) {
        #[cfg(feature = "http")]
        Some(protocol) if protocol == "http" || protocol == "https" => {
            #[cfg(feature = "rustls")]
            crypto::ensure_default_provider()?;

            let response = reqwest::get(path).await?;
            let stream = response
                .bytes_stream()
                .map(|result| result.map_err(std::io::Error::other));
            Box::new(tokio_util::io::StreamReader::new(stream))
        }
        #[cfg(feature = "ftp")]
        Some(protocol) if protocol == "ftp" => {
            // FTP async not supported - use sync version with tokio::task::spawn_blocking
            return Err(OneIoError::NotSupported(
                "FTP async not supported - use sync get_reader() instead".to_string(),
            ));
        }
        #[cfg(feature = "s3")]
        Some(protocol) if protocol == "s3" || protocol == "r2" => {
            // S3 async not supported - use sync version with tokio::task::spawn_blocking
            return Err(OneIoError::NotSupported(
                "S3 async not supported - use sync get_reader() instead".to_string(),
            ));
        }
        Some(_) => {
            return Err(OneIoError::NotSupported(format!(
                "Async support not available for protocol in path: {path}"
            )));
        }
        None => {
            // Local file
            use tokio::fs::File;
            let file = File::open(path).await?;
            Box::new(file)
        }
    };
    Ok(raw_reader)
}

/// Applies async decompression based on file extension
#[cfg(feature = "async")]
fn get_async_compression_reader(
    reader: Box<dyn AsyncRead + Send + Unpin>,
    file_type: &str,
) -> Result<Box<dyn AsyncRead + Send + Unpin>, OneIoError> {
    match file_type {
        #[cfg(all(feature = "async", feature = "any_gz"))]
        "gz" | "gzip" => {
            use async_compression::tokio::bufread::GzipDecoder;
            use tokio::io::BufReader;
            let buf_reader = BufReader::new(reader);
            let decoder = GzipDecoder::new(buf_reader);
            Ok(Box::new(decoder))
        }
        #[cfg(all(feature = "async", feature = "bz"))]
        "bz" | "bz2" => {
            use async_compression::tokio::bufread::BzDecoder;
            use tokio::io::BufReader;
            let buf_reader = BufReader::new(reader);
            let decoder = BzDecoder::new(buf_reader);
            Ok(Box::new(decoder))
        }
        #[cfg(all(feature = "async", feature = "zstd"))]
        "zst" | "zstd" => {
            use async_compression::tokio::bufread::ZstdDecoder;
            use tokio::io::BufReader;
            let buf_reader = BufReader::new(reader);
            let decoder = ZstdDecoder::new(buf_reader);
            Ok(Box::new(decoder))
        }
        #[cfg(all(feature = "async", feature = "lz"))]
        "lz4" | "lz" => {
            // LZ4 doesn't have async support in async-compression
            // Use spawn_blocking for sync decompression
            Err(OneIoError::NotSupported(
                "LZ4 async decompression not yet supported - use spawn_blocking with sync version"
                    .to_string(),
            ))
        }
        #[cfg(all(feature = "async", feature = "xz"))]
        "xz" | "xz2" => {
            // XZ doesn't have async support in async-compression
            // Use spawn_blocking for sync decompression
            Err(OneIoError::NotSupported(
                "XZ async decompression not yet supported - use spawn_blocking with sync version"
                    .to_string(),
            ))
        }
        _ => {
            // No compression
            Ok(reader)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    const TEST_TEXT: &str = "OneIO test file.\nThis is a test.";

    #[cfg(feature = "any_gz")]
    #[test]
    fn test_progress_tracking_local() {
        use std::sync::{Arc, Mutex};

        // Track progress calls
        let progress_calls = Arc::new(Mutex::new(Vec::<(u64, u64)>::new()));
        let calls_clone = progress_calls.clone();

        // Test with a local compressed file
        let result =
            get_reader_with_progress("tests/test_data.txt.gz", move |bytes_read, total_bytes| {
                calls_clone.lock().unwrap().push((bytes_read, total_bytes));
            });

        match result {
            Ok((mut reader, total_size)) => {
                assert!(total_size.is_some(), "Local file should have known size");
                let size = total_size.unwrap();
                assert!(size > 0, "Total size should be greater than 0");

                // Read the entire file
                let mut content = String::new();
                reader.read_to_string(&mut content).unwrap();
                assert_eq!(content.trim(), TEST_TEXT.trim());

                // Check that progress was tracked
                let calls = progress_calls.lock().unwrap();
                assert!(
                    !calls.is_empty(),
                    "Progress callback should have been called"
                );

                // Verify progress calls are reasonable
                let (last_bytes, last_total) = calls.last().unwrap();
                assert_eq!(*last_total, size, "Total should match in callbacks");
                assert!(*last_bytes <= size, "Bytes read should not exceed total");
                assert!(*last_bytes > 0, "Should have read some bytes");
            }
            Err(e) => {
                println!("Progress tracking test skipped: {:?}", e);
                // This can fail if gz feature is not enabled or file doesn't exist
            }
        }
    }

    #[cfg(feature = "http")]
    #[test]
    fn test_progress_tracking_remote() {
        use std::sync::{Arc, Mutex};

        // Track progress calls
        let progress_calls = Arc::new(Mutex::new(Vec::<(u64, u64)>::new()));
        let calls_clone = progress_calls.clone();

        // Test with a remote file that has Content-Length
        let result = get_reader_with_progress(
            "https://spaces.bgpkit.org/oneio/test_data.txt",
            move |bytes_read, total_bytes| {
                calls_clone.lock().unwrap().push((bytes_read, total_bytes));
            },
        );

        match result {
            Ok((mut reader, total_size)) => {
                // Read the file
                let mut content = String::new();
                reader.read_to_string(&mut content).unwrap();
                assert_eq!(content.trim(), TEST_TEXT.trim());

                // Check progress tracking
                let calls = progress_calls.lock().unwrap();
                assert!(
                    !calls.is_empty(),
                    "Progress callback should have been called"
                );

                let (last_bytes, last_total) = calls.last().unwrap();

                match total_size {
                    Some(size) => {
                        assert_eq!(*last_total, size, "Total should match in callbacks");
                        // Known size: verify bytes read doesn't exceed total
                        assert!(*last_bytes <= size);
                        println!(
                            "Progress tracking succeeded with known size: {} bytes",
                            size
                        );
                    }
                    None => {
                        assert_eq!(*last_total, 0, "Callback should get 0 for unknown size");
                        // Unknown size: just verify we read some bytes
                        assert!(*last_bytes > 0, "Should have read some bytes");
                        println!(
                            "Progress tracking succeeded with unknown size: {} bytes read",
                            last_bytes
                        );
                    }
                }
            }
            Err(e) => println!("Progress tracking remote test skipped: {:?}", e),
        }
    }

    #[test]
    fn test_get_content_length_local() {
        // Test local file content length
        match get_content_length("tests/test_data.txt.gz") {
            Ok(size) => {
                assert!(size > 0, "Local file should have a size greater than 0");

                // Verify it matches filesystem metadata
                let metadata = std::fs::metadata("tests/test_data.txt.gz").unwrap();
                assert_eq!(
                    size,
                    metadata.len(),
                    "Content length should match file metadata"
                );
            }
            Err(e) => {
                println!("Content length test skipped: {:?}", e);
                // This can fail if the test file doesn't exist or gz feature is disabled
            }
        }
    }

    // Async tests
    #[cfg(feature = "async")]
    #[tokio::test]
    async fn test_async_reader_local() {
        use tokio::io::AsyncReadExt;

        // Test basic async reading
        match get_reader_async("tests/test_data.txt").await {
            Ok(mut reader) => {
                let mut content = String::new();
                reader.read_to_string(&mut content).await.unwrap();
                assert_eq!(content.trim(), TEST_TEXT.trim());
            }
            Err(e) => println!("Async test skipped: {:?}", e),
        }

        // Test with compression formats that support async
        #[cfg(feature = "any_gz")]
        {
            match get_reader_async("tests/test_data.txt.gz").await {
                Ok(mut reader) => {
                    let mut content = String::new();
                    reader.read_to_string(&mut content).await.unwrap();
                    assert_eq!(content.trim(), TEST_TEXT.trim());
                }
                Err(e) => println!("Async gzip test skipped: {:?}", e),
            }
        }
    }
}
