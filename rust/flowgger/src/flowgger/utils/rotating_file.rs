extern crate time;
use std::ffi::OsStr;
use std::fs::OpenOptions;
use std::io::stderr;
use std::path::{Path, PathBuf};
use std::{
    fs::{self, File},
    io::{self, Write},
};
use time::{format_description, Duration, OffsetDateTime};

/// Writer providing a file rotating feature when a file reaches the configured size
pub struct RotatingFile {
    basename: PathBuf,
    max_size: usize,
    max_time: u32,
    max_files: i32,
    time_format: String,

    current_file: Option<File>,
    current_size: usize,
    next_rotation_time: Option<OffsetDateTime>,

    #[cfg(test)]
    now_time_mock: OffsetDateTime,
}

impl RotatingFile {
    /// Create a new rotating file, which implements the Write trait
    /// Files are rotated depending on the configured triggers. If no trigger is specified, no rotation will occur
    /// and the data will be written to a single file, rotation is disabled.
    ///
    /// If the time trigger is specified (max_time >0):
    /// All file names are appended with their creation timestamp. i.e. configured file "abcd.log" might become
    /// "abcd-20180108T0143Z.log" if the time format is configured to be "[year][month][day]T[hour][minute]Z"
    /// A file "expires" when its creation time + configured max_time is reached (based on current UTC time).
    /// Rotation occurs when a write is requested to an expired file. The file is then closed and a new one is created.
    /// # Notes:
    /// - the max_files has currently no impact on time trigger rotation, leading to an uncontrolled number of files being
    ///   generated if not externally purged.
    /// - files are only being rotated on write operation. Empty files will not be created every x minutes if there was no write requests.
    ///
    /// A size trigger can be configured in addition to the time trigger (max_time >0 and max_size > 0).
    /// In which case, the behavior is the same than with a time trigger except that a rotation is triggered if the
    /// specified size is reached before the file expires.
    /// # Notes:
    /// If the timestamp format is not precise enough, i.e. only have minutes, if the size trigger is reached within a minute of
    /// its creation, the size can become bigger than the limit specified
    ///
    /// If the time trigger is not specified (max_time = 0) but the size trigger is (max_size > 0):
    /// Rotation occurs when the data to write in the current file is going to reach the specified limit.
    /// During a rotation:
    /// - each existing file is renamed 'basename.{n}' -> 'basename.{n+1}', starting with n = maxfiles -2 up to 0.
    ///   The oldest 'basename.{maxfiles -1}' is therefore overwritten and the old data are lost
    /// - the current file is renamed 'basename' -> 'basename.0'
    /// - A new file 'basename' is created
    ///
    ///
    /// # Parameters
    /// - 'basename': Original file name and path.
    /// - 'max_size': Target size for rotating files. If a write will reach that limit, the file is rotated first.
    /// - 'max_time': Period in minutes for rotating files. If a write is done more than max_time after the file
    ///   creation, the file is rotated.
    /// - 'max_files': Count of files that can be created in addition to the original file,
    ///   named 'basename.N' where'basename' is always the file being currently written
    ///   - 'basename.0' is always the most recent file that has been rotated
    ///   - 'basename.N' is always the oldest file
    /// - time_format: Format of the timestamp to use when time rotation is enabled. Must conform to
    ///   https://docs.rs/time/0.3.7/time/format_description/index.html
    ///
    /// # Example
    /// From parameters:
    ///     - basename = 'logs/syslog.log'
    ///     - max_size = 1024
    ///     - max_files = 2
    ///
    /// The following files will be generated:
    ///     - Current file = 'logs/syslog.log', lg <= 1024
    ///     - Older file = 'logs/syslog.log.0', lg <= 1024
    ///     - Oldest file = 'logs/syslog.log.1', lg <= 1024
    ///
    /// From parameters:
    ///     - basename = 'logs/syslog.log'
    ///     - max_time = 2
    ///     - app started on 2018-01-08 at 01:43 UTC
    ///     - time format is "[year][month][day]T[hour][minute][second]Z"
    ///
    /// The following files will be generated:
    ///     - Current file = 'logs/syslog-20180108T014343Z.log'
    ///     - Older file = 'logs/syslog-20180108T014543Z.log'
    ///     - Oldest file = 'logs/syslog-20180108T014743Z.log'
    ///
    #[allow(dead_code)]
    pub fn new<P: AsRef<Path>>(
        basepath: P,
        max_size: usize,
        max_time: u32,
        max_files: i32,
        time_format: &str,
    ) -> Self {
        let basename = basepath.as_ref().to_path_buf();
        Self {
            basename,
            max_size,
            max_time,
            max_files,
            time_format: time_format.to_string(),
            current_file: None,
            current_size: 0,
            next_rotation_time: None,

            #[cfg(test)]
            now_time_mock: OffsetDateTime::now_utc(),
        }
    }

    fn get_current_date_time(&self) -> OffsetDateTime {
        #[cfg(test)]
        return self.now_time_mock;

        #[cfg(not(test))]
        OffsetDateTime::now_utc()
    }

    /// Build an output file name appending the current timestamp, and compute the file expiration time
    fn build_timestamped_filename(&mut self) -> Result<PathBuf, &'static str> {
        let current_time = self.get_current_date_time();
        self.next_rotation_time = Some(current_time + Duration::minutes(i64::from(self.max_time)));

        let format_item = format_description::parse(&self.time_format).unwrap();
        let dt_str = match current_time.format(&format_item) {
            Ok(date) => date,
            Err(_) => return Err("Failed to parse date"),
        };
        let mut new_file = self.basename.clone();
        new_file.set_file_name(format!(
            "{}-{}.{}",
            self.basename
                .file_stem()
                .unwrap_or_else(|| OsStr::new(""))
                .to_string_lossy(),
            dt_str,
            self.basename
                .extension()
                .unwrap_or_else(|| OsStr::new(""))
                .to_string_lossy()
        ));
        Ok(new_file)
    }

    /// Open the base file and ready for logging and set it as current file
    /// Should typically be called after object creation in order to be able to start writing
    /// The file opened is the 'basename' specified at object creation.
    /// Ex: for RotatingFile::new(basepath='a/file.log',...) the file opened will be 'a/file.log'
    ///
    /// If the time rotation is enabled, this filename will be appended a timestamp with the format
    /// YYYYMMDD'T'HHmmZ. Example: 20180108T0143Z
    /// Ex: for RotatingFile::new(basepath='a/file.log',...) the file opened will be 'a/file-20180108T0143Z.log'
    ///
    /// # Returns
    /// - 'Ok': The file has successfully been open
    /// - 'Err': The file system could not open the file
    ///
    pub fn open(&mut self) -> io::Result<()> {
        // Either use a timstamped filename or the one provided
        let filepath = if self.is_time_triggered() {
            self.build_timestamped_filename().clone().unwrap()
        } else {
            self.basename.clone()
        };

        match RotatingFile::open_file(filepath) {
            Ok(file) => {
                let metadata = file.metadata()?;
                self.current_size = metadata.len() as usize;

                self.current_file = Some(file);
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    /// Static method to open a file
    ///
    /// # Parameters
    /// 'basename': Path of the file to open
    ///
    /// # Returns
    /// Operation result, Ok(file) or IO Err()
    ///
    pub fn open_file<P: AsRef<Path>>(basename: P) -> io::Result<File> {
        OpenOptions::new().create(true).append(true).open(basename)
    }

    /// Build a file path with the specified file number as externsion, on the model:
    /// 'basename.N'. If the index is negative, the basename is returned
    ///
    /// # Parameters
    /// - 'file_num':  File number (file extension)
    ///
    /// # Returns
    /// Path of the new file
    ///
    fn build_file_path(&self, file_num: i32) -> PathBuf {
        if file_num < 0 {
            self.basename.clone()
        } else {
            let mut path = self.basename.clone();
            path.set_extension(file_num.to_string());
            path
        }
    }

    /// Execute a log file rotation for size triggers
    /// Starting from the file n=(self.max_files -1):
    /// - each existing file is renamed 'basename.{n}' -> 'basename.{n+1}'
    /// - the current file is renamed 'basename' -> 'basename.0'
    ///   A new file 'basename' is created
    ///
    /// # Returns
    /// - 'Ok':   when the rotation has been done
    /// - 'Err':  when the new file could not be open
    ///
    fn rotate_size(&mut self) -> io::Result<()> {
        let _ = writeln!(
            stderr(),
            "File {} reached size limit {}, rotating",
            self.basename.to_string_lossy(),
            self.max_size
        );

        // Make sure that file is not gonna be used anymore
        let _ = self.current_file.take();

        // Shift all existing files extension by 1
        let mut dest_pathbuf = self.build_file_path(self.max_files - 1);
        let mut src_pathbuf;
        for file_num in (0..self.max_files).rev() {
            src_pathbuf = self.build_file_path(file_num - 1);
            let _ = fs::rename(src_pathbuf.as_path(), dest_pathbuf.as_path());
            dest_pathbuf = src_pathbuf;
        }

        // Create new logfile, fail if we can't
        self.open()?;
        self.current_size = 0;

        Ok(())
    }

    /// Execute a log file rotation for time triggers
    /// Create a new file with a timestamped filename. The filename therefore indicates the creation time
    /// The previous file(s) being also timestamped, they are close
    ///
    /// # Returns
    /// - 'Ok':   when the rotation has been done
    /// - 'Err':  when the new file could not be open
    ///
    fn rotate_time(&mut self) -> io::Result<()> {
        let _ = writeln!(
            stderr(),
            "File {} reached time/size limit {}min/{}bytes, rotating",
            self.basename.to_string_lossy(),
            self.max_time,
            self.max_size
        );

        // Make sure that file is not gonna be used anymore
        let _ = self.current_file.take();

        // Create new logfile, fail if we can't
        self.open()?;
        self.current_size = 0;

        Ok(())
    }

    /// Indicates if the file rotation is enabled
    ///
    /// # Returns
    /// - true:     The rotation is triggered either on size or time
    /// - false:    The rotation is not configured to be triggered
    ///
    #[allow(dead_code)]
    pub fn is_enabled(&self) -> bool {
        self.is_time_triggered() || self.is_size_triggered()
    }

    /// Indicates if the file rotation is triggered by a time trigger (can may additionally be size triggered as well)
    ///
    /// # Returns
    /// - true:     The rotation is triggered based on time, if specified on size as well. The file names will be timestamped
    /// - false:    The rotation is not configured to be time triggered
    ///
    pub fn is_time_triggered(&self) -> bool {
        self.max_time > 0
    }

    /// Indicates if the file rotation is triggered by a size trigger
    ///
    /// # Returns
    /// - true:     The rotation is triggered based on size, if specified on size. The file names will be numbered
    /// - false:    The rotation is not configured to be size triggered
    ///
    pub fn is_size_triggered(&self) -> bool {
        (self.max_time == 0) && (self.max_size > 0)
    }

    /// Indicates if the file rotation condition for time trigger are reached:
    /// The time elapsed since the current file creation is bigger than the configured period.
    ///
    /// # Returns
    /// - true:     The current file must be rotated
    /// - false:    The current file does not need to be rotated
    ///
    fn is_rotation_time_reached(&self) -> bool {
        (self.next_rotation_time.is_some())
            && (self.next_rotation_time.unwrap() <= OffsetDateTime::now_utc())
    }

    /// Indicates if the file rotation condition for size trigger are reached:
    /// The time elapsed since the current file creation is bigger than the configured period.
    ///
    /// # Returns
    /// - true:     The current file must be rotated
    /// - false:    The current file does not need to be rotated
    ///
    fn is_rotation_size_reached(&self, bytes_to_write: usize) -> bool {
        (self.max_size > 0) && (self.current_size + bytes_to_write > self.max_size)
    }

    /// Verify whether a rotation is needed based on the configured triggers, and rotate the files
    fn check_rotation_trigger(&mut self, bytes_to_write: usize) -> io::Result<()> {
        if self.is_time_triggered() {
            if self.is_rotation_time_reached() || self.is_rotation_size_reached(bytes_to_write) {
                self.rotate_time()?;
            }
        } else if self.is_size_triggered() && self.is_rotation_size_reached(bytes_to_write) {
            self.rotate_size()?;
        }
        Ok(())
    }
}

/// Implementation of the Write trait to allow the Rotating file object to be used as data writer
/// Refer to https://doc.rust-lang.org/std/io/trait.Write.html for trait description
impl Write for RotatingFile {
    /// Writes will always give an event to write, or a set in case of bufferred writing.
    /// We don't split the data to write as we don't want to cut in the middle of an event
    /// So we always write the full data block
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let written = buf.len();

        // Rotate the file if needed
        self.check_rotation_trigger(written)?;

        // Write the whole data block
        self.current_size += written;
        if let Some(Err(err)) = self.current_file.as_mut().map(|file| file.write(buf)) {
            return Err(err);
        }

        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        if let Some(Err(err)) = self.current_file.as_mut().map(|file| file.flush()) {
            Err(err)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    extern crate tempdir;
    use crate::flowgger::utils::test_utils::rfc_test_utils::new_date_time;
    use tempdir::TempDir;
    use time::Month;

    fn build_pattern_list(count: u32, length: usize) -> Vec<String> {
        let mut pattern_list = Vec::new();
        for i in 0..count {
            let mut pattern_str = std::iter::repeat(i.to_string())
                .take(length)
                .collect::<String>();
            pattern_str.push('\n');
            pattern_list.push(pattern_str);
        }
        pattern_list
    }

    #[test]
    fn test_rotation_time_files_time() -> Result<(), io::Error> {
        // Create static time for the different writes to test to mock the current time during the test
        let ts1 = new_date_time(2015, Month::August, 6, 11, 15, 24, 637);
        let ts2 = new_date_time(2015, Month::August, 6, 11, 15, 34, 637);
        let ts3 = new_date_time(2015, Month::August, 6, 11, 16, 26, 637);
        let ts4 = new_date_time(2015, Month::August, 6, 11, 21, 28, 637);

        // Build the expected filenames that should be created in the test
        let tmp_dir = TempDir::new("test_rotation_time_files_time")?;
        let file_base = tmp_dir.path().join("test_log.log");
        let file1 = tmp_dir.path().join("test_log-20150806T1115Z.log");
        let file2 = tmp_dir.path().join("test_log-20150806T1116Z.log");
        let file3 = tmp_dir.path().join("test_log-20150806T1121Z.log");

        // Create a list of 6 bytes patterns
        let test_patterns = build_pattern_list(7, 6);

        // Open the rotating file
        let mut rotating_file =
            RotatingFile::new(&file_base, 16, 5, 10, "[year][month][day]T[hour][minute]Z");
        rotating_file.now_time_mock = ts1;
        assert!(rotating_file.open().is_ok());

        // Write more than the file is allowed in the same minute, no rotation yet
        let _ = &rotating_file.write(test_patterns[0].as_bytes());
        rotating_file.now_time_mock = ts2;
        let _ = &rotating_file.write(test_patterns[1].as_bytes());
        let _ = &rotating_file.write(test_patterns[2].as_bytes());
        assert_eq!(
            fs::read_to_string(file1.as_path()).unwrap(),
            format!(
                "{}{}{}",
                test_patterns[0], test_patterns[1], test_patterns[2]
            )
        );
        assert!(std::fs::metadata(file2.as_path()).is_err());
        assert!(std::fs::metadata(file3.as_path()).is_err());

        // Write more than the file is allowed in another minute, before rotation time expires,
        // we should have a rotation anyway
        rotating_file.now_time_mock = ts3;
        let _ = rotating_file.write(test_patterns[3].as_bytes());
        assert_eq!(
            fs::read_to_string(file1.as_path()).unwrap(),
            format!(
                "{}{}{}",
                test_patterns[0], test_patterns[1], test_patterns[2]
            )
        );
        assert_eq!(
            fs::read_to_string(file2.as_path()).unwrap(),
            test_patterns[3]
        );
        assert!(std::fs::metadata(file3.as_path()).is_err());

        // Write after rotation time expire, rotation expected even if the file size is below the max
        rotating_file.now_time_mock = ts4;
        let _ = rotating_file.write(test_patterns[4].as_bytes());
        assert_eq!(
            fs::read_to_string(file1.as_path()).unwrap(),
            format!(
                "{}{}{}",
                test_patterns[0], test_patterns[1], test_patterns[2]
            )
        );
        assert_eq!(
            fs::read_to_string(file2.as_path()).unwrap(),
            test_patterns[3]
        );
        assert_eq!(
            fs::read_to_string(file3.as_path()).unwrap(),
            test_patterns[4]
        );

        Ok(())
    }

    #[test]
    fn test_rotation_files_size() -> Result<(), io::Error> {
        let tmp_dir = TempDir::new("test_rotation_files_size")?;
        let file_base = tmp_dir.path().join("test_log.log");
        let file_rotated = tmp_dir.path().join("test_log.0");
        let file_rotated2 = tmp_dir.path().join("test_log.1");

        let test_patterns = build_pattern_list(7, 6);

        let mut rotating_file = RotatingFile::new(&file_base, 16, 0, 2, "");
        assert!(rotating_file.open().is_ok());

        // No rotation yet
        let _ = rotating_file.write(test_patterns[0].as_bytes());
        let _ = rotating_file.write(test_patterns[1].as_bytes());
        assert_eq!(
            fs::read_to_string(file_base.as_path()).unwrap(),
            format!("{}{}", test_patterns[0], test_patterns[1])
        );

        // First rotation
        let _ = rotating_file.write(test_patterns[2].as_bytes());
        assert_eq!(
            fs::read_to_string(file_rotated.as_path()).unwrap(),
            format!("{}{}", test_patterns[0], test_patterns[1])
        );
        assert_eq!(
            fs::read_to_string(file_base.as_path()).unwrap(),
            test_patterns[2]
        );

        // Second rotation
        let _ = rotating_file.write(test_patterns[3].as_bytes());
        let _ = rotating_file.write(test_patterns[4].as_bytes());
        assert_eq!(
            fs::read_to_string(file_rotated2.as_path()).unwrap(),
            format!("{}{}", test_patterns[0], test_patterns[1])
        );
        assert_eq!(
            fs::read_to_string(file_rotated.as_path()).unwrap(),
            format!("{}{}", test_patterns[2], test_patterns[3])
        );
        assert_eq!(
            fs::read_to_string(file_base.as_path()).unwrap(),
            test_patterns[4]
        );

        // Oldest log overwritten
        let _ = rotating_file.write(test_patterns[5].as_bytes());
        let _ = rotating_file.write(test_patterns[6].as_bytes());
        assert_eq!(
            fs::read_to_string(file_rotated2.as_path()).unwrap(),
            format!("{}{}", test_patterns[2], test_patterns[3])
        );
        assert_eq!(
            fs::read_to_string(file_rotated.as_path()).unwrap(),
            format!("{}{}", test_patterns[4], test_patterns[5])
        );
        assert_eq!(fs::read_to_string(file_base).unwrap(), test_patterns[6]);

        let _ = rotating_file.flush();

        Ok(())
    }

    #[test]
    fn test_file_invalid_path() {
        let file_base = "/some/crazy/path/test_log.log";

        let mut rotating_file = RotatingFile::new(file_base, 16, 0, 2, "");
        assert!(rotating_file.open().is_err());
    }
}
