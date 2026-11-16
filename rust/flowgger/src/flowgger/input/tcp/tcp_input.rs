use super::*;
use crate::flowgger::config::Config;
use crate::flowgger::decoder::{Decoder, RemoteAddrDecoder};
use crate::flowgger::encoder::Encoder;
#[cfg(feature = "capnp-recompile")]
use crate::flowgger::splitter::CapnpSplitter;
use crate::flowgger::splitter::{LineSplitter, NulSplitter, Splitter, SyslenSplitter};
use std::io::{BufReader, ErrorKind};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::SyncSender;
use std::thread;
use std::time::Duration;

pub struct TcpInput {
    listen: String,
    tcp_config: TcpConfig,
    timeout: Option<Duration>,
}

impl TcpInput {
    pub fn new(config: &Config) -> TcpInput {
        let (tcp_config, listen, timeout) = config_parse(config);
        TcpInput {
            listen,
            tcp_config,
            timeout: Some(Duration::from_secs(timeout)),
        }
    }
}

impl Input for TcpInput {
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    ) {
        let listener = TcpListener::bind(&self.listen as &str)
            .unwrap_or_else(|err| panic!("Unable to listen to {}: {err}", self.listen));
        for client in listener.incoming() {
            let client = match client {
                Ok(client) => client,
                Err(err)
                    if matches!(
                        err.kind(),
                        ErrorKind::Interrupted | ErrorKind::ConnectionAborted
                    ) =>
                {
                    continue;
                }
                Err(err) if listener_unusable(&err) => {
                    panic!("Unable to accept TCP connection on {}: {err}", self.listen)
                }
                Err(err) => {
                    eprintln!("Unable to accept TCP connection on {}: {err}", self.listen);
                    thread::sleep(ACCEPT_RETRY_DELAY);
                    continue;
                }
            };
            let _ = client.set_read_timeout(self.timeout);
            let tx = tx.clone();
            let tcp_config = self.tcp_config.clone();
            let (decoder, encoder) = (decoder.clone_boxed(), encoder.clone_boxed());
            thread::spawn(move || {
                handle_client(client, tx, decoder, encoder, tcp_config);
            });
        }
    }
}

const ACCEPT_RETRY_DELAY: Duration = Duration::from_millis(100);

#[cfg(target_os = "linux")]
const ENOTSOCK: i32 = 88;
#[cfg(not(target_os = "linux"))]
const ENOTSOCK: i32 = 38;
const EBADF: i32 = 9;

fn listener_unusable(err: &std::io::Error) -> bool {
    err.kind() == ErrorKind::InvalidInput || matches!(err.raw_os_error(), Some(EBADF | ENOTSOCK))
}

#[cfg(feature = "capnp-recompile")]
pub fn get_capnp_splitter<T>() -> Box<dyn Splitter<T>>
where
    T: std::io::Read,
{
    Box::new(CapnpSplitter) as Box<dyn Splitter<_>>
}

#[cfg(not(feature = "capnp-recompile"))]
pub fn get_capnp_splitter() -> ! {
    panic!("Support for CapNProto is not compiled in")
}

fn handle_client(
    client: TcpStream,
    tx: SyncSender<Vec<u8>>,
    decoder: Box<dyn Decoder>,
    encoder: Box<dyn Encoder>,
    tcp_config: TcpConfig,
) {
    let remote_addr = match client.peer_addr() {
        Ok(peer_addr) => {
            println!("Connection over TCP from [{peer_addr}]");
            Some(peer_addr.ip().to_string())
        }
        Err(_) => None,
    };
    let decoder = match remote_addr {
        Some(remote_addr) => {
            Box::new(RemoteAddrDecoder::new(decoder, remote_addr)) as Box<dyn Decoder>
        }
        None => decoder,
    };
    let reader = BufReader::new(client);
    let splitter = match &tcp_config.framing as &str {
        "capnp" => get_capnp_splitter(),
        "line" => Box::new(LineSplitter) as Box<dyn Splitter<_>>,
        "syslen" => Box::new(SyslenSplitter) as Box<dyn Splitter<_>>,
        "nul" => Box::new(NulSplitter) as Box<dyn Splitter<_>>,
        _ => panic!("Unsupported framing scheme"),
    };
    splitter.run(reader, tx, decoder, encoder);
}
