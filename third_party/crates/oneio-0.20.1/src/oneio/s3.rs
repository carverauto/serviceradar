//! S3 related functions.
//!
//! The following environment variables are needed (e.g., in .env):
//! - AWS_ACCESS_KEY_ID
//! - AWS_SECRET_ACCESS_KEY
//! - AWS_REGION (e.g. "us-east-1") (use "auto" for Cloudflare R2)
//! - AWS_ENDPOINT
use crate::oneio::{get_reader_raw, get_writer_raw};
use crate::OneIoError;
use s3::creds::Credentials;
use s3::serde_types::{HeadObjectResult, ListBucketResult};
use s3::{Bucket, Region};
use std::io::{Cursor, Read};

/// Checks if the necessary environment variables for AWS S3 are set.
///
/// The required credentials are
/// - `AWS_ACCESS_KEY_ID`: This is the access key for your AWS account.
/// - `AWS_SECRET_ACCESS_KEY`: This is the secret key associated with the `AWS_ACCESS_KEY_ID`.
/// - `AWS_REGION`: The AWS region where the resources are hosted. For example, `us-east-1`. Use `auto` for Cloudflare R2.
/// - `AWS_ENDPOINT`: The specific endpoint of the AWS service that the application will interact with.
///
/// # Errors
///
/// Returns a `OneIoError` if any of the following conditions are met:
///
/// - Failed to load the dotenv file.
/// - Failed to retrieve the AWS region from the default environment.
/// - Failed to retrieve the AWS credentials from the environment.
///
/// # Examples
///
/// ```no_run
/// use oneio::s3_env_check;
///
/// if let Err(e) = s3_env_check() {
///     eprintln!("Error: {:?}", e);
/// }
/// ```
pub fn s3_env_check() -> Result<(), OneIoError> {
    dotenvy::dotenv().ok();
    let _ = Region::from_default_env()?;
    let _ = Credentials::from_env()?;
    Ok(())
}

/// Parse an S3 URL into a bucket and key.
///
/// This function takes an S3 URL as input and returns the bucket and key
/// as a tuple. The URL should be in the format "s3://bucket-name/key".
///
/// # Arguments
///
/// * `path` - A string slice representing the S3 URL to be parsed.
///
/// # Examples
///
/// ```no_run
/// use oneio::s3_url_parse;
///
/// let result = s3_url_parse("s3://my-bucket/my-folder/my-file.txt");
/// match result {
///     Ok((bucket, key)) => {
///         println!("Bucket: {}", bucket);
///         println!("Key: {}", key);
///     }
///     Err(err) => {
///         eprintln!("Failed to parse S3 URL: {:?}", err);
///     }
/// }
/// ```
///
/// # Errors
///
/// This function can return a `OneIoError` in the following cases:
///
/// * If the URL does not contain a bucket and key separated by "/".
///
/// In case of error, the `OneIoError` variant `S3UrlError` will be returned,
/// containing the original URL string.
///
/// # Returns
///
/// Returns a `Result` containing the bucket and key as a tuple, or a `OneIoError` if parsing fails.
pub fn s3_url_parse(path: &str) -> Result<(String, String), OneIoError> {
    let parts = path.split('/').collect::<Vec<&str>>();
    if parts.len() < 3 {
        return Err(OneIoError::NotSupported(format!("Invalid S3 URL: {path}")));
    }
    let bucket = parts[2];
    let key = parts[3..].join("/");
    Ok((bucket.to_string(), key))
}

/// Creates an S3 bucket object with the specified bucket name.
///
/// # Arguments
///
/// * `bucket` - A string slice representing the name of the S3 bucket.
///
/// # Errors
///
/// This function can return a `OneIoError` if any of the following conditions occur:
///
/// * Failed to load the environment variables from the .env file.
/// * Failed to create a new `Bucket` object with the given `bucket` name, `Region`, and `Credentials`.
///
/// # Examples
///
/// ```no_run
/// use s3::Bucket;
/// use oneio::s3_bucket;
///
/// let result = s3_bucket("my-bucket");
/// match result {
///     Ok(bucket) => {
///         // Do something with the `bucket` object
///     }
///     Err(error) => {
///         // Handle the error
///     }
/// }
/// ```
pub fn s3_bucket(bucket: &str) -> Result<Bucket, OneIoError> {
    dotenvy::dotenv().ok();

    #[cfg(feature = "rustls")]
    super::crypto::ensure_default_provider()?;

    let mut bucket = *Bucket::new(
        bucket,
        Region::from_default_env()?,
        Credentials::new(None, None, None, None, None)?,
    )?;
    bucket.set_request_timeout(Some(std::time::Duration::from_secs(10 * 60)));
    Ok(bucket)
}

//noinspection ALL,Style
/// `s3_reader` function reads a file from an S3 bucket and returns a boxed reader implementing `Read` trait.
///
/// # Arguments
///
/// * `bucket` - A string slice that represents the name of the S3 bucket.
/// * `path` - A string slice that represents the file path within the S3 bucket.
///
/// # Errors
///
/// The function can return an error of type `OneIoError`. This error occurs if there are any issues with the S3 operations, such as
/// accessing the bucket or retrieving the object.
///
/// # Returns
///
/// The function returns a `Result` containing a boxed reader implementing `Read + Send` trait in case of a successful operation. The reader
/// can be used to read the contents of the file stored in the S3 bucket. If the operation fails, a `OneIoError` is returned as an error.
///
/// # Example
///
/// ```rust,no_run
/// use std::io::Read;
/// use oneio::s3_reader;
///
/// let bucket = "my_bucket";
/// let path = "path/to/file.txt";
///
/// let mut  reader = s3_reader(bucket, path).unwrap();
///
/// let mut buffer = Vec::new();
/// reader.read_to_end(&mut buffer).unwrap();
///
/// assert_eq!(buffer, b"File content in S3 bucket");
/// ```
pub fn s3_reader(bucket: &str, path: &str) -> Result<Box<dyn Read + Send>, OneIoError> {
    let bucket = s3_bucket(bucket)?;
    let object = bucket.get_object(path)?;
    let buf: Vec<u8> = object.to_vec();
    Ok(Box::new(Cursor::new(buf)))
}

/// Uploads a file to an S3 bucket at the specified path.
///
/// # Arguments
///
/// * `bucket` - The name of the S3 bucket.
/// * `s3_path` - The desired path of the file in the S3 bucket.
/// * `file_path` - The path of the file to be uploaded.
///
/// # Returns
///
/// Returns Result<(), OneIoError> indicating success or failure.
///
/// # Examples
///
/// ```rust,no_run
/// use oneio::s3_upload;
///
/// let result = s3_upload("my-bucket", "path/to/file.txt", "/path/to/local_file.txt");
/// assert!(result.is_ok());
/// ```
pub fn s3_upload(bucket: &str, s3_path: &str, file_path: &str) -> Result<(), OneIoError> {
    // Early validation: check if file exists before attempting S3 operations
    // This prevents potential hanging issues when file doesn't exist
    if !std::path::Path::new(file_path).exists() {
        return Err(OneIoError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("File not found: {file_path}"),
        )));
    }

    let bucket = s3_bucket(bucket)?;
    let mut reader = get_reader_raw(file_path)?;
    bucket.put_object_stream(&mut reader, s3_path)?;
    Ok(())
}

/// Copies an object within the same Amazon S3 bucket.
///
/// # Arguments
///
/// * `bucket` - The name of the Amazon S3 bucket.
/// * `s3_path` - The path of the source object to be copied.
/// * `s3_path_new` - The path of the destination object.
///
/// # Errors
///
/// Returns an `Err` variant of the `OneIoError` enum if there was an error when copying the object.
///
/// # Examples
///
/// ```no_run
/// use oneio::s3_copy;
///
/// match s3_copy("my-bucket", "path/to/object.txt", "new-path/to/object.txt") {
///     Err(error) => {
///         println!("Failed to copy object: {:?}", error);
///     }
///     Ok(()) => {
///         println!("Object copied successfully.");
///     }
/// }
/// ```
pub fn s3_copy(bucket: &str, s3_path: &str, s3_path_new: &str) -> Result<(), OneIoError> {
    let bucket = s3_bucket(bucket)?;
    bucket.copy_object_internal(s3_path, s3_path_new)?;
    Ok(())
}

/// Deletes an object from an S3 bucket.
///
/// # Arguments
///
/// * `bucket` - The name of the S3 bucket.
/// * `s3_path` - The path to the object in the S3 bucket.
///
/// # Errors
///
/// Returns a `OneIoError` if the deletion fails.
///
/// # Examples
///
/// ```no_run
/// use oneio::{OneIoError, s3_delete};
///
/// fn example() -> Result<(), OneIoError> {
///     let bucket = "my-bucket";
///     let s3_path = "path/to/object.txt";
///     s3_delete(bucket, s3_path)?;
///     Ok(())
/// }
/// ```
///
pub fn s3_delete(bucket: &str, s3_path: &str) -> Result<(), OneIoError> {
    let bucket = s3_bucket(bucket)?;
    bucket.delete_object(s3_path)?;
    Ok(())
}

/// Downloads a file from an S3 bucket and saves it locally.
///
/// # Arguments
///
/// * `bucket` - The name of the S3 bucket.
/// * `s3_path` - The path to the file in the S3 bucket.
/// * `file_path` - The path where the downloaded file will be saved locally.
///
/// # Returns
///
/// Return `Ok(())` if the download is successful.
///
/// Return an `Err` with a `OneIoError` if there was an error during the download.
///
/// # Errors
///
/// The function can return `OneIoError::Network` if the HTTP response
/// status code is not in the range of 200 to 299 (inclusive).
///
/// # Example
///
/// ```rust
/// use std::path::Path;
/// use oneio::s3_download;
///
/// let bucket = "my-bucket";
/// let s3_path = "path/to/file.txt";
/// let file_path = "local/file.txt";
///
/// match s3_download(bucket, s3_path, file_path) {
///     Ok(()) => println!("Download successful!"),
///     Err(err) => println!("Error while downloading: {:?}", err),
/// }
/// ```
///
pub fn s3_download(bucket: &str, s3_path: &str, file_path: &str) -> Result<(), OneIoError> {
    let bucket = s3_bucket(bucket)?;
    let mut output_file = get_writer_raw(file_path)?;
    let res: u16 = bucket.get_object_to_writer(s3_path, &mut output_file)?;
    match res {
        200..=299 => Ok(()),
        _ => Err(OneIoError::Network(Box::new(std::io::Error::other(
            format!("S3 HTTP error: {res}"),
        )))),
    }
}

/// # S3 Stats
///
/// Retrieves the head object result for a given bucket and path in Amazon S3.
///
/// ## Parameters
///
/// - `bucket`: A string that represents the name of the bucket in Amazon S3.
/// - `path`: A string that represents the path of the object in the bucket.
///
/// ## Returns
///
/// Returns a `Result` that contains a `HeadObjectResult` if the operation was
/// successful, otherwise returns a `OneIoError` indicating the S3 download error.
///
/// ## Example
///
/// ```rust,no_run
/// use oneio::s3_stats;
///
/// let bucket = "my-bucket";
/// let path = "my-folder/my-file.txt";
///
/// match s3_stats(bucket, path) {
///     Ok(result) => {
///         // Handle the successful result
///         println!("Head Object: {:?}", result);
///     }
///     Err(error) => {
///         // Handle the error
///         println!("Error: {:?}", error);
///     }
/// }
/// ```
pub fn s3_stats(bucket: &str, path: &str) -> Result<HeadObjectResult, OneIoError> {
    let bucket = s3_bucket(bucket)?;
    let (head_object, code): (HeadObjectResult, u16) = bucket.head_object(path)?;
    match code {
        200..=299 => Ok(head_object),
        _ => Err(OneIoError::Network(Box::new(std::io::Error::other(
            format!("S3 HTTP error: {code}"),
        )))),
    }
}

/// Check if a file exists in an S3 bucket.
///
/// # Arguments
///
/// * `bucket` - The name of the S3 bucket.
/// * `path` - The path of the file in the S3 bucket.
///
/// # Returns
///
/// Returns `Ok(true)` if the file exists, `Ok(false)` if the file does not exist,
/// or an `Err` containing a `OneIoError::Network` if there was an error
/// checking the file's existence.
///
/// # Example
///
/// ```no_run
/// use oneio::s3_exists;
///
/// let result = s3_exists("my-bucket", "path/to/file.txt");
/// match result {
///     Ok(true) => println!("File exists"),
///     Ok(false) => println!("File does not exist"),
///     Err(error) => eprintln!("Error: {:?}", error),
/// }
/// ```
pub fn s3_exists(bucket: &str, path: &str) -> Result<bool, OneIoError> {
    match s3_stats(bucket, path) {
        Ok(_) => Ok(true),
        Err(err) => {
            // Check if this is a 404 network error by parsing the status code
            if let OneIoError::Network(boxed_err) = &err {
                let error_msg = boxed_err.to_string();
                if error_msg.starts_with("S3 HTTP error: ") {
                    // Parse the status code from the structured error message
                    if let Some(code_str) = error_msg.strip_prefix("S3 HTTP error: ") {
                        if let Ok(status_code) = code_str.parse::<u16>() {
                            return match status_code {
                                404 => Ok(false), // Not Found
                                // 403 Forbidden means permission denied; propagate as error
                                _ => Err(err), // Other errors should propagate
                            };
                        }
                    }
                }
            }
            Err(err)
        }
    }
}

/// Lists objects in the specified Amazon S3 bucket with given prefix and delimiter.
///
/// # Arguments
///
/// * `bucket` - Name of the S3 bucket.
/// * `prefix` - A prefix to filter the objects by.
/// * `delimiter` - An optional delimiter used to separate object key hierarchies.
/// * `dirs` - A flag to show only directories under the given prefix if set to true
///
/// # Returns
///
/// * If the URL does not start with "s3://". Returns a `Result` with a `Vec<String>` containing the object keys on success, or a `OneIoError` on failure.
///
/// # Example
///
/// ```no_run
/// use oneio::s3_list;
///
/// let bucket = "my-bucket";
/// let prefix = "folder/";
/// let delimiter = Some("/".to_string());
///
/// let result = s3_list(bucket, prefix, delimiter, false);
/// match result {
///     Ok(objects) => {
///         println!("Found {} objects:", objects.len());
///         for object in objects {
///             println!("{}", object);
///         }
///     }
///     Err(error) => {
///         eprintln!("Failed to list objects: {:?}", error);
///     }
/// }
/// ```
pub fn s3_list(
    bucket: &str,
    prefix: &str,
    delimiter: Option<String>,
    dirs: bool,
) -> Result<Vec<String>, OneIoError> {
    let fixed_delimiter = match dirs && delimiter.is_none() {
        true => Some("/".to_string()),
        false => delimiter,
    };
    let bucket = s3_bucket(bucket)?;
    let mut list: Vec<ListBucketResult> = bucket.list(prefix.to_string(), fixed_delimiter)?;
    let mut result = vec![];
    for item in list.iter_mut() {
        match dirs {
            true => result.extend(
                item.common_prefixes
                    .iter()
                    .flat_map(|x| x.iter().map(|p| p.prefix.clone())),
            ),
            false => result.extend(item.contents.iter().map(|x| x.key.clone())),
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_s3_url_parse() {
        const S3_URL: &str = "s3://test-bucket/test-path/test-file.txt";
        let (bucket, path) = s3_url_parse(S3_URL).unwrap();
        assert_eq!(bucket, "test-bucket");
        assert_eq!(path, "test-path/test-file.txt");

        const NON_S3_URL: &str = "s3:/test-bucket";
        assert!(s3_url_parse(NON_S3_URL).is_err());
    }

    #[test]
    fn test_s3_upload_nonexistent_file_early_validation() {
        // Test for issue #48: s3_upload should fail quickly for non-existent files
        // This test checks the early validation logic without requiring S3 credentials

        let non_existent_file = "/tmp/oneio_test_nonexistent_file_12345.txt";

        // Make sure the file doesn't exist
        let _ = std::fs::remove_file(non_existent_file);
        assert!(!std::path::Path::new(non_existent_file).exists());

        // This should return an error quickly due to early file validation
        let start = std::time::Instant::now();

        match s3_upload("test-bucket", "test-path", non_existent_file) {
            Ok(_) => {
                panic!("Upload should have failed for non-existent file");
            }
            Err(OneIoError::Io(e)) => {
                let duration = start.elapsed();
                println!(
                    "✓ Upload failed quickly with IO error after {:?}: {}",
                    duration, e
                );
                assert!(
                    duration < std::time::Duration::from_millis(100),
                    "Early validation should be instant. Took: {:?}",
                    duration
                );
                assert_eq!(e.kind(), std::io::ErrorKind::NotFound);
                assert!(e.to_string().contains("File not found"));
            }
            Err(e) => {
                // Could also fail due to missing credentials, which is also quick
                let duration = start.elapsed();
                println!("Upload failed with error after {:?}: {:?}", duration, e);
                assert!(
                    duration < std::time::Duration::from_secs(1),
                    "Should fail quickly, not hang. Took: {:?}",
                    duration
                );
            }
        }
    }
}
