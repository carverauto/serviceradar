/// Fuzz testing logic defined in this module
/// This module depends on the default configuration file `flowgger.toml`
///
/// The test in this module hits flowgger with random input.
/// The expected state is a failure for invalid inputs (no logs sent to output)
/// and successfully parsed logs written to output stream for valid inputs
///
/// # Dependencies
/// It depends on the external crate [`QuickCheck`][https://docs.rs/quickcheck/latest/quickcheck/]
///
/// `QuickCheck`is used to generate random string input, while a global structure is used to initialize shared resources at runtime
///
/// # Errors
///
/// This function will return an error if the default config does not exists, is unreadable, or is not valid
/// toml format
#[cfg(test)]
mod tests {
    extern crate quickcheck;
    extern crate tempdir;

    use crate::flowgger;

    use quickcheck::QuickCheck;
    use tempdir::TempDir;

    use std::fs;
    use std::io::{BufRead, BufReader};
    use std::ptr::addr_of_mut;
    use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
    use std::sync::Once;
    use std::sync::{Arc, Mutex};

    use flowgger::config::Config;
    use flowgger::decoder::Decoder;
    use flowgger::encoder::Encoder;
    use flowgger::get_decoder_rfc3164;
    use flowgger::get_encoder_rfc3164;
    use flowgger::get_output_file;
    use flowgger::input::udp_input::handle_record_maybe_compressed;
    use flowgger::merger;

    use self::merger::{LineMerger, Merger};
    use toml::Value;

    const DEFAULT_CONFIG_FILE: &str = "flowgger.toml";
    const DEFAULT_OUTPUT_FILENAME: &str = "output.log";
    const DEFAULT_QUEUE_SIZE: usize = 10_000_000;

    const DEFAULT_OUTPUT_FORMAT: &str = "gelf";
    const DEFAULT_OUTPUT_FRAMING: &str = "noop";
    const DEFAULT_OUTPUT_TYPE: &str = "file";

    const DEFAULT_FUZZED_MESSAGE_COUNT: u64 = 500;

    static INIT_CONTEXT: Once = Once::new();
    static mut GLOBAL_CONTEXT: Mutex<Option<Context>> = Mutex::new(None);

    struct Context {
        encoder: Box<dyn Encoder>,
        decoder: Box<dyn Decoder>,
        sync_sender: SyncSender<Vec<u8>>,
    }

    #[test]
    fn test_fuzzer() {
        let mut config = get_config();
        let file_output_name = config
            .lookup("output.file_path")
            .map_or(DEFAULT_OUTPUT_FILENAME, |x| {
                x.as_str().expect("File output path missing in config")
            });
        let output_dir = get_output_dir();
        let file_output_path = get_output_file_path(&output_dir, &file_output_name);
        let (tx, rx): (SyncSender<Vec<u8>>, Receiver<Vec<u8>>) = sync_channel(DEFAULT_QUEUE_SIZE);

        set_output_file_path_in_config(&mut config, &file_output_path);
        start_file_output(&config, rx);
        set_global_context(&config, tx);

        QuickCheck::new()
            .tests(DEFAULT_FUZZED_MESSAGE_COUNT)
            .quickcheck(fuzz_target_rfc3164 as fn(String));
        let _ = check_result(&file_output_path);
    }

    fn get_output_dir() -> TempDir {
        let temp_dir = TempDir::new("test_file_output").expect("Couldn't create output directory");
        return temp_dir;
    }

    fn get_output_file_path(output_dir: &TempDir, file_output_name: &str) -> String {
        let file_base = output_dir
            .path()
            .join(file_output_name)
            .to_string_lossy()
            .to_string();

        return file_base;
    }

    fn get_global_context() -> *mut Mutex<Option<Context>> {
        unsafe { addr_of_mut!(GLOBAL_CONTEXT) }
    }

    // Set the global context for the fuzzer
    // The global context is used to share resources across all test runs
    // CallOnce routine ensures the static variable referencing the struct is only ever set once
    fn set_global_context(config: &Config, sync_sender: SyncSender<Vec<u8>>) {
        INIT_CONTEXT.call_once(|| unsafe {
            let decoder = get_decoder_rfc3164(config);
            let encoder = get_encoder_rfc3164(config);
            let (decoder, encoder): (Box<dyn Decoder>, Box<dyn Encoder>) =
                (decoder.clone_boxed(), encoder.clone_boxed());

            let context = Context {
                encoder: encoder,
                decoder: decoder,
                sync_sender: sync_sender,
            };

            let mut guard = GLOBAL_CONTEXT.lock().unwrap();
            if guard.is_none() {
                *guard = Some(context);
            }
            drop(guard);
        });
    }

    fn get_config() -> Config {
        let mut config = match Config::from_path(DEFAULT_CONFIG_FILE) {
            Ok(config) => config,
            Err(e) => panic!(
                "Unable to read the config file [{}]: {}",
                "flowgger.toml",
                e.to_string()
            ),
        };

        update_file_rotation_defaults_in_config(&mut config);
        return config;
    }

    /// Update the default file rotation size and time in the config file
    /// This ensures output is sent to a single non-rotated file
    fn update_file_rotation_defaults_in_config(config: &mut Config) {
        if let Some(entry) = config
            .config
            .get_mut("output")
            .unwrap()
            .get_mut("file_rotation_size")
        {
            *entry = Value::Integer(0);
        }

        if let Some(entry) = config
            .config
            .get_mut("output")
            .unwrap()
            .get_mut("file_rotation_time")
        {
            *entry = Value::Integer(0);
        }
    }

    fn set_output_file_path_in_config(config: &mut Config, file_output_path: &str) {
        if let Some(entry) = config
            .config
            .get_mut("output")
            .unwrap()
            .get_mut("file_path")
        {
            *entry = Value::String(file_output_path.to_string());
        }
    }

    /// Start an input listener which writes data to the output file once received.
    fn start_file_output(config: &Config, rx: Receiver<Vec<u8>>) {
        let output_format = config
            .lookup("output.format")
            .map_or(DEFAULT_OUTPUT_FORMAT, |x| {
                x.as_str().expect("output.format must be a string")
            });

        let output = get_output_file(&config);
        let output_type = config
            .lookup("output.type")
            .map_or(DEFAULT_OUTPUT_TYPE, |x| {
                x.as_str().expect("output.type must be a string")
            });

        let _output_framing = match config.lookup("output.framing") {
            Some(framing) => framing.as_str().expect("output.framing must be a string"),
            None => match (output_format, output_type) {
                ("capnp", _) | (_, "kafka") => "noop",
                (_, "debug") | ("ltsv", _) => "line",
                ("gelf", _) => "nul",
                _ => DEFAULT_OUTPUT_FRAMING,
            },
        };
        let merger: Option<Box<dyn Merger>> =
            Some(Box::new(LineMerger::new(&config)) as Box<dyn Merger>);

        let arx = Arc::new(Mutex::new(rx));
        output.start(arx, merger);
    }

    fn fuzz_target_rfc3164(data: String) {
        unsafe {
            let global_context = get_global_context().as_ref().unwrap();

            // Extract the required fields from the global context structure, which is wrapped around by a Mutex
            let mut guard = match global_context.lock() {
                Ok(guard) => guard,
                Err(_poisoned_error) => {
                    // Handle the poisoned Mutex
                    let guard = _poisoned_error.into_inner();
                    guard
                }
            };
            let context: &mut Context = guard.as_mut().unwrap();
            let sync_sender: &mut SyncSender<Vec<u8>> = &mut context.sync_sender;
            let encoder: &mut Box<dyn Encoder> = &mut context.encoder;
            let decoder: &mut Box<dyn Decoder> = &mut context.decoder;
            let _result =
                handle_record_maybe_compressed(data.as_bytes(), &sync_sender, &decoder, &encoder);

            drop(guard);
        }
    }

    // Check for the result
    // On invalid input, no logs are expected to be written to the output file
    // For valid inputs, analyze each log entry, and check that the hostnames and appnames are in place
    fn check_result(file_output_path: &str) -> Result<(), std::io::Error> {
        unsafe {
            let global_context = get_global_context().as_ref().unwrap();
            let mut guard = match global_context.lock() {
                Ok(guard) => guard,
                Err(_poisoned_error) => {
                    let guard = _poisoned_error.into_inner();
                    guard
                }
            };
            let tx: SyncSender<Vec<u8>> = guard.take().unwrap().sync_sender;
            drop(tx);
            drop(guard);

            let file = fs::File::open(file_output_path).expect("Unable to open output file");
            let reader = BufReader::new(file);
            for line in reader.lines() {
                let line_item: String = line?;
                if !line_item.trim().is_empty() {
                    let split_line_content: Vec<&str> = line_item
                        .split(" ")
                        .filter(|data| !data.is_empty())
                        .collect();
                    let hostname = split_line_content[3].trim();
                    let appname = split_line_content[4].trim();

                    if hostname.is_empty() || appname.is_empty() {
                        panic!("Log output invalid");
                    }
                }
            }
            Ok(())
        }
    }
}
