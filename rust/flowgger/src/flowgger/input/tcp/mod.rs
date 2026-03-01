use crate::flowgger::config::Config;

pub mod tcp_input;
#[cfg(feature = "coroutines")]
pub mod tcpco_input;

pub use super::Input;

const DEFAULT_FRAMING: &str = "line";
const DEFAULT_LISTEN: &str = "0.0.0.0:514";
#[cfg(feature = "coroutines")]
const DEFAULT_THREADS: usize = 1;
const DEFAULT_TIMEOUT: u64 = 3600;

#[derive(Clone)]
pub struct TcpConfig {
    pub(crate) framing: String,
    #[allow(dead_code)]
    pub(crate) threads: usize,
}

#[cfg(feature = "coroutines")]
fn get_default_threads(config: &Config) -> usize {
    config
        .lookup("input.tcp_threads")
        .map_or(DEFAULT_THREADS, |x| {
            x.as_integer()
                .expect("input.tcp_threads must be an unsigned integer") as usize
        })
}

#[cfg(not(feature = "coroutines"))]
fn get_default_threads(_config: &Config) -> usize {
    1
}

pub fn config_parse(config: &Config) -> (TcpConfig, String, u64) {
    let listen = config
        .lookup("input.listen")
        .map_or(DEFAULT_LISTEN, |x| {
            x.as_str().expect("input.listen must be an ip:port string")
        })
        .to_owned();
    let threads = get_default_threads(config);
    let timeout = config.lookup("input.timeout").map_or(DEFAULT_TIMEOUT, |x| {
        x.as_integer()
            .expect("input.timeout must be an unsigned integer") as u64
    });
    let framing = if config
        .lookup("input.framed")
        .is_some_and(|x| x.as_bool().expect("input.framed must be a boolean"))
    {
        "syslen"
    } else {
        DEFAULT_FRAMING
    };
    let framing = config
        .lookup("input.framing")
        .map_or(framing, |x| {
            x.as_str()
                .expect(r#"input.framing must be a string set to "line", "nul" or "syslen""#)
        })
        .to_owned();
    let tcp_config = TcpConfig { framing, threads };
    (tcp_config, listen, timeout)
}
