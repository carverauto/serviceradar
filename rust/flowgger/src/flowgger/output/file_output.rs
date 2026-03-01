use super::Output;
use crate::flowgger::config::Config;
use crate::flowgger::merger::Merger;
use crate::flowgger::utils::rotating_file::RotatingFile;
use crate::flowgger::validate_time_format_input;
use std::io::{BufWriter, Write};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread;

use std::io::stderr;
const FILE_DEFAULT_BUFFER_SIZE: usize = 0;
const FILE_DEFAULT_TIME_FORMAT: &str = "[year][month][day]T[hour][minute][second]Z";
const FILE_DEFAULT_ROTATION_SIZE: usize = 0;
const FILE_DEFAULT_ROTATION_TIME: u32 = 0;
const FILE_DEFAULT_ROTATION_MAXFILES: i32 = 50;

/// Output of type file, to store the data to a file
pub struct FileOutput {
    path: String,
    buffer_size: usize,
    rotation_size: usize,
    rotation_time: u32,
    rotation_maxfiles: i32,
    time_format: String,
}

impl FileOutput {
    /// Create a new file output, using the configuration in the Config object
    /// Required elements:
    /// - 'output.file_path':               Must be a string. Path of the output file.
    ///
    /// Optional:
    /// - 'output.file_buffer_size':        Must be an integer. Default is 0. If not 0, enables file buffering.
    ///                                     Data are only flushed to the file once the buffer isize is reached
    /// - 'output.file_rotation_size':      Must be an integer. Default is 0. If not 0, enables file rotation.
    ///                                     Files are rotated when this size is reached.
    /// - 'output.file_rotation_time':      Must be an integer. Default is 0. If not 0, enables file rotation.
    ///                                     Files are rotated after that period of time elapsed between writes.
    /// - 'output.file_rotation_maxfiles':  Must be an integer. Default is 2. Specifies count rotated files.
    ///                                     Unused if rotation is not enabled.
    /// - 'output.file_rotation_maxfiles':  Must be an integer. Default is 2. Specifies count rotated files.
    ///                                     Unused if rotation is not enabled.
    /// - 'output.file_rotation_timeformat':Must be a String. Default is set to "[year][month][day]T[hour][minute][second]Z".
    ///                                     When time rotation is enabled, format of the timestamp added to the
    ///                                     https://docs.rs/time/0.3.7/time/format_description/index.html
    /// # Parameters
    /// - 'Config':  Configuration parameters
    ///
    pub fn new(config: &Config) -> FileOutput {
        let path = config
            .lookup("output.file_path")
            .expect("output.file_path is missing")
            .as_str()
            .expect("output.file_path must be a string")
            .to_string();
        let buffer_size =
            config
                .lookup("output.file_buffer_size")
                .map_or(FILE_DEFAULT_BUFFER_SIZE, |bs| {
                    bs.as_integer()
                        .expect("output.file_buffer_size should be an integer")
                        as usize
                });
        // Get the optional file rotation size. if none, set it to 0 to disable the feature
        let rotation_size = config.lookup("output.file_rotation_size").map_or(
            FILE_DEFAULT_ROTATION_SIZE,
            |rot_size| {
                rot_size
                    .as_integer()
                    .expect("output.file_rotation_size should be an integer")
                    as usize
            },
        );
        // Get the optional file rotation time. if none, set it to 0 to disable the feature
        let rotation_time = config.lookup("output.file_rotation_time").map_or(
            FILE_DEFAULT_ROTATION_TIME,
            |rot_time| {
                rot_time
                    .as_integer()
                    .expect("output.file_rotation_time should be an integer") as u32
            },
        );
        // Get the optional file rotation max files. Default is 2
        let rotation_maxfiles = config.lookup("output.file_rotation_maxfiles").map_or(
            FILE_DEFAULT_ROTATION_MAXFILES,
            |rot_size| {
                rot_size
                    .as_integer()
                    .expect("output.file_rotation_maxfiles should be an integer")
                    as i32
            },
        );
        let time_format = config.lookup("output.file_rotation_timeformat").map_or(
            FILE_DEFAULT_TIME_FORMAT.to_string(),
            |bs| {
                bs.as_str()
                    .expect("output.file_rotation_timeformat should be a string")
                    .to_string()
            },
        );

        let time_format = validate_time_format_input(
            "file_rotation_timeformat",
            &time_format,
            FILE_DEFAULT_TIME_FORMAT.to_string(),
        );

        FileOutput {
            path,
            buffer_size,
            rotation_size,
            rotation_time,
            rotation_maxfiles,
            time_format,
        }
    }

    /// Open the right file writer depending on the configuration:
    /// - a standard file
    /// - a rotating file if the rotationg option is specified
    /// - bufferized output if specified
    ///
    /// # Returns
    /// Some() with boxed object implementing the Write and Send traits, so a data writer that can send data to a thread
    /// None if an error occured trying to open the writer (during RotatingFile::open or RotatingFile::open_file)
    ///
    /// # Panics
    /// Explains when a function panics, should always be included when panic!, assert! or similar are used/when any branch of the function can directly return !
    ///
    /// # Errors
    /// Explain when an error value is returned (see also “Returns” in the next section)
    ///
    fn open_writer(&self) -> Option<Box<dyn Write + Send>> {
        let file_writer: Option<Box<dyn Write + Send>>;

        // Rotation option is enabled, open a rotating file writer
        let mut rotating_file = RotatingFile::new(
            &self.path,
            self.rotation_size,
            self.rotation_time,
            self.rotation_maxfiles,
            &self.time_format,
        );
        if rotating_file.is_enabled() {
            file_writer = match rotating_file.open() {
                Ok(_) => Some(Box::new(rotating_file)),
                Err(e) => {
                    let _ = writeln!(
                        stderr(),
                        "Unable to open rotating file {}: {}",
                        &self.path,
                        e
                    );
                    None
                }
            }
        }
        // Open a standard file writer
        else {
            file_writer = match RotatingFile::open_file(&self.path) {
                Ok(file) => Some(Box::new(file)),
                Err(e) => {
                    let _ = writeln!(stderr(), "Unable to open file {}: {}", &self.path, e);
                    None
                }
            }
        }
        // Return bufferized output if option is enabled
        if (file_writer.is_some()) && (self.buffer_size > 0) {
            Some(Box::new(BufWriter::with_capacity(
                self.buffer_size,
                file_writer.unwrap(),
            )))
        } else {
            file_writer
        }
    }
}

/// Implements the Output traits (flowgger::Output) to allow FileOutput to be used as a flowgger data output
impl Output for FileOutput {
    /// Start a thread listening to the specified synchronized input and writing data to a file once received.
    /// See flowgger::Output trait for arguments description
    ///
    fn start(&self, arx: Arc<Mutex<Receiver<Vec<u8>>>>, merger: Option<Box<dyn Merger>>) {
        let merger = match merger {
            Some(merger) => Some(merger.clone_boxed()),
            None => None,
        };

        // Try to get an output writer, or panic: if we can't output data we're useless
        let mut writer: Box<dyn Write + Send>;
        match self.open_writer() {
            Some(file) => {
                writer = file;
            }
            None => {
                panic!("Cannot open file to {}", &self.path);
            }
        }

        thread::spawn(move || loop {
            let mut bytes = match { arx.lock().unwrap().recv() } {
                Ok(line) => line,
                Err(_) => return,
            };

            if let Some(ref merger) = merger {
                merger.frame(&mut bytes);
            }

            writer
                .write_all(&bytes)
                .expect("Cannot write bytes to output file");
        });
    }
}

#[cfg(test)]
mod tests {
    /// FileOutput object unit tests
    /// Note: Tests checking real files must use test unique filenames as tests are ran in parallel
    use super::*;
    use crate::flowgger::merger::LineMerger;
    use std::fs;
    use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
    use std::sync::{Arc, Mutex};
    use std::{thread, time};
    extern crate tempdir;
    use std::io::Result;
    use tempdir::TempDir;

    /// Helper for the test to initialize some test data, create a writer,  and verify it
    struct WriterTest {
        file_base: String,
        test_patterns: Vec<&'static str>,
        _temp_dir: TempDir,
    }

    impl WriterTest {
        fn new(file_name: &'static str) -> Result<Self> {
            let temp_dir = TempDir::new("test_file_output")?;
            let file_base = temp_dir
                .path()
                .join(file_name)
                .to_string_lossy()
                .to_string();
            Ok(Self {
                file_base,
                test_patterns: vec!["abcdef", "ghijkl", "012345", "678901"],
                _temp_dir: temp_dir,
            })
        }

        fn setup_writer(
            &self,
            cfg: Config,
            expected_rotsize: usize,
            expected_rotfiles: i32,
            expected_buffsize: usize,
            expected_time: u32,
        ) -> Box<dyn Write> {
            let fp = FileOutput::new(&cfg);

            assert_eq!(fp.rotation_size, expected_rotsize);
            assert_eq!(fp.rotation_maxfiles, expected_rotfiles);
            assert_eq!(fp.buffer_size, expected_buffsize);
            assert_eq!(fp.rotation_time, expected_time);
            let writer_result = fp.open_writer();
            assert!(writer_result.is_some());
            writer_result.unwrap()
        }

        fn setup_nowriter(&self, cfg: Config) {
            let fp = FileOutput::new(&cfg);
            let writer_result = fp.open_writer();
            assert!(writer_result.is_none());
        }

        fn setup_start_thread(
            &self,
            cfg: Config,
            merger: Option<Box<dyn Merger>>,
        ) -> SyncSender<Vec<u8>> {
            let fp = FileOutput::new(&cfg);

            // Create a sync data sender and start the file output task
            let (tx, rx): (SyncSender<Vec<u8>>, Receiver<Vec<u8>>) = sync_channel(128);
            let arx = Arc::new(Mutex::new(rx));
            fp.start(arx, merger);
            tx
        }

        fn get_file_base(&self) -> &str {
            &self.file_base
        }
    }

    #[test]
    #[should_panic(expected = "output.file_path must be a string")]
    fn test_invalid_file_path() {
        let cfg = Config::from_string(&format!("[output]\nfile_path = 123\n")).unwrap();
        let _ = FileOutput::new(&cfg);
    }

    #[test]
    #[should_panic(expected = "output.file_rotation_timeformat should be a string")]
    fn test_invalid_time_format() {
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"output_file\"\nfile_rotation_timeformat = 123\n"
        ))
        .unwrap();
        let _ = FileOutput::new(&cfg);
    }

    #[test]
    #[should_panic(expected = "output.file_rotation_size should be an integer")]
    fn test_invalid_rotation_size() {
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"output_file\"\nfile_rotation_size= \"15s\"\n"
        ))
        .unwrap();
        let _ = FileOutput::new(&cfg);
    }

    #[test]
    #[should_panic(expected = "output.file_buffer_size should be an integer")]
    fn test_invalid_buffer_size() {
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"output_file\"\nfile_buffer_size= \"15s\"\n"
        ))
        .unwrap();
        let _ = FileOutput::new(&cfg);
    }

    #[test]
    #[should_panic(expected = "output.file_rotation_maxfiles should be an integer")]
    fn test_invalid_rotation_maxfiles() {
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"output_file\"\nfile_rotation_maxfiles= \"15s\"\n"
        ))
        .unwrap();
        let _ = FileOutput::new(&cfg);
    }

    #[test]
    #[should_panic(expected = "output.file_rotation_time should be an integer")]
    fn test_invalid_rotation_time() {
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"output_file\"\nfile_rotation_time= \"15s\"\n"
        ))
        .unwrap();
        let _ = FileOutput::new(&cfg);
    }

    #[test]
    fn test_start_no_merger() -> Result<()> {
        let file_base = "/tmp/test_start_no_merger";
        let test_object = WriterTest::new(file_base)?;
        let cfg =
            Config::from_string(&format!("[output]\nfile_path = \"{}\"\n", file_base)).unwrap();
        let tx = test_object.setup_start_thread(cfg, None);

        // Send data, then check it has been written to file. Wait a sec for the task to receive and write
        let _ = tx.send(test_object.test_patterns[0].as_bytes().to_vec());
        thread::sleep(time::Duration::from_millis(100));
        assert_eq!(
            fs::read_to_string(file_base).unwrap(),
            test_object.test_patterns[0]
        );
        let _ = fs::remove_file(file_base);
        Ok(())
    }

    #[test]
    fn test_start_with_merger() -> Result<()> {
        let file_base = "/tmp/test_start_with_merger";
        let test_object = WriterTest::new(file_base)?;
        let cfg =
            Config::from_string(&format!("[output]\nfile_path = \"{}\"\n", file_base)).unwrap();
        let merger = Some(Box::new(LineMerger::new(&cfg)) as Box<dyn Merger>);
        let tx = test_object.setup_start_thread(cfg, merger);

        // Send data, then check it has been written to file. Wait a sec for the task to receive and write
        let _ = tx.send(test_object.test_patterns[0].as_bytes().to_vec());
        thread::sleep(time::Duration::from_millis(100));
        assert_eq!(
            fs::read_to_string(file_base).unwrap(),
            format!("{}\n", test_object.test_patterns[0])
        );
        let _ = fs::remove_file(file_base);
        Ok(())
    }

    #[test]
    #[should_panic(expected = "Cannot open file to /wrong/path/test_start_nofile")]
    fn test_start_nofile() {
        let file_base = "/wrong/path/test_start_nofile";
        let test_object = WriterTest::new(file_base).unwrap();
        let cfg =
            Config::from_string(&format!("[output]\nfile_path = \"{}\"\n", file_base)).unwrap();
        let _ = test_object.setup_start_thread(cfg, None);
    }

    #[test]
    fn test_log_rotate_nobuf() -> Result<()> {
        let test_object = WriterTest::new("test_log_rotate_nobuf")?;
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"{}\"\nfile_rotation_size = 15\n",
            test_object.get_file_base()
        ))
        .unwrap();
        let mut writer = test_object.setup_writer(
            cfg,
            15,
            FILE_DEFAULT_ROTATION_MAXFILES,
            FILE_DEFAULT_BUFFER_SIZE,
            FILE_DEFAULT_ROTATION_TIME,
        );

        // We should have a RotatingFile instance unbuffered, check a 2 files are created after >15 bytes written
        let file_rotated = &format!("{}.0", test_object.get_file_base());
        let _ = fs::remove_file(file_rotated);
        let _ = writer.write_all(test_object.test_patterns[0].as_bytes());
        let _ = writer.write_all(test_object.test_patterns[1].as_bytes());
        let _ = writer.write_all(test_object.test_patterns[2].as_bytes());
        assert_eq!(
            fs::read_to_string(test_object.get_file_base()).unwrap(),
            test_object.test_patterns[2]
        );
        assert_eq!(
            fs::read_to_string(file_rotated).unwrap(),
            format!(
                "{}{}",
                test_object.test_patterns[0], test_object.test_patterns[1]
            )
        );

        let _ = fs::remove_file(file_rotated);
        Ok(())
    }

    #[test]
    fn test_log_rotate_time_nobuf() -> Result<()> {
        let test_object = WriterTest::new("test_log_rotate_time_nobuf")?;
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"{}\"\nfile_rotation_size = 15\nfile_rotation_time = 2\n",
            test_object.get_file_base()
        ))
        .unwrap();
        let _writer = test_object.setup_writer(
            cfg,
            15,
            FILE_DEFAULT_ROTATION_MAXFILES,
            FILE_DEFAULT_BUFFER_SIZE,
            2,
        );

        Ok(())
    }

    #[test]
    fn test_log_rotate_buf() -> Result<()> {
        let test_object = WriterTest::new("test_log_rotate_buf")?;
        let cfg = Config::from_string(&format!("[output]\nfile_path = \"{}\"\nfile_rotation_size = 15\nfile_buffer_size=10\nfile_rotation_maxfiles=6\n",
                                               test_object.get_file_base())).unwrap();
        let mut writer = test_object.setup_writer(cfg, 15, 6, 10, FILE_DEFAULT_ROTATION_TIME);

        // We should have a BufWriter<RotatingFile> instance, check no new file created after >file size
        let file_rotated = &format!("{}.0", test_object.get_file_base());
        let _ = fs::remove_file(file_rotated);
        let _ = writer.write(test_object.test_patterns[0].as_bytes());
        let _ = writer.write(test_object.test_patterns[1].as_bytes());

        // At this point, we wrote enough data to generate a rotation. but the last write should be buffered and not flushed. so no rotation yet
        let _ = writer.write(test_object.test_patterns[2].as_bytes());
        assert_eq!(
            fs::read_to_string(test_object.get_file_base()).unwrap(),
            format!(
                "{}{}",
                test_object.test_patterns[0], test_object.test_patterns[1]
            )
        );

        // This write fills the buffer and should generate the flush and the rotation
        let _ = writer.write(test_object.test_patterns[3].as_bytes());

        assert_eq!(
            fs::read_to_string(test_object.get_file_base()).unwrap(),
            test_object.test_patterns[2]
        );
        assert_eq!(
            fs::read_to_string(file_rotated).unwrap(),
            format!(
                "{}{}",
                test_object.test_patterns[0], test_object.test_patterns[1]
            )
        );

        let _ = fs::remove_file(file_rotated);
        Ok(())
    }

    #[test]
    fn test_log_rotate_nofile() -> Result<()> {
        let test_object = WriterTest::new("/wrong/path/test_log_rotate_buf")?;
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"{}\"\nfile_rotation_size = 15\n",
            test_object.get_file_base()
        ))
        .unwrap();
        test_object.setup_nowriter(cfg);
        Ok(())
    }

    #[test]
    fn test_log_norotate_nobuf() -> Result<()> {
        let test_object = WriterTest::new("test_log_norotate_nobuf")?;
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"{}\"\n",
            test_object.get_file_base()
        ))
        .unwrap();
        let mut writer = test_object.setup_writer(
            cfg,
            FILE_DEFAULT_ROTATION_SIZE,
            FILE_DEFAULT_ROTATION_MAXFILES,
            FILE_DEFAULT_BUFFER_SIZE,
            FILE_DEFAULT_ROTATION_TIME,
        );

        // We should have a File instance
        let _ = writer.write(test_object.test_patterns[0].as_bytes());
        assert_eq!(
            fs::read_to_string(test_object.get_file_base()).unwrap(),
            test_object.test_patterns[0]
        );
        let _ = writer.write(test_object.test_patterns[1].as_bytes());
        assert_eq!(
            fs::read_to_string(test_object.get_file_base()).unwrap(),
            format!(
                "{}{}",
                test_object.test_patterns[0], test_object.test_patterns[1]
            )
        );

        Ok(())
    }

    #[test]
    fn test_log_norotate_buf() -> Result<()> {
        let test_object = WriterTest::new("test_log_norotate_buf")?;
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"{}\"\nfile_buffer_size=10\n",
            test_object.get_file_base()
        ))
        .unwrap();
        let mut writer = test_object.setup_writer(
            cfg,
            FILE_DEFAULT_ROTATION_SIZE,
            FILE_DEFAULT_ROTATION_MAXFILES,
            10,
            FILE_DEFAULT_ROTATION_TIME,
        );

        // We should have a BufWriter<File> instance. First write should not be flushed
        let _ = writer.write(test_object.test_patterns[0].as_bytes());
        assert_eq!(fs::read_to_string(test_object.get_file_base()).unwrap(), "");
        let _ = writer.write(test_object.test_patterns[1].as_bytes());
        assert_eq!(
            fs::read_to_string(test_object.get_file_base()).unwrap(),
            test_object.test_patterns[0]
        );

        Ok(())
    }

    #[test]
    fn test_log_norotate_nofile() -> Result<()> {
        let test_object = WriterTest::new("/wrong/path/test_log_rotate_buf")?;
        let cfg = Config::from_string(&format!(
            "[output]\nfile_path = \"{}\"\n",
            test_object.get_file_base()
        ))
        .unwrap();
        test_object.setup_nowriter(cfg);
        Ok(())
    }
}
