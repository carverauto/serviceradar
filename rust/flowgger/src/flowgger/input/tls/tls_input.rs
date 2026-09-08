use super::*;
use crate::flowgger::config::Config;
use crate::flowgger::decoder::{Decoder, RemoteAddrDecoder};
use crate::flowgger::encoder::Encoder;
#[cfg(feature = "capnp-recompile")]
use crate::flowgger::splitter::CapnpSplitter;
use crate::flowgger::splitter::{LineSplitter, NulSplitter, Splitter, SyslenSplitter};
use rustls::{ServerConnection, StreamOwned};
use std::io::{BufReader, Write, stderr};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::SyncSender;
use std::thread;
use std::time::Duration;

pub struct TlsInput {
    listen: String,
    timeout: Option<Duration>,
    tls_config: TlsConfig,
}

impl TlsInput {
    pub fn new(config: &Config) -> TlsInput {
        let (tls_config, listen, timeout) = config_parse(config);
        TlsInput {
            listen,
            tls_config,
            timeout: Some(Duration::from_secs(timeout)),
        }
    }
}

impl Input for TlsInput {
    fn accept(
        &self,
        tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    ) {
        let listener = TcpListener::bind(&self.listen as &str).unwrap();
        for client in listener.incoming().flatten() {
            let _ = client.set_read_timeout(self.timeout);
            let tx = tx.clone();
            let (decoder, encoder) = (decoder.clone_boxed(), encoder.clone_boxed());
            let tls_config = self.tls_config.clone();
            thread::spawn(move || {
                handle_client(client, tx, decoder, encoder, tls_config);
            });
        }
    }
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
    tls_config: TlsConfig,
) {
    let remote_addr = match client.peer_addr() {
        Ok(peer_addr) => {
            println!("Connection over TLS from [{peer_addr}]");
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
    let conn = match ServerConnection::new(tls_config.server_config.clone()) {
        Err(e) => {
            let _ = writeln!(stderr(), "Unable to start the TLS session: {e}");
            return;
        }
        Ok(conn) => conn,
    };
    // The rustls handshake completes lazily on the first read below; a failed
    // handshake surfaces as a read error handled by the splitter.
    let sslclient = StreamOwned::new(conn, client);
    let reader = BufReader::new(sslclient);
    let splitter = match &tls_config.framing as &str {
        "capnp" => get_capnp_splitter(),
        "line" => Box::new(LineSplitter) as Box<dyn Splitter<_>>,
        "syslen" => Box::new(SyslenSplitter) as Box<dyn Splitter<_>>,
        "nul" => Box::new(NulSplitter) as Box<dyn Splitter<_>>,
        _ => panic!("Unsupported framing scheme"),
    };
    splitter.run(reader, tx, decoder, encoder);
}
