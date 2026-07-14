use md5::Digest;
use oneio::get_reader;
use std::fs::{create_dir_all, File};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Once;

/// List of files to download for testing and their md5 hashes. Hashes are used to avoid
/// re-downloading files on every run. Additionally, they also protect against tests using partial
/// data due to an incomplete downloads on an earlier run.
///
/// When adding a new file, the hash can easily be obtained by using `md5sum [file name]`. Checks
/// are done using the `md5` crate to be compatible with systems where the `md5sum` command is not
/// available.
pub const DATA_SOURCES: &[(&str, &str)] = &[
    (
        "https://spaces.bgpkit.org/parser/rib-example-small.bz2",
        "fb06ea281008c19e479d91433c99c599",
    ),
    (
        "https://spaces.bgpkit.org/parser/update-example.gz",
        "6338710910b20d7c2335b22e0ed112a0",
    ),
];

/// Returns the path of the specified test data file from [DATA_SOURCES]. Upon the first call to
/// this function, any missing data files are also downloaded.
pub fn test_data_file(name: &str) -> PathBuf {
    static ONCE: Once = Once::new();
    ONCE.call_once(download_test_data);

    test_data_dir().join(name)
}

/// Downloads any missing test data files listed in [DATA_SOURCES]. If an error is encountered
/// during this process the program panics with a (hopefully) helpful error.
pub fn download_test_data() {
    let test_data = test_data_dir();

    if let Err(e) = create_dir_all(&test_data) {
        panic!(
            "Unable to create test data folder {}: {}",
            test_data.display(),
            e
        )
    }

    for &(url, checksum) in DATA_SOURCES {
        let data_file_path = match url.rsplit_once('/') {
            Some((_, file_name)) => test_data.join(file_name),
            None => test_data.join(url),
        };

        // Check if file is already downloaded and matches out expected checksum
        if data_file_path.exists() {
            let computed_checksum = match md5_checksum_for_file(&data_file_path) {
                Ok(v) => v,
                Err(err) => panic!(
                    "Unable to compute md5 checksum for test file {}: {}",
                    data_file_path.display(),
                    err
                ),
            };

            if format!("{computed_checksum:x}").as_str() == checksum {
                continue;
            }
        }

        println!(
            "Downloading test file {} from {}",
            data_file_path.display(),
            url
        );

        match download_file(url, &data_file_path) {
            Ok(download_checksum) => {
                if format!("{download_checksum:x}").as_str() != checksum {
                    println!("MD5 checksum for downloaded file ({download_checksum:x}) does not match expected checksum ({checksum:?}).");
                    println!("Perhaps a different file is being used?");

                    panic!("Unable to find expected test data file")
                }
            }
            Err(e) => panic!(
                "Failed to download test file {}: {}",
                data_file_path.display(),
                e
            ),
        }
    }
}

fn md5_checksum_for_file<P: AsRef<Path>>(path: P) -> io::Result<Digest> {
    let mut context = md5::Context::new();
    let mut file = File::open(path)?;

    io::copy(&mut file, &mut context)?;
    Ok(context.finalize())
}

struct HashingWriter<W> {
    writer: W,
    hasher: md5::Context,
}

impl<W: Write> Write for HashingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let length = self.writer.write(buf)?;
        self.hasher.write_all(&buf[..length])?;
        Ok(length)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

fn download_file<P: AsRef<Path>>(url: &str, target: P) -> io::Result<Digest> {
    let target_path = target.as_ref().to_str().unwrap().to_string();

    oneio::download(url, target_path.as_str(), None).map_err(io::Error::other)?;

    let mut reader = get_reader(target_path.as_str()).unwrap();
    let mut writer = HashingWriter {
        writer: BufWriter::new(File::create(target)?),
        hasher: md5::Context::new(),
    };

    io::copy(&mut reader, &mut writer)?;
    writer.flush()?;

    Ok(writer.hasher.finalize())
}

pub fn test_data_dir() -> PathBuf {
    locate_target_dir().join("test_data")
}

pub fn locate_target_dir() -> PathBuf {
    // CARGO_MANIFEST_DIR is an absolute path that is always present at compile time when building
    // with cargo. We know the target directory is most likely in the same directory as the manifest
    // or in a parent directory in the case of a normal workspace.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    let mut search_path = manifest.as_path();
    loop {
        let check_dir = search_path.join("target");
        if check_dir.is_dir() {
            return check_dir;
        }

        // Move to parent directory and try again
        if let Some(parent) = search_path.parent() {
            search_path = parent;
        } else {
            // If we still can't find it, then it is likely defined by a workspace in some strange
            // location. At this point, we just give up as it will be near impossible to find.
            panic!("Unable to find cargo target directory")
        }
    }
}
