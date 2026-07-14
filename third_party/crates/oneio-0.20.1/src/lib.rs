/*!
OneIO is a Rust library providing unified IO operations for reading and writing compressed
files from local and remote sources with both synchronous and asynchronous support.

## Quick Start

```toml
oneio = "0.20"  # Default: gz, bz, https
```

## Feature Selection Guide

### Common Use Cases

**Local files only:**
```toml
oneio = { version = "0.20", default-features = false, features = ["gz", "bz"] }
```

**HTTP only (no HTTPS)**:
```toml
oneio = { version = "0.20", default-features = false, features = ["http", "gz"] }
```

**HTTPS with default rustls**:
```toml
oneio = { version = "0.20", default-features = false, features = ["https", "gz"] }
```

**HTTPS with custom TLS backend**:
```toml
# With rustls
oneio = { version = "0.20", default-features = false, features = ["http", "rustls", "gz"] }

# With native-tls
oneio = { version = "0.20", default-features = false, features = ["http", "native-tls", "gz"] }
```

**S3-compatible storage**:
```toml
oneio = { version = "0.20", default-features = false, features = ["s3", "https", "gz"] }
```

**Async operations**:
```toml
oneio = { version = "0.20", features = ["async"] }
```

### Available Features

**Compression** (choose only what you need):
- `gz` - Gzip via flate2
- `bz` - Bzip2
- `lz` - LZ4
- `xz` - XZ
- `zstd` - Zstandard (balanced)

**Protocols**:
- `http` - HTTP-only support (no TLS)
- `https` - HTTP/HTTPS with rustls TLS backend (equivalent to `http` + `rustls`)
- `ftp` - FTP support (requires `http` + TLS backend)
- `s3` - S3-compatible storage

**TLS Backends** (for HTTPS - mutually exclusive):
- `rustls` - Pure Rust TLS (use with `http`). Uses both system certificates and bundled Mozilla certificates for maximum compatibility with corporate VPNs and minimal environments.
- `native-tls` - Platform native TLS (use with `http`)

**Additional**:
- `async` - Async support (limited to gz, bz, zstd for compression)
- `json` - JSON parsing
- `digest` - SHA256 digest calculation
- `cli` - Command-line tool

Environment: Set `ONEIO_ACCEPT_INVALID_CERTS=true` to accept invalid certificates.

**Crypto Provider Initialization**: When using rustls features (`https`, `s3`, `ftp`), oneio
automatically initializes the crypto provider (AWS-LC or ring) on first use. You can also
initialize it explicitly at startup using [`crypto::ensure_default_provider()`] for better
control over error handling.

## Usages

### Reading Files

Read all content into a string:

```rust,ignore
use oneio;

const TEST_TEXT: &str = "OneIO test file.\nThis is a test.";

// Works with compression and remote files automatically
let content = oneio::read_to_string("https://spaces.bgpkit.org/oneio/test_data.txt.gz")?;
assert_eq!(content.trim(), TEST_TEXT);
# Ok::<(), Box<dyn std::error::Error>>(())
```

Read line by line:

```rust,ignore
use oneio;

let lines = oneio::read_lines("https://spaces.bgpkit.org/oneio/test_data.txt.gz")?
    .map(|line| line.unwrap())
    .collect::<Vec<String>>();

assert_eq!(lines.len(), 2);
assert_eq!(lines[0], "OneIO test file.");
assert_eq!(lines[1], "This is a test.");
# Ok::<(), Box<dyn std::error::Error>>(())
```

Get a reader for streaming:

```rust
use oneio;
use std::io::Read;

let mut reader = oneio::get_reader("tests/test_data.txt.gz")?;
let mut buffer = Vec::new();
reader.read_to_end(&mut buffer)?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

### Writing Files

Write with automatic compression:

```rust,ignore
use oneio;
use std::io::Write;

let mut writer = oneio::get_writer("output.txt.gz")?;
writer.write_all(b"Hello, compressed world!")?;
drop(writer); // Important: close the writer

// Read it back
let content = oneio::read_to_string("output.txt.gz")?;
assert_eq!(content, "Hello, compressed world!");
# Ok::<(), Box<dyn std::error::Error>>(())
```

### Remote Files with Custom Headers

```rust,ignore
use oneio;

let client = oneio::create_client_with_headers([("Authorization", "Bearer TOKEN")])?;
let mut reader = oneio::get_http_reader(
    "https://api.example.com/protected/data.json.gz",
    Some(client)
)?;

let content = std::io::read_to_string(&mut reader)?;
println!("{}", content);
# Ok::<(), Box<dyn std::error::Error>>(())
```

### Progress Tracking
Track download/read progress with callbacks:

```rust,ignore
use oneio;

let (mut reader, total_size) = oneio::get_reader_with_progress(
    "https://example.com/largefile.gz",
    |bytes_read, total_bytes| {
        match total_bytes {
            Some(total) => {
                let percent = (bytes_read as f64 / total as f64) * 100.0;
                println!("Progress: {:.1}%", percent);
            }
            None => println!("Downloaded: {} bytes", bytes_read),
        }
    }
)?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

### Async Support (Feature: `async`)

```rust,ignore
use oneio;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let content = oneio::read_to_string_async("https://example.com/data.json.gz").await?;

    oneio::download_async(
        "https://example.com/data.csv.gz",
        "local_data.csv.gz"
    ).await?;

    Ok(())
}
```

Note: Async compression is limited to gz, bz, zstd. LZ4/XZ return `NotSupported`.


## Supported Formats

### Compression Detection

OneIO detects compression algorithm by the file extensions:

- **Gzip**: `.gz`, `.gzip`
- **Bzip2**: `.bz`, `.bz2`
- **LZ4**: `.lz4`, `.lz`
- **XZ**: `.xz`, `.xz2`
- **Zstandard**: `.zst`, `.zstd`

### Protocol Support
- **Local files**: `/path/to/file.txt`
- **HTTP/HTTPS**: `https://example.com/file.txt.gz`
- **FTP**: `ftp://ftp.example.com/file.txt` (requires `ftp` feature)
- **S3**: `s3://bucket/path/file.txt` (requires `s3` feature)

## Command Line Tool

Install the CLI tool:

```bash
cargo install oneio --features cli
```

Basic usage:

```bash
# Read and print a remote compressed file
oneio https://example.com/data.txt.gz

# Download a file
oneio -d https://example.com/largefile.bz2

# Pipe to other tools
oneio https://api.example.com/data.json.gz | jq '.results | length'
```

## S3 Operations (Feature: `s3`)

```rust,ignore
use oneio::s3::*;

// Direct S3 operations
s3_upload("my-bucket", "path/to/file.txt", "local/file.txt")?;
s3_download("my-bucket", "path/to/file.txt", "downloaded.txt")?;

// Read S3 directly
let content = oneio::read_to_string("s3://my-bucket/path/to/file.txt")?;

// Check existence and get metadata
if s3_exists("my-bucket", "path/to/file.txt")? {
    let stats = s3_stats("my-bucket", "path/to/file.txt")?;
    println!("Size: {} bytes", stats.content_length.unwrap_or(0));
}

// List objects
let objects = s3_list("my-bucket", "path/", Some("/".to_string()), false)?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

## Crypto Provider Initialization (Rustls)

When using HTTPS, S3, or FTP features with rustls, oneio automatically initializes
a crypto provider (AWS-LC or ring) on first use. For more control, you can initialize
it explicitly at startup:

```rust,ignore
use oneio;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize crypto provider explicitly at startup
    oneio::crypto::ensure_default_provider()?;

    // Now all HTTPS/S3/FTP operations will work
    let content = oneio::read_to_string("https://example.com/data.txt")?;

    Ok(())
}
```

This is particularly useful in libraries or applications that want to:
- Handle initialization errors early
- Control when the provider is set up
- Make the dependency on crypto providers explicit

## Error Handling

Three error types in v0.20:

```rust
use oneio::OneIoError;

match oneio::get_reader("file.txt") {
    Ok(reader) => { /* use reader */ },
    Err(OneIoError::Io(e)) => { /* filesystem error */ },
    Err(OneIoError::Network(e)) => { /* network error */ },
    Err(OneIoError::NotSupported(msg)) => { /* feature not compiled */ },
}
```
*/

#![doc(
    html_logo_url = "https://raw.githubusercontent.com/bgpkit/assets/main/logos/icon-transparent.png",
    html_favicon_url = "https://raw.githubusercontent.com/bgpkit/assets/main/logos/favicon.ico"
)]

mod error;
mod oneio;

pub use error::OneIoError;

#[cfg(feature = "rustls")]
pub mod crypto {
    //! Crypto provider initialization for rustls.
    pub use crate::oneio::crypto::*;
}
#[cfg(feature = "digest")]
pub use crate::oneio::digest::*;
#[cfg(any(feature = "http", feature = "ftp"))]
pub use crate::oneio::remote::*;
#[cfg(feature = "s3")]
pub use crate::oneio::s3::*;

pub use crate::oneio::utils::*;

pub use crate::oneio::*;
